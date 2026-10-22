import Foundation
import Testing
@testable import BatteryCore

@Test func featurePreferencesPreserveExistingChoicesAcrossLaunches() throws {
    let domain = "Cell-feature-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set(false, forKey: "appMonitoring")
    defaults.set(false, forKey: "alertSound")
    var features = FeaturePreferences(defaults: defaults)
    #expect(!features[.appActivity])
    #expect(features[.chargeAlerts])
    features[.runtimeForecast] = false
    features[.reports] = false
    features.save(to: defaults)
    #expect(FeaturePreferences(defaults: defaults) == features)
    #expect(!defaults.bool(forKey: "alertSound"))
}

@Test func pausingPrerequisitesKeepsIndependentFeatureChoices() {
    var features = FeaturePreferences()
    features[.healthHistory] = false
    features[.batteryHistory] = false
    #expect(!features.recordsAppEnergy && !features.recordsSleep && !features.recordsTimeline && !features.generatesReports)
    #expect(features[.runtimeForecast] && features[.chargeAlerts] && features[.reports])
    features[.batteryHistory] = true
    #expect(features.recordsSleep && features.generatesReports)
    #expect(!features.recordsHealth)
    features[.appActivity] = false
    #expect(!features.recordsAppEnergy && features[.appEnergyHistory])
    features[.appActivity] = true
    #expect(features.recordsAppEnergy)
}

private func featureSample(_ date: Date, level: Double = 80, state: BatteryState = .discharging) -> BatterySnapshot {
    .init(date: date, level: level, state: state, cycleCount: 100, designCapacity: 6_000,
          fullCapacity: 5_000, voltage: 12, currentMA: state == .charging ? 1_000 : -1_000)
}

@Test func disabledInsightCategoriesAreExcludedWithoutDeletingRecords() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
    let now = Date.now, start = now.addingTimeInterval(-300)
    let first = featureSample(start), last = featureSample(start.addingTimeInterval(60), level: 79)
    try await store.append(first, recordHealthHistory: false)
    let initial = try await store.insights(range: .day, reportEnd: now, now: now)
    #expect(initial.health.isEmpty)
    try await store.append(last)
    try await store.recordEvent(.init(date: start, kind: .connected, title: "Connected"))
    var sleep = SleepSession(before: first); sleep.after = last
    try await store.recordSleep(sleep)
    try await store.recordAppEnergy([.init(identity: "test", name: "Test app", bundlePath: nil,
        end: last.date, seconds: 60, watts: 2, cpuPercent: 10)])
    var features = FeaturePreferences()
    for feature in [CellFeature.healthHistory, .sleepTracking, .appEnergyHistory, .timeline] { features[feature] = false }
    let filtered = try await store.insights(range: .day, reportEnd: now, now: now, features: features, includeBaseline: false)
    #expect(filtered.health.isEmpty && filtered.sleep.isEmpty && filtered.apps.isEmpty && filtered.events.isEmpty && filtered.sessions.isEmpty)
    let report = try #require(filtered.report)
    #expect(report.apps.isEmpty && report.sleeps.isEmpty && report.healthChange == nil)
    features[.reports] = false
    #expect(try await store.insights(range: .day, reportEnd: now, features: features).report == nil)
    features[.batteryHistory] = false
    #expect(try await store.insights(range: .day, reportEnd: now, features: features).report == nil)
    #expect(try await store.samples(since: start).count == 2)
    let restored = try await store.insights(range: .day, reportEnd: now, now: now)
    #expect(restored.health.count == 1 && restored.sleep.count == 1 && restored.events.count == 1 && restored.apps.count == 1)
    await store.close()
}

@Test func statisticsAndSessionsDoNotBridgePausedHistory() throws {
    let start = Date.now, firstSession = UUID(), secondSession = UUID()
    var a = featureSample(start, state: .charging)
    var b = featureSample(start.addingTimeInterval(60), level: 81, state: .charging)
    var c = featureSample(start.addingTimeInterval(120), level: 82, state: .charging)
    a.recordingID = firstSession; b.recordingID = firstSession; c.recordingID = secondSession
    #expect(BatteryStatistics(samples: [a, b, c]).observedSeconds == 60)
    let sessions = InsightMath.chargingSessions([a, b, c], now: c.date)
    #expect(sessions.count == 2)
    #expect(abs(InsightMath.dailyEnergy([a, b, c]).reduce(0) { $0 + $1.chargedWh } - 0.2) < 0.0001)
    // Old JSON payloads have no recording identifier and remain readable.
    let legacy = featureSample(start)
    #expect(try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(legacy)).recordingID == nil)
}
