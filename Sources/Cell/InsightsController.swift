import AppKit
import SwiftUI
import BatteryCore

private actor InsightProcessor {
    private var recent: [BatterySnapshot] = []
    private var detector = DrainAnomalyDetector()
    func process(_ sample: BatterySnapshot, baseline: DrainBaseline?, enabled: Bool, lastAlert: Date?) -> (RuntimeForecast?, Bool) {
        recent.append(sample); recent.removeAll { sample.date.timeIntervalSince($0.date) > 660 }
        if !enabled { detector = DrainAnomalyDetector() }
        let alert = enabled && detector.evaluate(sample, baseline: baseline, lastAlert: lastAlert)
        return (RuntimeForecast.estimate(recent), alert)
    }
    func reset() { recent.removeAll(keepingCapacity: true); detector = DrainAnomalyDetector() }
}

@MainActor
final class InsightsController: ObservableObject {
    @Published private(set) var dashboard = InsightsDashboard()
    @Published private(set) var forecast: RuntimeForecast?
    @Published private(set) var error: String?
    @Published private(set) var drainWarning: String?
    @Published private(set) var loading = false
    @Published var range: HistoryRange = .week { didSet { Task { await reload() } } }
    @Published var reportWeeksAgo = 0 { didSet { Task { await reload() } } }
    @Published var profiles: [ChargeProfile] {
        didSet {
            save(profiles, key: "chargeProfiles")
            if let id = selectedProfile, oldValue.first(where: { $0.id == id }) != profiles.first(where: { $0.id == id }) { selectedProfile = nil }
        }
    }
    @Published var selectedProfile: UUID? { didSet { defaults.set(selectedProfile?.uuidString, forKey: "selectedChargeProfile") } }
    @Published var drainAlerts: Bool { didSet { defaults.set(drainAlerts, forKey: "drainAlerts"); if !drainAlerts { drainWarning = nil } } }
    @Published var weeklyNotifications: Bool { didSet { defaults.set(weeklyNotifications, forKey: "weeklyReports") } }
    private let defaults: UserDefaults
    private let processor = InsightProcessor()
    private var store: HistoryStore?
    private var lastBattery: BatterySnapshot?
    private var lastHelper: ChargeHelperStatus?
    private var pendingSleep: SleepSession?
    private var recoveringSleep = false
    private var pendingUsage: [AppEnergyInterval] = []
    private var flushTask: Task<Void, Never>?
    private var lastFlush = Date.now
    private var lastLoad = Date.distantPast
    private var generation = 0
    private var dirty = false
    private var lastDrainAlert: Date?
    private var lastForecastPublication = Date.distantPast

    init(defaults: UserDefaults) {
        self.defaults = defaults
        profiles = defaults.data(forKey: "chargeProfiles").flatMap { try? JSONDecoder().decode([ChargeProfile].self, from: $0) }?.filter(\.isValid) ?? ChargeProfile.defaults
        selectedProfile = defaults.string(forKey: "selectedChargeProfile").flatMap(UUID.init(uuidString:))
        pendingSleep = defaults.data(forKey: "pendingSleepV2").flatMap { try? JSONDecoder().decode(SleepSession.self, from: $0) }
        recoveringSleep = pendingSleep != nil
        drainAlerts = defaults.object(forKey: "drainAlerts") as? Bool ?? true
        weeklyNotifications = defaults.bool(forKey: "weeklyReports")
        lastDrainAlert = defaults.object(forKey: "lastDrainAlert") as? Date
        if defaults.data(forKey: "chargeProfiles") == nil { save(profiles, key: "chargeProfiles") }
    }
    func connect(_ store: HistoryStore?) { self.store = store }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    func record(_ event: PowerEvent) async {
        guard let store else { return }
        do { try await store.recordEvent(event); dirty = true }
        catch { self.error = "Could not record the power timeline: \(error.localizedDescription)" }
    }
    func sleep(before snapshot: BatterySnapshot) {
        guard snapshot.state != .unavailable else { return }
        var before = snapshot; before.date = .now
        let session = SleepSession(before: before)
        pendingSleep = session; recoveringSleep = false; save(session, key: "pendingSleepV2")
        Task { await record(.init(date: before.date, kind: .sleep, title: "Mac went to sleep", detail: "Battery at \(Int(before.level))%. The last available reading is used.")) }
    }
    private func finishSleep(after snapshot: BatterySnapshot) async {
        guard var pending = pendingSleep else { return }
        guard snapshot.date > pending.before.date else { clearPendingSleep(); return }
        pending.after = snapshot
        pending.recoveredAfterRestart = recoveringSleep
        do {
            try await store?.recordSleep(pending)
            if pending.duration >= 60 {
                await record(.init(date: snapshot.date, kind: .wake, title: recoveringSleep ? "Recovered a sleep comparison" : "Mac woke from sleep",
                    detail: "\(Display.duration(pending.duration)) between observations. Battery changed from \(Int(pending.before.level))% to \(Int(snapshot.level))%. \(recoveringSleep ? "Cell was restarted, so the actual wake time is unknown." : "Power may have changed while asleep.")"))
            }
            clearPendingSleep(); await processor.reset(); dirty = true
        } catch { self.error = "Could not save the sleep comparison: \(error.localizedDescription)" }
    }
    private func clearPendingSleep() { pendingSleep = nil; defaults.removeObject(forKey: "pendingSleepV2") }

