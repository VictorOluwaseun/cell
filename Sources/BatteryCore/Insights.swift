import Foundation

public struct ChargeProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var limit: Int
    public var lowReminder: Int?
    public var highReminder: Int?
    public init(id: UUID = UUID(), name: String, limit: Int, lowReminder: Int? = 20, highReminder: Int? = nil) {
        self.id = id; self.name = name; self.limit = limit
        self.lowReminder = lowReminder; self.highReminder = highReminder
    }
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 40 &&
        ChargeLimitConfiguration.allowedRange.contains(limit) &&
        [lowReminder, highReminder].allSatisfy { $0 == nil || (1...100).contains($0!) }
    }
    public static let defaults = [ChargeProfile(name: "Desk", limit: 80, lowReminder: 20, highReminder: 80),
                                  ChargeProfile(name: "Travel", limit: 100, lowReminder: 15, highReminder: 100)]
}

public enum PowerEventKind: String, Codable, CaseIterable, Sendable {
    case monitoring, connected, disconnected, charging, paused, full, limit, override, profile, sleep, wake, alert, anomaly
    public var symbol: String {
        switch self {
        case .monitoring: "waveform.path"
        case .connected: "powerplug.fill"
        case .disconnected: "powerplug"
        case .charging: "bolt.fill"
        case .paused: "pause.circle"
        case .full: "battery.100percent"
        case .limit: "battery.100percent.bolt"
        case .override: "forward.end"
        case .profile: "square.stack"
        case .sleep: "moon"
        case .wake: "sun.max"
        case .alert, .anomaly: "bell"
        }
    }
}

public struct PowerEvent: Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: PowerEventKind
    public var title: String
    public var detail: String
    public init(id: UUID = UUID(), date: Date = .now, kind: PowerEventKind, title: String, detail: String = "") {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.detail = detail
    }
}

public struct SleepSession: Codable, Sendable, Identifiable {
    public var id: UUID
    public var before: BatterySnapshot
    public var after: BatterySnapshot?
    public var recoveredAfterRestart: Bool?
    public init(id: UUID = UUID(), before: BatterySnapshot, after: BatterySnapshot? = nil) {
        self.id = id; self.before = before; self.after = after; self.recoveredAfterRestart = false
    }
    public var duration: Double { after.map { $0.date.timeIntervalSince(before.date) } ?? 0 }
    public var batteryOnly: Bool { before.state == .discharging && after?.state == .discharging }
    public var drop: Double? {
        guard let after, before.state != .unavailable, after.state != .unavailable, duration >= 60 else { return nil }
        return before.level - after.level
    }
    public var drainPerHour: Double? {
        guard batteryOnly, recoveredAfterRestart != true, let drop, duration >= 3_600, drop >= 0 else { return nil }
        return drop / (duration / 3_600)
    }
    public var unusual: Bool { (drainPerHour ?? 0) > 1 }
}

public struct HealthReading: Codable, Sendable, Identifiable {
    public var day: Date
    public var health: Double
    public var fullCapacity: Double
    public var cycles: Int?
    public var id: Date { day }
    public init(day: Date, health: Double, fullCapacity: Double, cycles: Int?) {
        self.day = day; self.health = health; self.fullCapacity = fullCapacity; self.cycles = cycles
    }
}

public struct AppEnergyInterval: Sendable {
    public var identity: String
    public var name: String
    public var bundlePath: String?
    public var end: Date
    public var seconds: Double
    public var watts: Double?
    public var cpuPercent: Double
    public init(identity: String, name: String, bundlePath: String? = nil, end: Date,
                seconds: Double, watts: Double?, cpuPercent: Double) {
        self.identity = identity; self.name = name; self.bundlePath = bundlePath
        self.end = end; self.seconds = seconds; self.watts = watts; self.cpuPercent = cpuPercent
    }
}

public struct AppEnergyTotal: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var wattHours: Double
    public var cpuSeconds: Double
    public var observedSeconds: Double
    public var measuredSeconds: Double
    public var averageWatts: Double? { measuredSeconds > 0 ? wattHours * 3_600 / measuredSeconds : nil }
}

public struct DailyEnergy: Sendable, Identifiable {
    public var day: Date
    public var dischargedWh: Double
    public var chargedWh: Double
    public var batterySeconds: Double
    public var id: Date { day }
}

