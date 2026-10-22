import Foundation
import Testing
import CSQLite
@testable import BatteryCore

private let origin = Date(timeIntervalSince1970: 1_790_006_400)
private func point(_ seconds: Double, level: Double = 80, state: BatteryState = .discharging,
                   watts: Double? = -10, full: Double = 5_000) -> BatterySnapshot {
    BatterySnapshot(date: origin.addingTimeInterval(seconds), level: level, state: state,
        cycleCount: 100, designCapacity: 5_500, fullCapacity: full, voltage: watts == nil ? nil : 10,
        currentMA: watts.map { $0 * 100 })
}
private func temporaryStore() throws -> (HistoryStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try HistoryStore(url: folder.appendingPathComponent("history.sqlite")), folder)
}

@Test func profilesValidateLimitsNamesAndReminders() {
    #expect(ChargeProfile(name: "Desk", limit: 80).isValid)
    #expect(!ChargeProfile(name: " ", limit: 80).isValid)
    #expect(!ChargeProfile(name: String(repeating: "x", count: 41), limit: 80).isValid)
    #expect(!ChargeProfile(name: "Custom", limit: 101).isValid)
    #expect(!ChargeProfile(name: "Custom", limit: 80, lowReminder: 0).isValid)
    #expect(ChargeProfile.defaults.map(\.limit) == [80, 100])
}

@Test func forecastUsesCurrentInCorrectUnitsAndShowsUncertainty() throws {
    let samples = stride(from: 0.0, through: 300, by: 15).map { point($0) }
    let forecast = try #require(RuntimeForecast.estimate(samples))
    // 1 A / 5 Ah = 20% per hour; 80% has about 4 hours.
    #expect(abs(forecast.hours - 4) < 0.001)
    #expect(forecast.lowerHours < forecast.hours)
    #expect(forecast.upperHours > forecast.hours)
}

@Test func forecastRejectsWarmupSleepChargingAndMissingSensors() {
    #expect(RuntimeForecast.estimate([point(0), point(60), point(120)]) == nil)
    let missing = stride(from: 0.0, through: 300, by: 15).map { point($0, watts: nil) }
    #expect(RuntimeForecast.estimate(missing) == nil)
    let samples = stride(from: 0.0, through: 300, by: 15).map { point($0) }
    #expect(RuntimeForecast.estimate(samples + [point(900)]) == nil)
    #expect(RuntimeForecast.estimate(samples + [point(315, state: .charging, watts: 10)]) == nil)
}

@Test func forecastResistsOneTransientPowerSpike() throws {
    var samples = stride(from: 0.0, through: 300, by: 15).map { point($0) }
    samples[5] = point(75, watts: -90)
    #expect(abs(try #require(RuntimeForecast.estimate(samples)).hours - 4) < 0.01)
}

@Test func drainBaselineNeedsCoverageAndExcludesRecentData() throws {
    let samples = stride(from: 0.0, through: 3_000, by: 60).map { point($0, watts: $0 < 1_800 ? -10 : -60) }
    let baseline = try #require(InsightMath.baseline(samples, before: origin.addingTimeInterval(1_861)))
    #expect(abs(baseline.watts - 10) < 0.01)
    #expect(InsightMath.baseline(Array(samples.prefix(10)), before: origin.addingTimeInterval(10_000)) == nil)
}

@Test func drainAlertRequiresFiveMinutesAndDoesNotRepeat() {
    var detector = DrainAnomalyDetector()
    let baseline = DrainBaseline(watts: 8, seconds: 3_600)
    for second in stride(from: 0.0, to: 300, by: 15) {
        let fired = detector.evaluate(point(second, watts: -25), baseline: baseline, lastAlert: nil)
        #expect(!fired)
    }
    let first = detector.evaluate(point(300, watts: -25), baseline: baseline, lastAlert: nil)
    let repeated = detector.evaluate(point(315, watts: -25), baseline: baseline, lastAlert: nil)
    #expect(first); #expect(!repeated)
}

@Test func drainAlertIgnoresSpikesGapsAndCooldown() {
    var detector = DrainAnomalyDetector()
    let baseline = DrainBaseline(watts: 8, seconds: 3_600)
    _ = detector.evaluate(point(0, watts: -25), baseline: baseline, lastAlert: nil)
    let afterGap = detector.evaluate(point(300, watts: -25), baseline: baseline, lastAlert: nil)
    #expect(!afterGap)
    for second in stride(from: 315.0, through: 615, by: 15) {
        let fired = detector.evaluate(point(second, watts: -25), baseline: baseline, lastAlert: origin)
        #expect(!fired)
    }
    let charging = detector.evaluate(point(630, state: .charging, watts: 25), baseline: baseline, lastAlert: nil)
    #expect(!charging)
}

