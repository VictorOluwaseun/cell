import Foundation
import Testing
@testable import BatteryCore

private let resourceEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private func resourcePreferences() -> AppResourceAlertPreferences {
    var settings = AppResourceAlertPreferences(); settings.cpuEnabled = true; settings.cooldownSeconds = 300; return settings
}
private func resourceReading(_ identity: String = "/Applications/Example.app", cpu: Double = 150,
                             memory: UInt64 = 5 * 1_073_741_824, watts: Double? = 6, started: UInt64 = 1,
                             seconds: Double = 30) -> AppResourceReading {
    .init(identity: identity, name: "Example", pid: 100, started: started, cpuPercent: cpu,
          memoryBytes: memory, watts: watts, sampledSeconds: seconds)
}
private func resourceEvaluate(_ evaluator: inout AppResourceAlertEvaluator, _ seconds: Double,
                              apps: [AppResourceReading] = [resourceReading()], settings: AppResourceAlertPreferences = resourcePreferences(),
                              state: BatteryState = .discharging) -> [AppResourceAlert] {
    evaluator.evaluate(apps, preferences: settings, at: resourceEpoch.addingTimeInterval(seconds),
                       uptime: 1_000 + seconds, batteryState: state)
}

@Test func appResourceAlertsAreOptInAndValidateSavedThresholds() {
    var settings = AppResourceAlertPreferences(), evaluator = AppResourceAlertEvaluator()
    #expect(!settings.anyEnabled)
    for second in stride(from: 0.0, through: 300, by: 30) { #expect(resourceEvaluate(&evaluator, second, settings: settings).isEmpty) }
    settings.cpuThreshold = .nan; settings.memoryGiB = -.infinity; settings.powerWatts = -1
    settings.sustainedSeconds = .infinity; settings.cooldownSeconds = 1
    let valid = settings.validated
    #expect(valid.cpuThreshold == 100 && valid.memoryGiB == 4 && valid.powerWatts == 0.1)
    #expect(valid.sustainedSeconds == 60 && valid.cooldownSeconds == 900)
}

@Test func appResourceAlertsIgnoreSpikesAndCombineSustainedMetrics() throws {
    var settings = resourcePreferences(); settings.memoryEnabled = true; settings.powerEnabled = true
    var evaluator = AppResourceAlertEvaluator()
    #expect(resourceEvaluate(&evaluator, 0, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 30, apps: [resourceReading(cpu: 10, memory: 0, watts: 0)], settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 60, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 90, settings: settings).isEmpty)
    let alert = try #require(resourceEvaluate(&evaluator, 120, settings: settings).first)
    #expect(alert.breaches.map(\.kind) == [.cpu, .memory, .power])
    #expect(alert.breaches[1].value == 5 && alert.name == "Example")
    #expect(alert.detail.contains("150%") && alert.detail.contains("5 GiB") && alert.detail.contains("6 W"))
    #expect(resourceEvaluate(&evaluator, 150, settings: settings).isEmpty)
}

@Test func appPowerAlertsRequireMeasuredWattsAndRespectPowerSource() {
    var settings = AppResourceAlertPreferences(); settings.powerEnabled = true
    var evaluator = AppResourceAlertEvaluator()
    for second in [0.0, 30, 60] { #expect(resourceEvaluate(&evaluator, second, apps: [resourceReading(cpu: 900, watts: nil)], settings: settings).isEmpty) }
    for second in [90.0, 120, 150] { #expect(resourceEvaluate(&evaluator, second, settings: settings, state: .charging).isEmpty) }
    #expect(resourceEvaluate(&evaluator, 180, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 210, settings: settings, state: .unavailable).isEmpty)
    #expect(resourceEvaluate(&evaluator, 240, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 270, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 300, settings: settings).count == 1)
    evaluator = .init(); settings.powerOnlyOnBattery = false
    #expect(resourceEvaluate(&evaluator, 0, settings: settings, state: .full).isEmpty)
    #expect(resourceEvaluate(&evaluator, 30, settings: settings, state: .full).isEmpty)
    #expect(resourceEvaluate(&evaluator, 60, settings: settings, state: .full).first?.breaches.first?.kind == .power)
}

@Test func appMemoryAndMultiCoreCPUAlertsWorkWithoutPowerReadings() {
    var settings = resourcePreferences(); settings.cpuThreshold = 200; settings.memoryEnabled = true
    var evaluator = AppResourceAlertEvaluator()
    for second in [0.0, 30] { #expect(resourceEvaluate(&evaluator, second, apps: [resourceReading(cpu: 250, watts: nil)], settings: settings, state: .unavailable).isEmpty) }
    #expect(resourceEvaluate(&evaluator, 60, apps: [resourceReading(cpu: 250, watts: nil)], settings: settings, state: .unavailable).first?.breaches.map(\.kind) == [.cpu, .memory])
    evaluator = .init()
    for second in [0.0, 30] { #expect(resourceEvaluate(&evaluator, second, apps: [resourceReading(cpu: .nan, watts: nil)], settings: settings).isEmpty) }
    #expect(resourceEvaluate(&evaluator, 60, apps: [resourceReading(cpu: .nan, watts: nil)], settings: settings).first?.breaches.map(\.kind) == [.memory])
}

@Test func appResourceAlertsNeedRecoveryAndCooldownBeforeRepeating() {
    var evaluator = AppResourceAlertEvaluator()
    for second in [0.0, 30] { _ = resourceEvaluate(&evaluator, second) }
    #expect(resourceEvaluate(&evaluator, 60).count == 1)
    for second in stride(from: 90.0, through: 600, by: 30) { #expect(resourceEvaluate(&evaluator, second).isEmpty) }
    // Threshold noise does not rearm a reported episode.
    #expect(resourceEvaluate(&evaluator, 630, apps: [resourceReading(cpu: 95)]).isEmpty)
    #expect(resourceEvaluate(&evaluator, 660).isEmpty)
    #expect(resourceEvaluate(&evaluator, 690, apps: [resourceReading(cpu: 90)]).isEmpty)
    #expect(resourceEvaluate(&evaluator, 720).isEmpty)
    #expect(resourceEvaluate(&evaluator, 750).isEmpty)
    #expect(resourceEvaluate(&evaluator, 780).count == 1)
    _ = resourceEvaluate(&evaluator, 810, apps: [resourceReading(cpu: 50)])
    for second in stride(from: 840.0, through: 1_050, by: 30) { #expect(resourceEvaluate(&evaluator, second).isEmpty) }
    #expect(resourceEvaluate(&evaluator, 1_080).count == 1)
}

@Test func appResourceAlertsSpaceSimultaneousAppsAndCombineDuplicateInstances() {
    var evaluator = AppResourceAlertEvaluator()
    let apps = [resourceReading("/A.app", cpu: 150), resourceReading("/B.app", cpu: 300)]
    for second in [0.0, 30] { _ = resourceEvaluate(&evaluator, second, apps: apps + apps) }
    #expect(resourceEvaluate(&evaluator, 60, apps: apps + apps).first?.identity == "/B.app")
    #expect(resourceEvaluate(&evaluator, 90, apps: apps).isEmpty)
    #expect(resourceEvaluate(&evaluator, 120, apps: apps).first?.identity == "/A.app")
}

@Test func appResourceAlertsNeverBridgeMissingAppsGapsOrReusedPIDs() {
    var evaluator = AppResourceAlertEvaluator()
    _ = resourceEvaluate(&evaluator, 0); _ = resourceEvaluate(&evaluator, 30)
    #expect(resourceEvaluate(&evaluator, 60, apps: [resourceReading(started: 2)]).isEmpty)
    #expect(resourceEvaluate(&evaluator, 90, apps: [resourceReading(started: 2)]).isEmpty)
    #expect(resourceEvaluate(&evaluator, 120, apps: []).isEmpty)
    #expect(resourceEvaluate(&evaluator, 150).isEmpty)
    // An unobserved interval must not count towards the sustained period.
    #expect(resourceEvaluate(&evaluator, 240).isEmpty)
    #expect(resourceEvaluate(&evaluator, 270).isEmpty)
    #expect(resourceEvaluate(&evaluator, 300).count == 1)
}

@Test func appResourceAlertsIgnoreInvalidOrOutOfOrderSamples() {
    var evaluator = AppResourceAlertEvaluator()
    var invalid = resourceReading(); invalid.pid = 0
    for second in [0.0, 30, 60] { #expect(resourceEvaluate(&evaluator, second, apps: [invalid, resourceReading(seconds: 91), resourceReading(started: 0)]).isEmpty) }
    _ = resourceEvaluate(&evaluator, 90)
    #expect(resourceEvaluate(&evaluator, 80).isEmpty)
    #expect(resourceEvaluate(&evaluator, 90).isEmpty)
    #expect(resourceEvaluate(&evaluator, 120).isEmpty)
    #expect(resourceEvaluate(&evaluator, 150).count == 1)
}

@Test func appResourceCooldownsSurviveRestartAndUseMonotonicTime() {
    let saved = AppResourceCooldown(identity: "/Applications/Example.app", date: resourceEpoch.addingTimeInterval(60))
    var evaluator = AppResourceAlertEvaluator(cooldowns: [saved], at: resourceEpoch.addingTimeInterval(120), uptime: 1_120)
    for second in stride(from: 120.0, through: 330, by: 30) { #expect(resourceEvaluate(&evaluator, second).isEmpty) }
    #expect(resourceEvaluate(&evaluator, 360).count == 1)
    evaluator.resetObservations()
    // Wall-clock jumps do not expire an in-session cooldown.
    for second in [390.0, 420, 450] {
        #expect(evaluator.evaluate([resourceReading()], preferences: resourcePreferences(),
            at: resourceEpoch.addingTimeInterval(100_000), uptime: 1_000 + second, batteryState: .discharging).isEmpty)
    }
    let future = AppResourceCooldown(identity: saved.identity, date: resourceEpoch.addingTimeInterval(10_000))
    let restored = AppResourceAlertEvaluator(cooldowns: [future], at: resourceEpoch, uptime: 1_000)
    #expect(restored.cooldowns.first?.date == resourceEpoch)
}

@Test func appResourceConfigurationAndSleepResetsDiscardOldEvidence() {
    var settings = resourcePreferences(), evaluator = AppResourceAlertEvaluator()
    _ = resourceEvaluate(&evaluator, 0); _ = resourceEvaluate(&evaluator, 30)
    evaluator.resetObservations()
    #expect(resourceEvaluate(&evaluator, 60).isEmpty)
    settings.cpuThreshold = 120
    #expect(resourceEvaluate(&evaluator, 90, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 120, settings: settings).isEmpty)
    #expect(resourceEvaluate(&evaluator, 150, settings: settings).count == 1)
}

@Test func appResourceCooldownStorageIsBoundedAndDiscardsExpiredRecords() {
    let saved = (0..<300).map { AppResourceCooldown(identity: "/App\($0).app", date: resourceEpoch) }
    let evaluator = AppResourceAlertEvaluator(cooldowns: saved, at: resourceEpoch, uptime: 1_000)
    #expect(evaluator.cooldowns.count == 256)
    let expired = AppResourceAlertEvaluator(cooldowns: saved, at: resourceEpoch.addingTimeInterval(3_600), uptime: 4_600)
    #expect(expired.cooldowns.isEmpty)
}

@Test func appResourcePowerSourceChangesDoNotInterruptCPUOrMemoryEvidence() {
    var settings = resourcePreferences(); settings.powerEnabled = true; settings.memoryEnabled = true
    var evaluator = AppResourceAlertEvaluator()
    _ = resourceEvaluate(&evaluator, 0, settings: settings); _ = resourceEvaluate(&evaluator, 30, settings: settings)
    evaluator.resetPowerObservations()
    #expect(resourceEvaluate(&evaluator, 60, settings: settings).first?.breaches.map(\.kind) == [.cpu, .memory])
}