public struct ChargingSession: Sendable, Identifiable {
    public var start: Date
    public var end: Date
    public var firstLevel: Double
    public var lastLevel: Double
    public var chargedWh: Double
    public var measuredSeconds: Double
    public var ongoing: Bool
    public var id: Date { start }
}

public struct RuntimeForecast: Sendable {
    public var hours: Double
    public var lowerHours: Double
    public var upperHours: Double
    public var observedSeconds: Double
    public static func estimate(_ samples: [BatterySnapshot]) -> Self? {
        guard let last = samples.last, last.state == .discharging, last.level > 0 else { return nil }
        var window = [last]
        for item in samples.dropLast().reversed() {
            guard item.state == .discharging, last.date.timeIntervalSince(item.date) <= 600,
                  window.last!.date.timeIntervalSince(item.date) <= 90 else { break }
            window.append(item)
        }
        let duration = last.date.timeIntervalSince(window.last!.date)
        let rates = window.compactMap(\.instantaneousRate).map { -$0 }.filter { $0.isFinite && $0 > 0.5 && $0 < 200 }.sorted()
        guard duration >= 180, rates.count >= 6, rates.count >= window.count / 2 else { return nil }
        let median = InsightMath.quantile(rates, 0.5)
        let lowRate = min(median * 0.8, InsightMath.quantile(rates, 0.2))
        let highRate = max(median * 1.2, InsightMath.quantile(rates, 0.8))
        return .init(hours: min(72, last.level / median), lowerHours: min(72, last.level / highRate),
                     upperHours: min(72, last.level / lowRate), observedSeconds: duration)
    }
}

public struct DrainBaseline: Sendable {
    public var watts: Double
    public var seconds: Double
    public init(watts: Double, seconds: Double) { self.watts = watts; self.seconds = seconds }
}

public struct DrainAnomalyDetector: Sendable {
    private var elevatedSince: Date?
    private var lastDate: Date?
    private var rearmed = true
    public init() {}
    public mutating func evaluate(_ sample: BatterySnapshot, baseline: DrainBaseline?, lastAlert: Date?) -> Bool {
        defer { lastDate = sample.date }
        if let lastDate, sample.date.timeIntervalSince(lastDate) > 90 { elevatedSince = nil }
        guard sample.state == .discharging, let baseline, baseline.seconds >= 1_800,
              let power = sample.batteryWatts, power.isFinite else { elevatedSince = nil; return false }
        let drain = -power
        if drain < baseline.watts * 1.3 { elevatedSince = nil; rearmed = true; return false }
        let threshold = max(8, max(baseline.watts * 2, baseline.watts + 5))
        guard drain >= threshold else { elevatedSince = nil; return false }
        if elevatedSince == nil { elevatedSince = sample.date }
        guard rearmed, sample.date.timeIntervalSince(elevatedSince!) >= 300,
              lastAlert.map({ sample.date.timeIntervalSince($0) >= 7_200 }) ?? true else { return false }
        rearmed = false; return true
    }
}

public enum InsightMath {
    public static func quantile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Double(sorted.count - 1) * min(1, max(0, fraction))
        let lower = Int(index), upper = min(sorted.count - 1, Int(index.rounded(.up)))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
    }
    public static func baseline(_ samples: [BatterySnapshot], before cutoff: Date) -> DrainBaseline? {
        var values: [Double] = [], seconds = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            guard b.date < cutoff, dt > 0, dt <= 180, a.state == .discharging, b.state == .discharging,
                  let wa = a.batteryWatts, let wb = b.batteryWatts else { continue }
            let power = -(wa + wb) / 2
            if power > 0.5 && power < 200 { values.append(power); seconds += dt }
        }
        guard seconds >= 1_800, values.count >= 20 else { return nil }
        return .init(watts: quantile(values.sorted(), 0.5), seconds: seconds)
    }
    public static func chargingSessions(_ samples: [BatterySnapshot], now: Date) -> [ChargingSession] {
        var output: [ChargingSession] = [], group: [BatterySnapshot] = []
        func finish(ongoing: Bool) {
            guard let first = group.first, let last = group.last else { return }
            let statistics = BatteryStatistics(samples: group)
            output.append(.init(start: first.date, end: last.date, firstLevel: first.level, lastLevel: last.level,
                                chargedWh: statistics.chargedWh, measuredSeconds: statistics.measuredChargeSeconds, ongoing: ongoing))
            group.removeAll(keepingCapacity: true)
        }
        for sample in samples {
            if let previous = group.last, sample.date.timeIntervalSince(previous.date) > 180 { finish(ongoing: false) }
            if sample.state.onAC { group.append(sample) } else { finish(ongoing: false) }
        }
        finish(ongoing: samples.last.map { $0.state.onAC && now.timeIntervalSince($0.date) <= 180 } ?? false)
        return output.reversed()
    }
    public static func dailyEnergy(_ samples: [BatterySnapshot], calendar: Calendar = .current) -> [DailyEnergy] {
        var days: [Date: DailyEnergy] = [:]
        // Split continuous intervals at local midnight, including DST boundaries.
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            guard dt > 0, dt <= 180, a.state == b.state else { continue }
            let stats = BatteryStatistics(samples: [a, b])
            var cursor = a.date
            while cursor < b.date {
                let day = calendar.startOfDay(for: cursor)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let end = min(b.date, nextDay), ratio = end.timeIntervalSince(cursor) / dt
                var value = days[day] ?? .init(day: day, dischargedWh: 0, chargedWh: 0, batterySeconds: 0)
                value.dischargedWh += stats.dischargedWh * ratio; value.chargedWh += stats.chargedWh * ratio
                value.batterySeconds += stats.batterySeconds * ratio; days[day] = value; cursor = end
            }
        }
        return days.values.sorted { $0.day < $1.day }
    }
}

