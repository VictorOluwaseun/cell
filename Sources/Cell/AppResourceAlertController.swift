import Foundation
import Combine
import BatteryCore

@MainActor
final class AppResourceAlertController: ObservableObject {
    @Published private(set) var preferences: AppResourceAlertPreferences
    @Published private(set) var recent: [AppResourceAlert] = []
    @Published private(set) var monitoringEnabled = true
    var deliver: (@MainActor (AppResourceAlert, @escaping @MainActor () -> Bool) async -> Void)?
    private let defaults: UserDefaults
    private var evaluator: AppResourceAlertEvaluator
    private var revision = 0
    private var suspended = false
    private var batteryState: BatteryState = .unavailable
    private static let settingsKey = "appResourceAlertPreferences"
    private static let cooldownKey = "appResourceAlertCooldowns"
    var active: Bool { monitoringEnabled && !suspended && preferences.anyEnabled }

    init(defaults: UserDefaults, now: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.defaults = defaults
        preferences = (defaults.data(forKey: Self.settingsKey).flatMap {
            try? JSONDecoder().decode(AppResourceAlertPreferences.self, from: $0)
        } ?? .init()).validated
        let cooldowns = defaults.data(forKey: Self.cooldownKey).flatMap {
            try? JSONDecoder().decode([AppResourceCooldown].self, from: $0)
        } ?? []
        evaluator = .init(cooldowns: cooldowns, at: now, uptime: uptime)
    }
    func update(_ value: AppResourceAlertPreferences) {
        let value = value.validated
        guard preferences != value else { return }
        preferences = value; resetObservations()
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.settingsKey) }
    }
    func setMonitoringEnabled(_ value: Bool) {
        guard value != monitoringEnabled else { return }
        monitoringEnabled = value; resetObservations()
    }
    func suspend() { suspended = true; resetObservations() }
    func resume() { suspended = false; resetObservations() }
    func resetObservations() { revision += 1; evaluator.resetObservations() }
    func observeBatteryState(_ value: BatteryState) {
        if value.onAC != batteryState.onAC || (value == .unavailable) != (batteryState == .unavailable) {
            evaluator.resetPowerObservations()
        }
        batteryState = value
    }
    func clearRecent() { recent.removeAll() }
    func shutdown() { suspended = true; resetObservations() }

    func consume(_ apps: [AppActivity], batteryState: BatteryState, at date: Date = .now,
                 uptime: Double = ProcessInfo.processInfo.systemUptime) async {
        guard active else { return }
        observeBatteryState(batteryState)
        let readings = apps.compactMap { app -> AppResourceReading? in
            guard let path = app.bundlePath, !path.isEmpty, let started = app.processStarted else { return nil }
            return .init(identity: path, name: app.name, pid: app.id, started: started,
                         cpuPercent: app.cpuPercent, memoryBytes: app.memory, watts: app.watts, sampledSeconds: app.sampledSeconds)
        }
        let alerts = evaluator.evaluate(readings, preferences: preferences, at: date, uptime: uptime, batteryState: batteryState)
        guard !alerts.isEmpty else { return }
        // Persist cooldowns before awaiting delivery, so a restart cannot cause an immediate repeat.
        if let data = try? JSONEncoder().encode(evaluator.cooldowns) { defaults.set(data, forKey: Self.cooldownKey) }
        recent.insert(contentsOf: alerts, at: 0)
        if recent.count > 20 { recent.removeLast(recent.count - 20) }
        let token = revision
        for alert in alerts {
            await deliver?(alert, { [weak self] in self.map { $0.active && $0.revision == token } ?? false })
        }
    }
}
