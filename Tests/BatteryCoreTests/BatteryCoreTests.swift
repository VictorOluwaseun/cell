import Foundation
import Testing
@testable import BatteryCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private func sample(_ minute: Double = 0, level: Double = 80, state: BatteryState = .discharging,
                    amps: Double? = -1_000) -> BatterySnapshot {
    BatterySnapshot(date: start.addingTimeInterval(minute * 60), level: level, state: state,
                    cycleCount: 120, designCapacity: 5_000, fullCapacity: 4_500,
                    voltage: 12, currentMA: amps)
}

@Test func electricalUnits() {
    let s = sample()
    #expect(s.batteryWatts == -12)
    #expect(s.health == 90)
    #expect(abs(s.instantaneousRate! - (-22.22222222)) < 0.00001)
    #expect(abs(s.cRate! - 0.22222222) < 0.00001)
}

@Test func unavailableSensorsStayUnavailable() {
    let s = BatterySnapshot(level: 50, state: .discharging, designCapacity: 0, fullCapacity: 0)
    #expect(s.health == nil)
    #expect(s.batteryWatts == nil)
    #expect(s.instantaneousRate == nil)
}

@Test func integratesContinuousPowerAndCycles() {
    let samples = (0...60).map { sample(Double($0), level: 100 - Double($0) / 2) }
    let stats = BatteryStatistics(samples: samples)
    #expect(stats.batterySeconds == 3_600)
    #expect(abs(stats.dischargedWh - 12) < 0.0001)
    #expect(abs(stats.averageDrainWatts! - 12) < 0.0001)
    #expect(abs(stats.equivalentCycles - 0.3) < 0.0001)
    #expect(abs(stats.cyclesPerDay! - 7.2) < 0.0001)
}

@Test func excludesSleepAndPowerTransitions() {
    let stats = BatteryStatistics(samples: [sample(0), sample(60, level: 40),
        sample(61, level: 41, state: .charging, amps: 1_000)])
    #expect(stats.observedSeconds == 0)
    #expect(stats.dischargedWh == 0)
    #expect(stats.equivalentCycles == 0)
    #expect(stats.cyclesPerDay == nil)
}

@Test func missingPowerDoesNotBecomeZeroWatts() {
    let stats = BatteryStatistics(samples: [sample(0, amps: nil), sample(1, amps: nil)])
    #expect(stats.batterySeconds == 60)
    #expect(stats.measuredBatterySeconds == 0)
    #expect(stats.averageDrainWatts == nil)
}

@Test func chargeEnergyHasCorrectSign() {
    let stats = BatteryStatistics(samples: [sample(0, state: .charging, amps: 2_000), sample(1, state: .charging, amps: 2_000)])
    #expect(abs(stats.chargedWh - 0.4) < 0.0001)
    #expect(stats.dischargedWh == 0)
}

@Test func smoothedTrendAndWarmup() {
    #expect(Analytics.ratePerHour([sample(0), sample(1)]) == nil)
    let samples = (0...10).map { sample(Double($0), level: 80 - Double($0) / 2) }
    #expect(abs(Analytics.ratePerHour(samples)! + 30) < 0.00001)
    #expect(Analytics.ratePerHour(samples + [sample(11, state: .charging)]) == nil)
    #expect(Analytics.ratePerHour(samples + [sample(60)]) == nil)
}

@Test func chartSamplingPreservesEndpoints() {
    let input = (0..<1_000).map { sample(Double($0)) }
    let result = Analytics.chartSamples(input, limit: 100)
    #expect(result.count == 100)
    #expect(result.first == input.first)
    #expect(result.last == input.last)
}

@Test func lowAlertLatchesAndRearmsWithHysteresis() {
    let rule = ChargeAlert(direction: .below, threshold: 20)
    var evaluator = AlertEvaluator()
    #expect(evaluator.evaluate(sample(level: 20), rules: [rule]).count == 1)
    #expect(evaluator.evaluate(sample(level: 19), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 21), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 20), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 22), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 20), rules: [rule]).count == 1)
}

@Test func highAlertRequiresExternalPower() {
    let rule = ChargeAlert(direction: .above, threshold: 80)
    var evaluator = AlertEvaluator()
    #expect(evaluator.evaluate(sample(level: 90), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 80, state: .pluggedIn), rules: [rule]).count == 1)
    #expect(evaluator.evaluate(sample(level: 81, state: .charging), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 78), rules: [rule]).isEmpty)
    #expect(evaluator.evaluate(sample(level: 80, state: .charging), rules: [rule]).count == 1)
}

@Test func disabledAndUnavailableAlertsDoNotFire() {
    var evaluator = AlertEvaluator()
    #expect(evaluator.evaluate(sample(level: 5), rules: [ChargeAlert(direction: .below, threshold: 20, enabled: false)]).isEmpty)
    #expect(evaluator.evaluate(.unavailable, rules: [ChargeAlert(direction: .below, threshold: 20)]).isEmpty)
}

@Test func editingOneRuleDoesNotRearmOthers() {
    var evaluator = AlertEvaluator()
    let low = ChargeAlert(direction: .below, threshold: 20)
    var high = ChargeAlert(direction: .above, threshold: 80)
    #expect(evaluator.evaluate(sample(level: 10), rules: [low, high]).count == 1)
    high.enabled = false
    #expect(evaluator.evaluate(sample(level: 10), rules: [low, high]).isEmpty)
}

@Test func reenabledAlertCanFireAgain() {
    var evaluator = AlertEvaluator()
    var low = ChargeAlert(direction: .below, threshold: 20)
    #expect(evaluator.evaluate(sample(level: 10), rules: [low]).count == 1)
    low.enabled = false
    #expect(evaluator.evaluate(sample(level: 10), rules: [low]).isEmpty)
    low.enabled = true
    #expect(evaluator.evaluate(sample(level: 10), rules: [low]).count == 1)
}

@Test func sqliteRoundTripFilteringAndClear() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
    try await store.append(sample(0))
    try await store.append(sample(1, level: 79))
    try await store.append(sample(1, level: 78))
    let all = try await store.samples(since: start)
    #expect(all.count == 2)
    #expect(all.last?.level == 78)
    let filtered = try await store.samples(since: start.addingTimeInterval(30))
    #expect(filtered.count == 1)
    try await store.clear()
    #expect(try await store.samples(since: .distantPast).isEmpty)
    await store.close()
}

@Test func databaseSurvivesReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("history.sqlite")
    let store = try HistoryStore(url: url)
    try await store.append(sample())
    await store.close()
    let reopened = try HistoryStore(url: url)
    #expect(try await reopened.samples(since: start).first == sample())
    await reopened.close()
}

@Test func retentionRemovesOldHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
    try await store.append(sample())
    let later = sample(91 * 24 * 60)
    try await store.append(later)
    #expect(try await store.samples(since: .distantPast) == [later])
    await store.close()
}

@Test func csvUsesStableUnitsAndEmptyMissingValues() {
    let csv = HistoryCSV.encode([BatterySnapshot(date: start, level: 50, state: .pluggedIn)])
    #expect(csv.contains("battery_watts,system_watts,current_mA,voltage_V,temperature_C,cycles,health_percent"))
    #expect(csv.contains(",50.0,pluggedIn,,,,,,,\n"))
}
