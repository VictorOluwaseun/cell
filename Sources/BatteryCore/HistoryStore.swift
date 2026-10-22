import Foundation
import CSQLite

public struct StoreFailure: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// A single actor owns the connection; no database work runs on the main thread.
public actor HistoryStore {
    var db: OpaquePointer?
    private var lastPrune = Date.distantPast
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open battery history."
            sqlite3_close(connection); throw StoreFailure(message: message)
        }
        db = connection
        sqlite3_busy_timeout(connection, 3_000)
        var version: OpaquePointer?
        if sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK,
           sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) > 2 {
            sqlite3_finalize(version); sqlite3_close(connection); db = nil
            throw StoreFailure(message: "This history database was created by a newer version of Cell.")
        }
        sqlite3_finalize(version)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS samples (time REAL PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, time REAL NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_time ON events(time);
        CREATE TABLE IF NOT EXISTS sleep_sessions (id TEXT PRIMARY KEY, time REAL NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS sleep_time ON sleep_sessions(time);
        CREATE TABLE IF NOT EXISTS health_days (day REAL PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS app_usage (
          bucket REAL NOT NULL, identity TEXT NOT NULL, name TEXT NOT NULL, path TEXT,
          wh REAL NOT NULL, cpu REAL NOT NULL, seconds REAL NOT NULL, measured REAL NOT NULL,
          PRIMARY KEY(bucket, identity)
        ) WITHOUT ROWID;
        PRAGMA user_version=2;
        COMMIT;
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(connection))
            sqlite3_close(connection); db = nil; throw StoreFailure(message: message)
        }
    }
    // Connection is closed explicitly by the app, or by process teardown.
    public func close() { sqlite3_close(db); db = nil }
    func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_DONE else {
            throw StoreFailure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "History is closed.")
        }
    }
    public func append(_ sample: BatterySnapshot, recordHealthHistory: Bool = true) throws {
        guard db != nil else { throw StoreFailure(message: "History is closed.") }
        let data = try JSONEncoder().encode(sample)
        let payload = String(decoding: data, as: UTF8.self)
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples VALUES (?, ?)", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, sample.date.timeIntervalSince1970)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = payload.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        try check(sqlite3_step(statement))
        if recordHealthHistory { try recordHealth(sample) }
        if sample.date.timeIntervalSince(lastPrune) > 3_600 {
            try prune(before: sample.date.addingTimeInterval(-90 * 86_400))
            try pruneInsights(now: sample.date)
            lastPrune = sample.date
        }
    }
    public func samples(since date: Date) throws -> [BatterySnapshot] {
        guard db != nil else { throw StoreFailure(message: "History is closed.") }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT payload FROM samples WHERE time >= ? ORDER BY time", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        var output: [BatterySnapshot] = []
        let decoder = JSONDecoder()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { throw StoreFailure(message: "Unreadable history record.") }
            let data = Data(bytes: text, count: Int(sqlite3_column_bytes(statement, 0)))
            output.append(try decoder.decode(BatterySnapshot.self, from: data))
            result = sqlite3_step(statement)
        }
        try check(result)
        return output
    }
    public func clear() throws {
        try check(sqlite3_exec(db, "BEGIN IMMEDIATE; DELETE FROM samples; DELETE FROM events; DELETE FROM sleep_sessions; DELETE FROM health_days; DELETE FROM app_usage; COMMIT; PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil))
    }
    private func prune(before date: Date) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "DELETE FROM samples WHERE time < ?", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        try check(sqlite3_step(statement))
    }
}

public enum HistoryCSV {
    public static func encode(_ samples: [BatterySnapshot]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = "timestamp,percentage,state,battery_watts,system_watts,current_mA,voltage_V,temperature_C,cycles,health_percent"
        func field(_ number: Double?) -> String { number.map { String($0) } ?? "" }
        let rows: [String] = samples.map { s in
            var fields = [formatter.string(from: s.date), String(s.level), s.state.rawValue]
            fields.append(contentsOf: [field(s.batteryWatts), field(s.systemWatts), field(s.currentMA)])
            fields.append(contentsOf: [field(s.voltage), field(s.temperature)])
            fields.append(s.cycleCount.map { String($0) } ?? "")
            fields.append(field(s.health))
            return fields.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}
