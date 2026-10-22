import Foundation
import CSQLite

extension HistoryStore {
    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    private func payload<T: Encodable>(_ object: T) throws -> String {
        String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    }
    private func writeRecord(_ sql: String, id: String, date: Date, payload: String) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil)); defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1); sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        bind(payload, to: statement, at: 3); try check(sqlite3_step(statement))
    }
    public func recordEvent(_ event: PowerEvent) throws {
        try writeRecord("INSERT OR REPLACE INTO events VALUES (?, ?, ?)", id: event.id.uuidString, date: event.date, payload: payload(event))
    }
    public func recordSleep(_ session: SleepSession) throws {
        guard let after = session.after, session.duration >= 60 else { return }
        try writeRecord("INSERT OR REPLACE INTO sleep_sessions VALUES (?, ?, ?)", id: session.id.uuidString,
                        date: after.date, payload: payload(session))
    }
    func recordHealth(_ snapshot: BatterySnapshot) throws {
        guard let health = snapshot.health, health.isFinite, let capacity = snapshot.fullCapacity, capacity > 0, capacity.isFinite else { return }
        let day = Calendar.current.startOfDay(for: snapshot.date)
        let value = HealthReading(day: day, health: health, fullCapacity: capacity, cycles: snapshot.cycleCount)
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "INSERT INTO health_days VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET payload=excluded.payload WHERE health_days.payload<>excluded.payload", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, day.timeIntervalSince1970)
        bind(try payload(value), to: statement, at: 2); try check(sqlite3_step(statement))
    }
    private func records<T: Decodable>(_ type: T.Type, sql: String, since: Date) throws -> [T] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil)); defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var output: [T] = [], result = sqlite3_step(statement)
        let decoder = JSONDecoder()
        while result == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { throw StoreFailure(message: "Unreadable insight record.") }
            output.append(try decoder.decode(T.self, from: Data(bytes: text, count: Int(sqlite3_column_bytes(statement, 0)))))
            result = sqlite3_step(statement)
        }
        try check(result); return output
    }

    /// Coalesce intervals in memory before a single short SQLite transaction.
    public func recordAppEnergy(_ intervals: [AppEnergyInterval]) throws {
        struct Key: Hashable { var bucket: Double; var identity: String }
        struct Value { var name: String; var path: String?; var wh = 0.0; var cpu = 0.0; var seconds = 0.0; var measured = 0.0 }
        var buckets: [Key: Value] = [:]
        for interval in intervals {
            guard interval.seconds.isFinite, interval.seconds >= 1, interval.seconds <= 90,
                  interval.cpuPercent.isFinite, interval.cpuPercent >= 0 else { continue }
            var cursor = interval.end.timeIntervalSince1970 - interval.seconds
            let end = interval.end.timeIntervalSince1970
            while cursor < end {
                let hour = floor(cursor / 3_600) * 3_600, boundary = min(end, hour + 3_600)
                let seconds = boundary - cursor
                let key = Key(bucket: hour, identity: interval.identity)
                var value = buckets[key] ?? Value(name: interval.name, path: interval.bundlePath)
                value.seconds += seconds; value.cpu += interval.cpuPercent / 100 * seconds
                if let watts = interval.watts, watts.isFinite, watts >= 0 {
                    value.wh += watts * seconds / 3_600; value.measured += seconds
                }
                buckets[key] = value; cursor = boundary
            }
        }
        guard !buckets.isEmpty else { return }
        try check(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil))
        do {
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO app_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket, identity) DO UPDATE SET
              name=excluded.name, path=excluded.path, wh=wh+excluded.wh, cpu=cpu+excluded.cpu,
              seconds=seconds+excluded.seconds, measured=measured+excluded.measured
            """
            try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil)); defer { sqlite3_finalize(statement) }
            for (key, value) in buckets {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                sqlite3_bind_double(statement, 1, key.bucket); bind(key.identity, to: statement, at: 2)
                bind(value.name, to: statement, at: 3)
                if let path = value.path { bind(path, to: statement, at: 4) }
                for (index, number) in [value.wh, value.cpu, value.seconds, value.measured].enumerated() {
                    sqlite3_bind_double(statement, Int32(index + 5), number)
                }
                try check(sqlite3_step(statement))
            }
            // Bound every hour to 128 identities, even if processes churn continuously.
            var cap: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "DELETE FROM app_usage WHERE bucket=? AND identity NOT IN (SELECT identity FROM app_usage WHERE bucket=? ORDER BY wh DESC, cpu DESC LIMIT 128)", -1, &cap, nil))
            defer { sqlite3_finalize(cap) }
            for bucket in Set(buckets.keys.map(\.bucket)) {
                sqlite3_reset(cap); sqlite3_bind_double(cap, 1, bucket); sqlite3_bind_double(cap, 2, bucket)
                try check(sqlite3_step(cap))
            }
            try check(sqlite3_exec(db, "COMMIT", nil, nil, nil))
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }
    public func appTotals(since: Date, until: Date = .now) throws -> [AppEnergyTotal] {
        var statement: OpaquePointer?
        let sql = "SELECT identity, MAX(name), MAX(path), SUM(wh), SUM(cpu), SUM(seconds), SUM(measured) FROM app_usage WHERE bucket >= ? AND bucket < ? GROUP BY identity ORDER BY SUM(wh) DESC, SUM(cpu) DESC LIMIT 128"
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil)); defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, floor(since.timeIntervalSince1970 / 3_600) * 3_600)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        func string(_ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
        var result = sqlite3_step(statement), output: [AppEnergyTotal] = []
        while result == SQLITE_ROW {
            output.append(.init(id: string(0) ?? "", name: string(1) ?? "Process", bundlePath: string(2),
                wattHours: sqlite3_column_double(statement, 3), cpuSeconds: sqlite3_column_double(statement, 4),
                observedSeconds: sqlite3_column_double(statement, 5), measuredSeconds: sqlite3_column_double(statement, 6)))
            result = sqlite3_step(statement)
        }
        try check(result); return output
    }
    func pruneInsights(now: Date) throws {
        for (table, column, cutoff) in [("events", "time", now.addingTimeInterval(-90 * 86_400)),
            ("sleep_sessions", "time", now.addingTimeInterval(-90 * 86_400)),
            ("app_usage", "bucket", now.addingTimeInterval(-90 * 86_400)),
            ("health_days", "day", now.addingTimeInterval(-730 * 86_400))] {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE \(column) < ?", -1, &statement, nil))
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            let result = sqlite3_step(statement); sqlite3_finalize(statement); try check(result)
        }
        try check(sqlite3_exec(db, "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY time DESC LIMIT 10000)", nil, nil, nil))
    }

    public func insights(range: HistoryRange, reportEnd: Date, now: Date = .now,
                         features: FeaturePreferences = .init(), includeBaseline: Bool = true) throws -> InsightsDashboard {
        var result = InsightsDashboard(); result.generated = now
        guard features[.batteryHistory] else { return result }
        let since = now.addingTimeInterval(-range.seconds)
        if features.recordsTimeline {
            result.events = try records(PowerEvent.self, sql: "SELECT payload FROM events WHERE time>=? ORDER BY time DESC LIMIT 300", since: since)
        }
        if features.recordsSleep {
            result.sleep = try records(SleepSession.self, sql: "SELECT payload FROM sleep_sessions WHERE time>=? ORDER BY time DESC LIMIT 300", since: since)
        }
        if features.recordsHealth {
            result.health = try records(HealthReading.self, sql: "SELECT payload FROM health_days WHERE day>=? ORDER BY day", since: now.addingTimeInterval(-730 * 86_400))
        }
        if features.recordsAppEnergy { result.apps = try appTotals(since: since, until: now) }
        let needsSamples = features.recordsTimeline || includeBaseline || features.generatesReports
        let recent = needsSamples ? try samples(since: now.addingTimeInterval(-max(range.seconds, 14 * 86_400))) : []
        if features.recordsTimeline { result.sessions = Array(InsightMath.chargingSessions(recent.filter { $0.date >= since }, now: now).prefix(100)) }
        if includeBaseline { result.baseline = InsightMath.baseline(recent.filter { $0.date >= now.addingTimeInterval(-7 * 86_400) }, before: now.addingTimeInterval(-900)) }
        guard features.generatesReports else { return result }
        let calendar = Calendar.current
        let end = min(now, reportEnd)
        let start = calendar.date(byAdding: .day, value: -7, to: end)!
        let previousStart = calendar.date(byAdding: .day, value: -7, to: start)!
        let reportSamples = previousStart >= (recent.first?.date ?? .distantPast) ? recent : try samples(since: previousStart)
        let current = reportSamples.filter { $0.date >= start && $0.date < end }
        let previous = reportSamples.filter { $0.date >= previousStart && $0.date < start }
        let sleeps = features.recordsSleep ? try records(SleepSession.self, sql: "SELECT payload FROM sleep_sessions WHERE time>=? ORDER BY time DESC", since: start).filter { ($0.after?.date ?? .distantFuture) < end } : []
        let health = result.health.filter { $0.day >= calendar.startOfDay(for: start) && $0.day < end }
        let healthChange = health.count >= 2 ? health.last!.health - health.first!.health : nil
        result.report = .init(start: start, end: end, current: .init(samples: current), previous: .init(samples: previous),
            days: InsightMath.dailyEnergy(current), apps: features.recordsAppEnergy ? try appTotals(since: start, until: end) : [], sleeps: sleeps, healthChange: healthChange)
        return result
    }
}
