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
    @Published var alerts: [ChargeAlert] = [] { didSet { saveAlerts() } }
    @Published var interval: Double = 5 { didSet { defaults.set(interval, forKey: "sampleInterval") } }
    @Published var sound = true { didSet { defaults.set(sound, forKey: "alertSound") } }
    @Published var showPercentage = true { didSet { defaults.set(showPercentage, forKey: "showPercentage") } }
    @Published var appMonitoring = true { didSet { defaults.set(appMonitoring, forKey: "appMonitoring") } }
    let notifications = NotificationService()
    let chargeLimit = ChargeLimitController()
    let insights: InsightsController
    private let defaults: UserDefaults
    private let engine = TelemetryEngine()
    private var store: HistoryStore?
    private var evaluator = AlertEvaluator()
    private var recent: [BatterySnapshot] = []
    private var loop: Task<Void, Never>?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var lastSave = Date.distantPast
    private var lastApps = Date.distantPast
    private var sampling = false
    private var clearingHistory = false
    private var asleep = false
    private var historyGeneration = 0
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
        self.insights = InsightsController(defaults: defaults)
        self.defaults = defaults
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
        appMonitoring = defaults.object(forKey: "appMonitoring") as? Bool ?? true
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            store = try HistoryStore(url: base.appendingPathComponent("Cell/history.sqlite"))
        } catch { self.error = "History could not be opened: \(error.localizedDescription)" }
        insights.connect(store)
        installObservers()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.asleep { await self.refresh() }
                let seconds = NSApp.isActive ? self.interval : max(15, self.interval)
                try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(500))
            }
        }
    }

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
                self.asleep = true; self.insights.sleep(before: self.snapshot)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.asleep = false; self.recent.removeAll()
                await self.engine.resetProcesses(); await self.refresh()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.notifications.refresh() }
        })
    }

    func refresh() async {
        guard !sampling, !asleep, !clearingHistory else { return }
        sampling = true
        defer { sampling = false }
        let previous = snapshot
        snapshot = await engine.battery()
        guard !asleep, !clearingHistory else { return }
        if snapshot.state != .unavailable {
            recent.append(snapshot)
            recent.removeAll { snapshot.date.timeIntervalSince($0.date) > 960 }
            let fired = evaluator.evaluate(snapshot, rules: alerts)
            for rule in fired {
                notice = "\(rule.title): battery at \(Int(snapshot.level.rounded()))%."
                _ = await notifications.deliver(rule, level: snapshot.level, sound: sound)
                await insights.record(.init(date: snapshot.date, kind: .alert, title: rule.title, detail: "Battery at \(Int(snapshot.level))%."))
            }
            if snapshot.date.timeIntervalSince(lastSave) >= 60 || snapshot.state != previous.state {
                do {
                    try await store?.append(snapshot); lastSave = snapshot.date
                    await loadHistory()
                } catch { self.error = "History could not be saved: \(error.localizedDescription)" }
            }
        }
        if appMonitoring, Date.now.timeIntervalSince(lastApps) >= (NSApp.isActive ? 10 : 30) {
            let catalog = NSWorkspace.shared.runningApplications.map {
                AppIdentity(pid: $0.processIdentifier, name: $0.localizedName ?? "Application", bundlePath: $0.bundleURL?.path)
            }
            apps = await engine.applications(catalog: catalog)
            insights.accumulate(apps, at: .now)
            lastApps = .now; lastAppUpdate = .now
        }
        await chargeLimit.refresh()
        guard !asleep, !clearingHistory else { return }
        await insights.observeHelper(chargeLimit.status)
        await insights.consume(snapshot, notifications: notifications, sound: sound)
    }

    func loadHistory() async {
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
    private func saveAlerts() {
        if let data = try? JSONEncoder().encode(alerts) { defaults.set(data, forKey: "chargeAlerts") }
    }
    func shutdown() {
        asleep = true
        loop?.cancel(); loop = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        // SQLite's WAL keeps committed samples safe on normal or abrupt termination.
    }
    func prepareForTermination() async {
        shutdown(); await insights.flushUsage(); await insights.flushUsage()
    }
}