    func consume(_ sample: BatterySnapshot, notifications: NotificationService, sound: Bool) async {
        guard sample.state != .unavailable else { forecast = nil; return }
        await finishSleep(after: sample)
        if let previous = lastBattery {
            if previous.state.onAC != sample.state.onAC {
                await record(.init(date: sample.date, kind: sample.state.onAC ? .connected : .disconnected,
                    title: sample.state.onAC ? "External power detected" : "Switched to battery",
                    detail: "Observed at \(Int(sample.level))% charge."))
            } else if previous.state != sample.state {
                let kind: PowerEventKind = sample.state == .charging ? .charging : (sample.state == .full ? .full : .paused)
                await record(.init(date: sample.date, kind: kind, title: sample.state.title, detail: "Observed at \(Int(sample.level))% charge."))
            }
        } else {
            await record(.init(date: sample.date, kind: .monitoring, title: "Monitoring started", detail: "\(sample.state.title), \(Int(sample.level))%."))
        }
        lastBattery = sample
        let result = await processor.process(sample, baseline: dashboard.baseline, enabled: drainAlerts, lastAlert: lastDrainAlert)
        if let forecastValue = result.0 {
            if forecast == nil || sample.date.timeIntervalSince(lastForecastPublication) >= 30 {
                forecast = forecastValue; lastForecastPublication = sample.date
            }
        } else if forecast != nil { forecast = nil }
        if result.1, let baseline = dashboard.baseline {
            lastDrainAlert = sample.date; defaults.set(sample.date, forKey: "lastDrainAlert")
            let detail = "Battery use has stayed above its recent baseline for 5 minutes. Baseline: \(Display.number(baseline.watts, unit: " W")). Current: \(Display.number(sample.batteryWatts.map { -$0 }, unit: " W")). A changed workload can explain this."
            drainWarning = detail
            await record(.init(date: sample.date, kind: .anomaly, title: "Unusual battery drain", detail: detail))
            _ = await notifications.deliverInsight(id: "cell-drain", title: "Unusual battery drain", body: detail, sound: sound)
        }
        if Date.now.timeIntervalSince(lastFlush) >= 60 { await flushUsage() }
        if dirty || Date.now.timeIntervalSince(lastLoad) >= 60 { await reload() }
        if weeklyNotifications, reportWeeksAgo == 0, let report = dashboard.report,
           report.current.observedSeconds >= 1_800 {
            var calendar = Calendar(identifier: .iso8601); calendar.timeZone = .current
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: sample.date)
            let key = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
            if defaults.string(forKey: "lastWeeklyReport") != key {
                let delivered = await notifications.deliverInsight(id: "cell-weekly", title: "Your weekly battery report",
                    body: "\(Display.duration(report.current.batterySeconds)) of recorded battery use in the past 7 days. Open Reports in Cell for energy, app and sleep details.", sound: sound)
                if delivered { defaults.set(key, forKey: "lastWeeklyReport") }
            }
        }
    }
    func observeHelper(_ value: ChargeHelperStatus?) async {
        guard let value else { return }
        if let id = selectedProfile, let profile = profiles.first(where: { $0.id == id }),
           (!value.configuration.enabled || value.configuration.percentage != profile.limit) { selectedProfile = nil }
        defer { lastHelper = value }
        guard let old = lastHelper else { return }
        if old.configuration != value.configuration {
            await record(.init(kind: .limit, title: value.configuration.enabled ? "Charging limit set to \(value.configuration.percentage)%" : "Charging limit disabled", detail: "Confirmed by the charging helper."))
        }
        if old.held != value.held {
            await record(.init(kind: value.held ? .paused : .charging,
                title: value.held ? "Cell observed its charging pause" : "Cell released its charging pause",
                detail: "Helper state observed by Cell; this timestamp may follow the hardware change."))
        }
        if old.override != value.override {
            await record(.init(kind: .override, title: value.override ? "Full-charge override active" : "Full-charge override ended"))
        }
    }
    func accumulate(_ apps: [AppActivity], at date: Date) {
        var combined: [String: AppEnergyInterval] = [:]
        let active = apps.filter { ($0.watts ?? 0) > 0.001 || $0.cpuPercent > 0.05 }
        let candidates = Array(active.sorted { ($0.watts ?? 0) > ($1.watts ?? 0) }.prefix(32)) +
                         Array(active.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(32))
        var seen = Set<Int32>()
        for app in candidates where seen.insert(app.id).inserted {
            guard app.sampledSeconds >= 1 else { continue }
            let key = app.bundlePath.map { "app:" + $0 } ?? "process:" + app.name
            if var value = combined[key] {
                value.cpuPercent += app.cpuPercent
                if let watts = app.watts { value.watts = (value.watts ?? 0) + watts }
                value.seconds = max(value.seconds, app.sampledSeconds); combined[key] = value
            } else {
                combined[key] = .init(identity: key, name: app.name, bundlePath: app.bundlePath,
                    end: date, seconds: app.sampledSeconds, watts: app.watts, cpuPercent: app.cpuPercent)
            }
        }
        pendingUsage.append(contentsOf: combined.values)
        if pendingUsage.count > 1_024 {
            pendingUsage.removeFirst(pendingUsage.count - 1_024)
            error = "Some app intervals were dropped because storage could not keep up."
        }
    }
    func flushUsage() async {
        if let flushTask { await flushTask.value; return }
        guard !pendingUsage.isEmpty, let store else { lastFlush = .now; return }
        let batch = pendingUsage; pendingUsage.removeAll(keepingCapacity: true)
        let task = Task { [weak self] in
            do { try await store.recordAppEnergy(batch); self?.dirty = true }
            catch {
                self?.pendingUsage.insert(contentsOf: batch, at: 0)
                self?.error = "Could not save app energy history: \(error.localizedDescription)"
            }
        }
        flushTask = task; await task.value; flushTask = nil; lastFlush = .now
    }
    func reload() async {
        guard let store else { return }
        generation += 1; let token = generation; loading = true
        let end = reportWeeksAgo == 0 ? Date.now : Calendar.current.date(byAdding: .day, value: -reportWeeksAgo * 7,
                                                to: Calendar.current.startOfDay(for: .now))!
        do {
            let value = try await store.insights(range: range, reportEnd: end)
            guard generation == token else { return }
            dashboard = value; lastLoad = .now; dirty = false; loading = false
        } catch {
            guard generation == token else { return }
            self.error = "Could not load insights: \(error.localizedDescription)"; loading = false
        }
    }
    func apply(_ profile: ChargeProfile, controller: ChargeLimitController, monitor: BatteryMonitor) async {
        guard profile.isValid, !controller.busy else { return }
        await controller.configure(percentage: profile.limit, enabled: true)
        guard controller.error == nil, let status = controller.status, status.configuration.enabled,
              status.configuration.percentage == profile.limit else { return }
        let managed = Set((defaults.stringArray(forKey: "profileReminderIDs") ?? []).compactMap(UUID.init(uuidString:)))
        var rules = monitor.alerts.filter { !managed.contains($0.id) }, newIDs: [String] = []
        if let low = profile.lowReminder, !rules.contains(where: { $0.enabled && $0.direction == .below && $0.threshold == low }) {
            let rule = ChargeAlert(direction: .below, threshold: low); rules.append(rule); newIDs.append(rule.id.uuidString)
        }
        if let high = profile.highReminder, !rules.contains(where: { $0.enabled && $0.direction == .above && $0.threshold == high }) {
            let rule = ChargeAlert(direction: .above, threshold: high); rules.append(rule); newIDs.append(rule.id.uuidString)
        }
        defaults.set(newIDs, forKey: "profileReminderIDs"); monitor.alerts = rules; selectedProfile = profile.id
        await record(.init(kind: .profile, title: "Applied \(profile.name) profile", detail: "\(profile.limit)% limit. Profile reminders replaced; other reminders kept."))
        await observeHelper(status); await reload()
    }
    func resetHistory() async {
        generation += 1; loading = false; error = nil; drainWarning = nil
        pendingUsage.removeAll(); clearPendingSleep(); lastBattery = nil; lastHelper = nil
        await processor.reset(); forecast = nil; dashboard = .init(); lastLoad = .distantPast
    }
    func dismissError() { error = nil; drainWarning = nil }
    func exportReport() {
        guard let report = dashboard.report else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Cell-weekly-report.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try report.plainText().write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.error = "Could not export the report: \(error.localizedDescription)" }
        }
    }
}
