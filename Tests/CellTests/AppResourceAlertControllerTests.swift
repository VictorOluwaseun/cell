import Foundation
import Testing
import BatteryCore
@testable import Cell

private let resourceControllerEpoch = Date(timeIntervalSince1970: 1_800_000_000)
@MainActor private func isolatedResourceController() -> (AppResourceAlertController, UserDefaults, String) {
    let domain = "Cell-resource-tests-\(UUID().uuidString)"
    // Each test owns a separate suite and never changes the app's preferences or notification permission.
    let isolated = UserDefaults(suiteName: domain)!
    return (AppResourceAlertController(defaults: isolated, now: resourceControllerEpoch, uptime: 1_000), isolated, domain)
}
private func resourceActivity() -> AppActivity {
    .init(id: 42, name: "Example", bundlePath: "/Applications/Example.app", cpuPercent: 150, watts: 6,
          wakeups: 0, memory: 5 * 1_073_741_824, processes: 2, sampledSeconds: 30, processStarted: 1)
}
@MainActor private func enableResourceCPU(_ controller: AppResourceAlertController) {
    var preferences = controller.preferences; preferences.cpuEnabled = true; preferences.cooldownSeconds = 300; controller.update(preferences)
}
@MainActor private func consumeResource(_ controller: AppResourceAlertController, _ second: Double, apps: [AppActivity] = [resourceActivity()]) async {
    await controller.consume(apps, batteryState: .discharging, at: resourceControllerEpoch.addingTimeInterval(second), uptime: 1_000 + second)
}

@Test @MainActor func appResourceControllerPersistsChoicesAndKeepsAlertsOptIn() {
    let (controller, defaults, domain) = isolatedResourceController()
    defer { defaults.removePersistentDomain(forName: domain) }
    #expect(!controller.preferences.anyEnabled && !controller.active)
    enableResourceCPU(controller)
    var preferences = controller.preferences; preferences.memoryEnabled = true; preferences.memoryGiB = 8; controller.update(preferences)
    let restored = AppResourceAlertController(defaults: defaults)
    #expect(restored.preferences == controller.preferences && restored.active)
    controller.setMonitoringEnabled(false)
    #expect(!controller.active && controller.preferences.cpuEnabled)
}

@Test @MainActor func appResourceControllerUsesOnlyIdentifiedRunningApps() async {
    let (controller, defaults, domain) = isolatedResourceController()
    defer { defaults.removePersistentDomain(forName: domain) }
    enableResourceCPU(controller)
    var process = resourceActivity(); process.bundlePath = nil
    var missingStart = resourceActivity(); missingStart.processStarted = nil
    for second in [0.0, 30, 60] { await consumeResource(controller, second, apps: [process, missingStart]) }
    #expect(controller.recent.isEmpty)
    for second in [90.0, 120, 150] { await consumeResource(controller, second) }
    #expect(controller.recent.count == 1 && controller.recent[0].name == "Example")
}

@Test @MainActor func appResourceControllerPersistsCooldownBeforeDeliveryAndAcrossRestart() async {
    let (controller, defaults, domain) = isolatedResourceController()
    defer { defaults.removePersistentDomain(forName: domain) }
    enableResourceCPU(controller)
    var deliveries = 0
    controller.deliver = { _, enabled in
        #expect(defaults.data(forKey: "appResourceAlertCooldowns") != nil)
        if enabled() { deliveries += 1 }
    }
    for second in [0.0, 30, 60] { await consumeResource(controller, second) }
    #expect(deliveries == 1 && controller.recent.count == 1)
    controller.clearRecent(); await consumeResource(controller, 90)
    #expect(controller.recent.isEmpty && deliveries == 1)
    let restored = AppResourceAlertController(defaults: defaults, now: resourceControllerEpoch.addingTimeInterval(90), uptime: 1_090)
    restored.deliver = { _, enabled in if enabled() { deliveries += 1 } }
    for second in stride(from: 90.0, through: 330, by: 30) { await consumeResource(restored, second) }
    #expect(deliveries == 1)
    await consumeResource(restored, 360)
    #expect(deliveries == 2)
}

@Test @MainActor func appResourceControllerMonitoringPauseDiscardsEvidence() async {
    let (controller, defaults, domain) = isolatedResourceController()
    defer { defaults.removePersistentDomain(forName: domain) }
    enableResourceCPU(controller)
    await consumeResource(controller, 0); await consumeResource(controller, 30)
    controller.setMonitoringEnabled(false); await consumeResource(controller, 60)
    controller.setMonitoringEnabled(true); await consumeResource(controller, 90); await consumeResource(controller, 120)
    #expect(controller.recent.isEmpty)
    await consumeResource(controller, 150)
    #expect(controller.recent.count == 1 && controller.preferences.cpuEnabled)
}

@Test @MainActor func appResourceControllerSleepAndShutdownStopObservation() async {
    let (controller, defaults, domain) = isolatedResourceController()
    defer { defaults.removePersistentDomain(forName: domain) }
    enableResourceCPU(controller)
    await consumeResource(controller, 0); await consumeResource(controller, 30)
    controller.suspend(); await consumeResource(controller, 60)
    controller.resume(); await consumeResource(controller, 90); await consumeResource(controller, 120)
    #expect(controller.recent.isEmpty)
    await consumeResource(controller, 150); #expect(controller.recent.count == 1)
    controller.shutdown(); await consumeResource(controller, 1_000)
    #expect(!controller.active && controller.recent.count == 1)
}

@MainActor private final class ResourceDeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0; started?.resume(); started = nil } }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@Test(arguments: ["preference", "monitoring", "sleep"]) @MainActor
func appResourceControllerCancelsPendingNotificationsWhenPaused(_ reason: String) async {
    let (controller, defaults, domain) = isolatedResourceController(), gate = ResourceDeliveryGate()
    defer { defaults.removePersistentDomain(forName: domain) }
    enableResourceCPU(controller)
    var deliveries = 0
    controller.deliver = { _, enabled in await gate.pause(); if enabled() { deliveries += 1 } }
    await consumeResource(controller, 0); await consumeResource(controller, 30)
    let task = Task { await consumeResource(controller, 60) }
    await gate.waitUntilStarted()
    switch reason {
    case "preference": var value = controller.preferences; value.cpuEnabled = false; controller.update(value)
    case "monitoring": controller.setMonitoringEnabled(false)
    default: controller.suspend(); controller.resume()
    }
    gate.finish(); await task.value
    #expect(deliveries == 0)
}

@Test @MainActor func appResourceControllerValidatesEditsAndIgnoresUnchangedSettings() async {
    let (controller, defaults, domain) = isolatedResourceController()
    defer { defaults.removePersistentDomain(forName: domain) }
    enableResourceCPU(controller)
    await consumeResource(controller, 0); await consumeResource(controller, 30)
    controller.update(controller.preferences)
    await consumeResource(controller, 60); #expect(controller.recent.count == 1)
    var invalid = controller.preferences; invalid.cpuThreshold = .infinity; invalid.memoryGiB = -1; invalid.sustainedSeconds = 0
    controller.update(invalid)
    #expect(controller.preferences.cpuThreshold == 100 && controller.preferences.memoryGiB == 0.25 && controller.preferences.sustainedSeconds == 60)
    defaults.set(Data("invalid".utf8), forKey: "appResourceAlertPreferences")
    #expect(!AppResourceAlertController(defaults: defaults).preferences.anyEnabled)
}
