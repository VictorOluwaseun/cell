import Foundation

public enum AppResourceKind: String, CaseIterable, Codable, Sendable {
    case cpu, memory, power
    public var title: String {
        switch self { case .cpu: "CPU"; case .memory: "Memory"; case .power: "Measured power" }
    }
    public func formatted(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        switch self { case .cpu: return "\(number)%"; case .memory: return "\(number) GiB"; case .power: return "\(number) W" }
    }
}

public struct AppResourceAlertPreferences: Codable, Equatable, Sendable {
    public var cpuEnabled = false
    public var memoryEnabled = false
    public var powerEnabled = false
    public var cpuThreshold = 100.0
    public var memoryGiB = 4.0
    public var powerWatts = 5.0
    public var sustainedSeconds = 60.0
    public var cooldownSeconds = 900.0
    public var powerOnlyOnBattery = true
    public static let durations = [30.0, 60, 120, 300]
    public static let cooldowns = [300.0, 900, 1_800, 3_600]
    public init() {}
    public var anyEnabled: Bool { cpuEnabled || memoryEnabled || powerEnabled }
    public func enabled(_ kind: AppResourceKind) -> Bool {
        switch kind { case .cpu: cpuEnabled; case .memory: memoryEnabled; case .power: powerEnabled }
    }
    public func threshold(_ kind: AppResourceKind) -> Double {
        switch kind { case .cpu: cpuThreshold; case .memory: memoryGiB; case .power: powerWatts }
    }
    public var validated: Self {
        var value = self
        func bounded(_ number: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            number.isFinite ? min(range.upperBound, max(range.lowerBound, number)) : fallback
        }
        value.cpuThreshold = bounded(cpuThreshold, 10...6_400, fallback: 100)
        value.memoryGiB = bounded(memoryGiB, 0.25...1_024, fallback: 4)
        value.powerWatts = bounded(powerWatts, 0.1...100, fallback: 5)
        if !Self.durations.contains(sustainedSeconds) { value.sustainedSeconds = 60 }
        if !Self.cooldowns.contains(cooldownSeconds) { value.cooldownSeconds = 900 }
        return value
    }
}

/// A running app and its readable descendants, using the same grouping as live App activity.
public struct AppResourceReading: Sendable {
    public var identity: String
    public var name: String
    public var pid: Int32
    public var started: UInt64
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var watts: Double?
    public var sampledSeconds: Double
    public init(identity: String, name: String, pid: Int32, started: UInt64, cpuPercent: Double,
                memoryBytes: UInt64, watts: Double?, sampledSeconds: Double) {
        self.identity = identity; self.name = name; self.pid = pid; self.started = started
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.watts = watts; self.sampledSeconds = sampledSeconds
    }
    fileprivate func value(_ kind: AppResourceKind) -> Double? {
        switch kind {
        case .cpu: cpuPercent
        case .memory: Double(memoryBytes) / 1_073_741_824
        case .power: watts
        }
    }
}

public struct AppResourceBreach: Equatable, Sendable {
    public var kind: AppResourceKind
    public var value: Double
    public var threshold: Double
}

public struct AppResourceAlert: Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var identity: String
    public var name: String
    public var date: Date
    public var sustainedSeconds: Double
    public var breaches: [AppResourceBreach]
    public var title: String { "High resource use: \(name)" }
    public var detail: String {
        let readings = breaches.map { "\($0.kind.title) \($0.kind.formatted($0.value)) (limit \($0.kind.formatted($0.threshold)))" }.joined(separator: "; ")
        return "Above your limits for at least \(Int(sustainedSeconds)) seconds: \(readings)."
    }
}

public struct AppResourceCooldown: Codable, Equatable, Sendable {
    public var identity: String
    public var date: Date
    public init(identity: String, date: Date) { self.identity = identity; self.date = date }
}