@Test func sleepDrainHandlesPowerAndShortSessionsHonestly() {
    let night = SleepSession(before: point(0, level: 80), after: point(8 * 3_600, level: 68))
    #expect(night.duration == 28_800)
    #expect(night.drop == 12)
    #expect(night.drainPerHour == 1.5)
    #expect(night.unusual)
    let powered = SleepSession(before: point(0, state: .pluggedIn), after: point(7_200, level: 70))
    #expect(powered.drainPerHour == nil)
    #expect(SleepSession(before: point(0), after: point(30)).drop == nil)
    #expect(SleepSession(before: point(0), after: point(300, level: 79)).drainPerHour == nil)
    var recovered = night; recovered.recoveredAfterRestart = true
    #expect(recovered.drainPerHour == nil && !recovered.unusual)
}

@Test func newerDatabaseIsRejectedWithoutDowngradingItsVersion() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("history.sqlite")
    var db: OpaquePointer?; #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA user_version=3;", nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
    #expect(throws: StoreFailure.self) { _ = try HistoryStore(url: url) }
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW); #expect(sqlite3_column_int(statement, 0) == 3)
    sqlite3_finalize(statement); sqlite3_close(db)
}

@Test func chargeSessionsSplitAtDisconnectAndCoverageGaps() {
    let samples = [point(0, level: 40, state: .charging, watts: 20), point(60, level: 41, state: .charging, watts: 20),
        point(120, level: 41), point(300, level: 40, state: .charging, watts: 20),
        point(3_000, level: 80, state: .pluggedIn, watts: 0)]
    let sessions = InsightMath.chargingSessions(samples, now: origin.addingTimeInterval(3_010))
    #expect(sessions.count == 3)
    #expect(sessions.first?.ongoing == true)
    #expect(abs(sessions.last!.chargedWh - 1.0 / 3) < 0.0001)
}

@Test func dailyEnergySplitsAtMidnightWithoutInventingGaps() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let midnight = calendar.startOfDay(for: origin).addingTimeInterval(86_400)
    var a = point(0, watts: -12), b = point(120, watts: -12)
    a.date = midnight.addingTimeInterval(-60); b.date = midnight.addingTimeInterval(60)
    let days = InsightMath.dailyEnergy([a, b], calendar: calendar)
    #expect(days.count == 2)
    #expect(abs(days[0].dischargedWh - 0.2) < 0.0001)
    #expect(abs(days[1].dischargedWh - 0.2) < 0.0001)
    b.date = midnight.addingTimeInterval(1_000)
    #expect(InsightMath.dailyEnergy([a, b], calendar: calendar).isEmpty)
}

@Test func explanationDoesNotBlameCellWithoutConfirmation() {
    let battery = point(0, state: .pluggedIn, watts: 0)
    #expect(ChargingExplanation.make(battery, helper: nil, helperError: nil).title == "Connected, but charging is paused")
    let helper = ChargeHelperStatus(configuration: .init(enabled: true, percentage: 80), supported: true, held: true, onAC: true)
    #expect(ChargingExplanation.make(battery, helper: helper, helperError: nil).title == "Cell is holding the charge")
    #expect(ChargingExplanation.make(battery, helper: helper, helperError: "Offline").title == "Cell cannot confirm charge control")
    #expect(ChargingExplanation.make(point(0, state: .charging, watts: 20), helper: helper, helperError: nil).title == "Your battery is charging")
}

@Test func eventAndSleepPersistenceIsIdempotent() async throws {
    let (store, folder) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
    let event = PowerEvent(date: origin, kind: .connected, title: "Connected")
    try await store.recordEvent(event); try await store.recordEvent(event)
    let session = SleepSession(before: point(0), after: point(7_200, level: 75))
    try await store.recordSleep(session); try await store.recordSleep(session)
    let data = try await store.insights(range: .day, reportEnd: origin.addingTimeInterval(8_000), now: origin.addingTimeInterval(8_000))
    #expect(data.events.count == 1); #expect(data.sleep.count == 1)
    await store.close()
}

@Test func hourlyAppEnergyPreservesUnitsAndMissingPower() async throws {
    let (store, folder) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
    let hour = Date(timeIntervalSince1970: floor(origin.timeIntervalSince1970 / 3_600) * 3_600)
    let interval = AppEnergyInterval(identity: "app:test", name: "Test", end: hour.addingTimeInterval(3_630), seconds: 60, watts: 12, cpuPercent: 200)
    let unknown = AppEnergyInterval(identity: "process:unknown", name: "Unknown", end: hour.addingTimeInterval(3_630), seconds: 60, watts: nil, cpuPercent: 100)
    try await store.recordAppEnergy([interval, unknown])
    let totals = try await store.appTotals(since: hour, until: hour.addingTimeInterval(7_200))
    let measured = try #require(totals.first { $0.id == "app:test" })
    #expect(abs(measured.wattHours - 0.2) < 0.0001)
    #expect(measured.cpuSeconds == 120); #expect(measured.observedSeconds == 60)
    #expect(measured.averageWatts == 12)
    let proxy = try #require(totals.first { $0.name == "Unknown" })
    #expect(proxy.averageWatts == nil); #expect(proxy.measuredSeconds == 0)
    let laterHour = try await store.appTotals(since: hour.addingTimeInterval(3_600), until: hour.addingTimeInterval(7_200))
    #expect(abs(laterHour.first!.wattHours - 0.1) < 0.0001)
    await store.close()
}

