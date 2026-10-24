import AppKit
import SwiftUI
import IOKit.ps
import BatteryCore

struct ChartSegment: Identifiable {
    var id: Int
    var samples: [BatterySnapshot]
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var snapshot = BatterySnapshot.unavailable
    @Published private(set) var history: [BatterySnapshot] = []
    @Published private(set) var chart: [BatterySnapshot] = []
    @Published private(set) var chartSegments: [ChartSegment] = []
    @Published private(set) var statistics = BatteryStatistics(samples: [])
    @Published private(set) var apps: [AppActivity] = []
    @Published private(set) var lastAppUpdate: Date?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var range: HistoryRange = .day { didSet { Task { await loadHistory() } } }
    @Published var alerts: [ChargeAlert] = [] {
        didSet { saveAlerts(); syncAlarmRules() }
    }
    @Published var interval: Double = 5 { didSet { defaults.set(interval, forKey: "sampleInterval") } }
    @Published var sound = true { didSet { defaults.set(sound, forKey: "alertSound"); notifications.alarm.setSoundEnabled(sound) } }
    @Published var showPercentage = true { didSet { defaults.set(showPercentage, forKey: "showPercentage") } }
    @Published var features: FeaturePreferences {
        didSet { updateFeatures(from: oldValue) }
    }
    var activeAlerts: [ChargeAlert] { features[.chargeAlerts] ? alerts : [] }
    private var activeTimeReminders: [TimedChargeReminder] { features[.chargeAlerts] ? timeReminders.reminders : [] }
    let notifications: NotificationService
    let timeReminders: TimedReminderController
    let appResourceAlerts: AppResourceAlertController
    let chargeLimit = ChargeLimitController()
    let startup: StartupController
    let applicationQuitting = ApplicationQuitController()
    let insights: InsightsController
    private let defaults: UserDefaults
    private let engine = TelemetryEngine()
    private var store: HistoryStore?
    private var evaluator = AlertEvaluator()
    private var recent: [BatterySnapshot] = []
    private var loop: Task<Void, Never>?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var clockObservers: [NSObjectProtocol] = []
    private var lastSave = Date.distantPast
    private var lastApps = Date.distantPast
    private var sampling = false
    private var clearingHistory = false
    private var asleep = false
    private var historyGeneration = 0
    private var recordingID = UUID()
    private var processGeneration = 0
    private var needsProcessReset = true
    var trend: Double? { Analytics.ratePerHour(recent) }
    var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Warm"
        case .serious: "High"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    init(defaults: UserDefaults = .standard) {
        self.notifications = NotificationService(defaults: defaults)
        self.timeReminders = TimedReminderController(defaults: defaults)
        self.appResourceAlerts = AppResourceAlertController(defaults: defaults)
        // Detect a fresh installation before other controllers save their initial preferences.
        self.startup = StartupController(defaults: defaults)
        self.insights = InsightsController(defaults: defaults)
        self.defaults = defaults
        features = FeaturePreferences(defaults: defaults)
        if let data = defaults.data(forKey: "chargeAlerts"), let saved = try? JSONDecoder().decode([ChargeAlert].self, from: data) {
            alerts = saved
        } else {
            alerts = [ChargeAlert(direction: .below, threshold: 20, enabled: false),
                      ChargeAlert(direction: .above, threshold: 80, enabled: false)]
        }
        let savedInterval = defaults.double(forKey: "sampleInterval")
        interval = [2.0, 5, 15, 30].contains(savedInterval) ? savedInterval : 5
        sound = defaults.object(forKey: "alertSound") as? Bool ?? true
        showPercentage = defaults.object(forKey: "showPercentage") as? Bool ?? true
        notifications.remindersEnabled = features[.chargeAlerts]
        syncAlarmRules()
        insights.setFeatures(features)
        appResourceAlerts.setMonitoringEnabled(features[.appActivity])
        appResourceAlerts.deliver = { [weak self] alert, enabled in
            guard let self, enabled() else { return }
            await self.insights.record(.init(date: alert.date, kind: .alert, title: alert.title, detail: alert.detail))
            _ = await self.notifications.deliverInsight(id: "cell-app-resource-\(alert.id.uuidString)", title: alert.title,
                body: alert.detail + " Open App activity in Cell to review.", sound: self.sound, enabled: enabled)
        }
        notifications.alarm.readBattery = { [engine] in await engine.battery() }
        timeReminders.readBattery = { [engine] in await engine.battery() }
        timeReminders.rulesDidChange = { [weak self] in self?.syncAlarmRules() }
        timeReminders.deliver = { [weak self] occurrence in
            guard let self, self.timeReminders.isCurrent(occurrence) else { return }
            self.notice = occurrence.rule.action.reminderTitle
            _ = await self.notifications.deliver(occurrence, sound: self.sound,
                enabled: { self.timeReminders.isCurrent(occurrence) })
            await self.insights.record(.init(date: .now, kind: .alert, title: occurrence.rule.action.reminderTitle,
                detail: "Scheduled for \(occurrence.date.formatted(date: .abbreviated, time: .shortened))."))
        }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            store = try HistoryStore(url: base.appendingPathComponent("Cell/history.sqlite"))
        } catch { self.error = "History could not be opened: \(error.localizedDescription)" }
        insights.connect(store)
        applicationQuitting.onTermination = { [weak self] target in
            guard let self else { return }
            self.processGeneration += 1
            self.apps.removeAll { $0.quitTarget == target }
            self.appResourceAlerts.resetObservations()
        }
        installObservers()
        timeReminders.start(enabled: features[.chargeAlerts])
        loop = Task { [weak self] in
            await self?.startup.configureFirstLaunch()
            while !Task.isCancelled {
                guard let self else { return }
                if !self.asleep { await self.refresh() }
                let seconds = NSApp.isActive ? self.interval : max(15, self.interval)
                try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(500))
            }
        }
    }

    private func updateFeatures(from old: FeaturePreferences) {
        guard features != old else { return }
        features.save(to: defaults)
        insights.setFeatures(features)
        if !features[.applicationQuitting] || !features[.appActivity] {
            applicationQuitting.cancelRequests(); applicationQuitting.dismissMessage()
        }
        if features[.chargeAlerts] != old[.chargeAlerts] {
            evaluator = AlertEvaluator()
            notifications.remindersEnabled = features[.chargeAlerts]
            timeReminders.setEnabled(features[.chargeAlerts])
            syncAlarmRules()
        }
        if features[.appActivity] != old[.appActivity] || features.recordsAppEnergy != old.recordsAppEnergy {
            processGeneration += 1; needsProcessReset = true; lastApps = .distantPast
            apps = []; lastAppUpdate = nil
            appResourceAlerts.setMonitoringEnabled(features[.appActivity])
            appResourceAlerts.resetObservations()
        }
        if features[.batteryHistory] != old[.batteryHistory] {
            historyGeneration += 1; lastSave = .distantPast; recordingID = UUID()
            if !features[.batteryHistory] { history = []; chart = []; chartSegments = []; statistics = .init(samples: []) }
            else { Task { await loadHistory() } }
        }
    }

    private func syncAlarmRules() { notifications.alarm.updateRules(activeAlerts, timeRules: activeTimeReminders) }

    private func installObservers() {
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in await monitor.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asleep = true; self.timeReminders.suspend(); self.appResourceAlerts.suspend(); self.insights.sleep(before: self.snapshot)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.asleep = false; self.timeReminders.resume(); self.appResourceAlerts.resume(); self.recent.removeAll()
                self.processGeneration += 1; self.needsProcessReset = true; self.lastApps = .distantPast
                await self.refresh()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.notifications.refresh() }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            clockObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.timeReminders.clockChanged() }
            })
        }
    }

    func refresh() async {
        guard !sampling, !asleep, !clearingHistory else { return }
        sampling = true
        defer { sampling = false }
        let previous = snapshot
        snapshot = await engine.battery()
        guard !asleep, !clearingHistory else { return }
        appResourceAlerts.observeBatteryState(snapshot.state)
        if snapshot.state != .unavailable {
            notifications.alarm.reconcile(snapshot, rules: activeAlerts, timeRules: activeTimeReminders)
            if features[.advancedReadings] {
                recent.append(snapshot)
                recent.removeAll { snapshot.date.timeIntervalSince($0.date) > 960 }
            } else { recent.removeAll(keepingCapacity: true) }
            let fired = evaluator.evaluate(snapshot, rules: activeAlerts)
            for rule in fired {
                guard features[.chargeAlerts], alerts.contains(where: { $0.id == rule.id && $0.enabled }) else { continue }
                notice = "\(rule.title): battery at \(Int(snapshot.level.rounded()))%."
                _ = await notifications.deliver(rule, level: snapshot.level, sound: sound)
                await insights.record(.init(date: snapshot.date, kind: .alert, title: rule.title, detail: "Battery at \(Int(snapshot.level))%."))
            }
            if features[.batteryHistory], snapshot.date.timeIntervalSince(lastSave) >= 60 || snapshot.state != previous.state {
                do {
                    var recorded = snapshot; recorded.recordingID = recordingID
                    try await store?.append(recorded, recordHealthHistory: features.recordsHealth); lastSave = snapshot.date
                    await loadHistory()
                } catch { self.error = "History could not be saved: \(error.localizedDescription)" }
            }
        }
        if features[.appActivity], Date.now.timeIntervalSince(lastApps) >= (NSApp.isActive ? 10 : 30) {
            let generation = processGeneration
            if needsProcessReset { needsProcessReset = false; await engine.resetProcesses() }
            let catalog = NSWorkspace.shared.runningApplications.map {
                AppIdentity(pid: $0.processIdentifier, name: $0.localizedName ?? "Application", bundlePath: $0.bundleURL?.path,
                            quitTarget: features[.applicationQuitting] ? ApplicationQuitTarget.make($0) : nil)
            }
            let result = await engine.applications(catalog: catalog)
            if features[.appActivity], generation == processGeneration, !asleep, !clearingHistory {
                apps = result
                insights.accumulate(apps, at: .now)
                lastApps = .now; lastAppUpdate = .now
                await appResourceAlerts.consume(apps, batteryState: snapshot.state)
            }
        }
        await chargeLimit.refresh()
        guard !asleep, !clearingHistory else { return }
        await insights.observeHelper(chargeLimit.status)
        await insights.consume(snapshot, notifications: notifications, sound: sound)
    }

    func loadHistory() async {
        guard features[.batteryHistory] else { return }
        historyGeneration += 1
        let generation = historyGeneration
        let selectedRange = range
        do {
            let result = try await store?.samples(since: .now.addingTimeInterval(-selectedRange.seconds)) ?? []
            guard generation == historyGeneration else { return }
            history = result; chart = Analytics.chartSamples(result); statistics = BatteryStatistics(samples: result)
            var groups: [[BatterySnapshot]] = []
            for sample in result {
                if let previous = groups.last?.last, sample.state == previous.state,
                   sample.recordingID == previous.recordingID,
                   sample.date.timeIntervalSince(previous.date) <= 180 {
                    groups[groups.count - 1].append(sample)
                } else { groups.append([sample]) }
            }
            chartSegments = groups.enumerated().map { index, samples in
                let budget = max(2, Int(Double(samples.count) / Double(max(1, result.count)) * 360))
                return ChartSegment(id: index, samples: Analytics.chartSamples(samples, limit: budget))
            }
        } catch { self.error = "History could not be read: \(error.localizedDescription)" }
    }
    func exportHistory() {
        let samples = history
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Cell-battery-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).csv"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let csv = await Task.detached(priority: .utility) { HistoryCSV.encode(samples) }.value
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                    self?.notice = "History exported to \(url.lastPathComponent)."
                } catch { self?.error = "Export failed: \(error.localizedDescription)" }
            }
        }
    }
    func clearHistory() async {
        clearingHistory = true; historyGeneration += 1
        defer { clearingHistory = false }
        do {
            await insights.flushUsage()
            try await store?.clear(); recent.removeAll(); lastSave = .distantPast
            await insights.resetHistory()
            await loadHistory(); notice = "Battery history cleared. New readings will appear as they are recorded."
        } catch { self.error = "History could not be cleared: \(error.localizedDescription)" }
    }
    func dismissMessages() { error = nil; notice = nil }
    func quitApplication(_ app: AppActivity) {
        guard features[.appActivity], features[.applicationQuitting] else { return }
        applicationQuitting.requestQuit(app)
    }
    private func saveAlerts() {
        if let data = try? JSONEncoder().encode(alerts) { defaults.set(data, forKey: "chargeAlerts") }
    }
    func shutdown() {
        timeReminders.shutdown()
        appResourceAlerts.shutdown()
        applicationQuitting.cancelRequests()
        notifications.alarm.dismiss()
        asleep = true
        loop?.cancel(); loop = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers.removeAll()
        // SQLite's WAL keeps committed samples safe on normal or abrupt termination.
    }
    func prepareForTermination() async {
        shutdown(); await insights.flushUsage(); await insights.flushUsage()
    }
}