/// Linear in the current app list. Only active app/metric streaks and at most 256 cooldowns are kept.
public struct AppResourceAlertEvaluator: Sendable {
    private struct Instance: Hashable, Sendable { var identity: String; var pid: Int32; var started: UInt64 }
    private struct Key: Hashable, Sendable { var instance: Instance; var kind: AppResourceKind }
    private struct Streak: Sendable { var since: Double; var last: Double; var alerted = false }
    private struct LastAlert: Sendable { var date: Date; var uptime: Double }
    private var streaks: [Key: Streak] = [:]
    private var lastAlerts: [String: LastAlert] = [:]
    private var lastNotification: Double?
    private var lastEvaluation: Double?
    private var configuration: AppResourceAlertPreferences?
    public init(cooldowns: [AppResourceCooldown] = [], at date: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        for saved in cooldowns.suffix(256) where !saved.identity.isEmpty && saved.date.timeIntervalSince1970.isFinite {
            // Convert restored wall-clock ages once; in-session cooldowns use monotonic time.
            let age = max(0, date.timeIntervalSince(saved.date))
            guard age < 3_600 else { continue }
            let stamp = LastAlert(date: min(date, saved.date), uptime: uptime - age)
            if stamp.uptime > (lastAlerts[saved.identity]?.uptime ?? -.infinity) { lastAlerts[saved.identity] = stamp }
        }
        lastNotification = lastAlerts.values.map(\.uptime).max()
    }
    public var cooldowns: [AppResourceCooldown] {
        lastAlerts.map { .init(identity: $0.key, date: $0.value.date) }.sorted { $0.date < $1.date }
    }
    /// Sleep, sampling pauses and preference changes invalidate evidence, while keeping cooldowns.
    public mutating func resetObservations() { streaks.removeAll(keepingCapacity: true); lastEvaluation = nil }
    public mutating func resetPowerObservations() { streaks = streaks.filter { $0.key.kind != .power } }

    public mutating func evaluate(_ apps: [AppResourceReading], preferences: AppResourceAlertPreferences,
                                 at date: Date, uptime: Double, batteryState: BatteryState) -> [AppResourceAlert] {
        guard uptime.isFinite, date.timeIntervalSince1970.isFinite else { return [] }
        let settings = preferences.validated
        if configuration != settings { resetObservations(); configuration = settings }
        guard settings.anyEnabled else { resetObservations(); return [] }
        guard lastEvaluation.map({ uptime > $0 }) ?? true else { return [] }
        lastEvaluation = uptime
        lastAlerts = lastAlerts.filter { uptime - $0.value.uptime < 3_600 }
        var active = Set<Key>(), candidates: [(AppResourceReading, [AppResourceBreach], [Key])] = []
        var seen = Set<Instance>()
        for app in apps {
            let instance = Instance(identity: app.identity, pid: app.pid, started: app.started)
            guard !app.identity.isEmpty, app.pid > 0, app.started > 0, app.sampledSeconds.isFinite,
                  (1...90).contains(app.sampledSeconds), seen.insert(instance).inserted else { continue }
            var breaches: [AppResourceBreach] = [], ready: [Key] = []
            for kind in AppResourceKind.allCases where settings.enabled(kind) {
                guard kind != .power || !settings.powerOnlyOnBattery || batteryState == .discharging,
                      let value = app.value(kind), value.isFinite, value >= 0 else { continue }
                let key = Key(instance: instance, kind: kind), threshold = settings.threshold(kind)
                var streak = streaks[key] ?? Streak(since: uptime, last: uptime)
                let gap = uptime - streak.last
                if gap > 90 || gap > app.sampledSeconds + 2 { streak = Streak(since: uptime, last: uptime) }
                // Once reported, require a real recovery rather than threshold noise to rearm.
                if streak.alerted {
                    if value > threshold * 0.9 { streak.last = uptime; streaks[key] = streak; active.insert(key) }
                    continue
                }
                guard value >= threshold else { continue }
                streak.last = uptime; streaks[key] = streak; active.insert(key)
                if uptime - streak.since >= settings.sustainedSeconds {
                    breaches.append(.init(kind: kind, value: value, threshold: threshold)); ready.append(key)
                }
            }
            if !breaches.isEmpty, lastAlerts[app.identity].map({ uptime - $0.uptime >= settings.cooldownSeconds }) ?? true {
                candidates.append((app, breaches, ready))
            }
        }
        streaks = streaks.filter { active.contains($0.key) }
        // Spread simultaneous app warnings out. Recheck pending apps on the next existing sample.
        guard lastNotification.map({ uptime - $0 >= 60 }) ?? true,
              let selected = candidates.max(by: { a, b in
                  let aRatio = a.1.map { $0.value / $0.threshold }.max() ?? 0
                  let bRatio = b.1.map { $0.value / $0.threshold }.max() ?? 0
                  return aRatio == bRatio ? a.0.identity > b.0.identity : aRatio < bRatio
              }) else { return [] }
        for key in selected.2 { streaks[key]?.alerted = true }
        lastAlerts[selected.0.identity] = .init(date: date, uptime: uptime); lastNotification = uptime
        if lastAlerts.count > 256, let oldest = lastAlerts.min(by: { $0.value.uptime < $1.value.uptime })?.key { lastAlerts.removeValue(forKey: oldest) }
        let name = String(selected.0.name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return [.init(identity: selected.0.identity, name: name.isEmpty ? "Application" : name,
                      date: date, sustainedSeconds: settings.sustainedSeconds, breaches: selected.1)]
    }
}