public struct WeeklyReport: Sendable {
    public var start: Date
    public var end: Date
    public var current: BatteryStatistics
    public var previous: BatteryStatistics
    public var days: [DailyEnergy]
    public var apps: [AppEnergyTotal]
    public var sleeps: [SleepSession]
    public var healthChange: Double?
    public var observedDrainChange: Double? {
        guard current.measuredBatterySeconds >= 1_800, previous.measuredBatterySeconds >= 1_800,
              let a = current.averageDrainWatts, let b = previous.averageDrainWatts, b > 0 else { return nil }
        return (a - b) / b * 100
    }
}

public struct InsightsDashboard: Sendable {
    public var events: [PowerEvent] = []
    public var sleep: [SleepSession] = []
    public var health: [HealthReading] = []
    public var apps: [AppEnergyTotal] = []
    public var sessions: [ChargingSession] = []
    public var baseline: DrainBaseline?
    public var report: WeeklyReport?
    public var generated: Date = .now
    public init() {}
}

public struct ChargingExplanation: Sendable {
    public var title: String
    public var detail: String
    public var symbol: String
    public static func make(_ battery: BatterySnapshot, helper: ChargeHelperStatus?, helperError: String?) -> Self {
        if battery.state == .unavailable { return .init(title: "No battery reading", detail: "macOS has not provided an internal battery reading.", symbol: "questionmark.circle") }
        if !battery.state.onAC { return .init(title: "Running on battery", detail: "macOS reports that external power is not supplying this Mac.", symbol: "battery.75percent") }
        if battery.state == .charging { return .init(title: "Your battery is charging", detail: "macOS confirms charging is active. Positive current shows power entering the battery.", symbol: "bolt.fill") }
        if battery.state == .full { return .init(title: "The battery is full", detail: "macOS reports a full battery. Charging can pause while the adapter powers your Mac.", symbol: "battery.100percent") }
        if helperError != nil || helper?.error != nil {
            return .init(title: "Cell cannot confirm charge control", detail: "The helper reported a problem. Review Charging limit for details; this pause cannot be attributed to Cell with confidence.", symbol: "exclamationmark.triangle")
        }
        if let helper, helper.held, helper.configuration.enabled, !helper.override {
            return .init(title: "Cell is holding the charge", detail: "The helper reports an active pause for your \(helper.configuration.percentage)% limit. It releases at \(helper.configuration.percentage - 3)% or below. Sleep protection can also pause below the target.", symbol: "pause.circle")
        }
        if (battery.batteryWatts ?? 0) < -0.5 {
            return .init(title: "The battery is helping supply power", detail: "External power is connected, but the sensor shows net battery discharge. Check the charger and current workload. These readings alone cannot identify the cause.", symbol: "powerplug")
        }
        return .init(title: "Connected, but charging is paused", detail: "Cell has not confirmed its own pause. macOS optimization, a native charge limit, temperature or adapter conditions may be involved. Open Battery settings to check; the exact cause is not exposed by these readings.", symbol: "powerplug.fill")
    }
}