@Test func appStorageIsBoundedPerHour() async throws {
    let (store, folder) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
    let intervals = (0..<200).map { AppEnergyInterval(identity: "app:\($0)", name: "App \($0)", end: origin, seconds: 15, watts: Double($0), cpuPercent: 1) }
    try await store.recordAppEnergy(intervals)
    #expect(try await store.appTotals(since: origin.addingTimeInterval(-60), until: origin.addingTimeInterval(60)).count == 128)
    await store.close()
}

@Test func healthUsesOneDailyReadingAndClearRemovesAllKinds() async throws {
    let (store, folder) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
    try await store.append(point(0)); try await store.append(point(60, full: 4_900))
    try await store.recordEvent(.init(date: origin, kind: .monitoring, title: "Start"))
    try await store.recordSleep(.init(before: point(0), after: point(7_200)))
    try await store.recordAppEnergy([.init(identity: "a", name: "A", end: origin, seconds: 10, watts: 5, cpuPercent: 1)])
    let data = try await store.insights(range: .day, reportEnd: origin.addingTimeInterval(8_000), now: origin.addingTimeInterval(8_000))
    #expect(data.health.count == 1); #expect(data.health.first?.fullCapacity == 4_900)
    try await store.clear()
    let cleared = try await store.insights(range: .day, reportEnd: origin.addingTimeInterval(8_000), now: origin.addingTimeInterval(8_000))
    #expect(cleared.health.isEmpty && cleared.events.isEmpty && cleared.apps.isEmpty && cleared.sleep.isEmpty)
    await store.close()
}

@Test func retentionKeepsHealthLongerThanDetailedRecords() async throws {
    let (store, folder) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
    try await store.append(point(0))
    try await store.recordEvent(.init(date: origin, kind: .monitoring, title: "Old"))
    try await store.recordAppEnergy([.init(identity: "a", name: "A", end: origin, seconds: 10, watts: 5, cpuPercent: 1)])
    let later = point(100 * 86_400)
    try await store.append(later)
    let data = try await store.insights(range: .month, reportEnd: later.date, now: later.date)
    #expect(data.events.isEmpty && data.apps.isEmpty)
    #expect(data.health.count == 2)
    await store.close()
}

@Test func weeklyReportsCompareSeparatePeriodsAndExposeCoverage() async throws {
    let (store, folder) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: folder) }
    for minute in 0...60 { try await store.append(point(Double(minute * 60), watts: -10)) }
    for minute in 0...60 { try await store.append(point(8 * 86_400 + Double(minute * 60), watts: -20)) }
    let end = origin.addingTimeInterval(9 * 86_400)
    let dashboard = try await store.insights(range: .week, reportEnd: end, now: end)
    let report = try #require(dashboard.report)
    #expect(abs(report.current.dischargedWh - 20) < 0.001)
    #expect(abs(report.previous.dischargedWh - 10) < 0.001)
    #expect(abs(report.observedDrainChange! - 100) < 0.001)
    #expect(report.plainText().contains("Recorded coverage:"))
    await store.close()
}

@Test func existingV1DatabaseMigratesWithoutLosingSamples() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("history.sqlite")
    var db: OpaquePointer?; #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE samples(time REAL PRIMARY KEY, payload TEXT NOT NULL); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
    let sample = point(0), json = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    #expect(sqlite3_exec(db, "INSERT INTO samples VALUES (\(origin.timeIntervalSince1970), '\(json)')", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let store = try HistoryStore(url: url)
    #expect(try await store.samples(since: origin) == [sample])
    try await store.recordEvent(.init(date: origin, kind: .monitoring, title: "Migrated"))
    await store.close()
}

@Test func appCSVQuotesNamesAndPreventsSpreadsheetFormulas() {
    let value = AppEnergyTotal(id: "x", name: "=HYPERLINK(\"bad\"),name", bundlePath: nil, wattHours: 0, cpuSeconds: 60, observedSeconds: 10, measuredSeconds: 0)
    let csv = AppEnergyCSV.encode([value])
    #expect(csv.contains("\"'=HYPERLINK(\"\"bad\"\"),name\""))
    #expect(csv.contains(",,1.0,10.0,0.0"))
}
