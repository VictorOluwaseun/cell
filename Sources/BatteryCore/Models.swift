import Foundation

public enum BatteryState: String, Codable, Sendable {
    case charging, discharging, pluggedIn, full, unavailable
    public var title: String {
        switch self {
        case .charging: "Charging"
        case .discharging: "On battery"
        case .pluggedIn: "Charging paused"
        case .full: "Fully charged"
        case .unavailable: "No battery detected"
        }
    }
    public var onAC: Bool { self == .charging || self == .pluggedIn || self == .full }
}

public struct BatterySnapshot: Codable, Sendable, Identifiable, Equatable {
    public var date: Date
    public var level: Double
    public var state: BatteryState
    public var cycleCount: Int?
    public var designCapacity: Double?
    public var fullCapacity: Double?
    public var currentCapacity: Double?
    public var voltage: Double?
    public var currentMA: Double?
    public var temperature: Double?
    public var systemWatts: Double?
    public var adapterWatts: Double?
    public var minutesRemaining: Int?
    /// Changes when history recording resumes, so statistics never bridge a user-requested pause.
    public var recordingID: UUID?
    public var id: Date { date }
    public var batteryWatts: Double? {
        guard let voltage, let currentMA else { return nil }
        return voltage * currentMA / 1_000
    }
    public var health: Double? {
        guard let designCapacity, let fullCapacity, designCapacity > 0 else { return nil }
        return min(100, max(0, fullCapacity / designCapacity * 100))
    }
    /// Instantaneous electrical charge change, in percentage points per hour.
    public var instantaneousRate: Double? {
        guard let currentMA, let fullCapacity, fullCapacity > 0 else { return nil }
        return currentMA / fullCapacity * 100
    }
    public var cRate: Double? { instantaneousRate.map { abs($0) / 100 } }

    public init(date: Date = .now, level: Double, state: BatteryState,
                cycleCount: Int? = nil, designCapacity: Double? = nil, fullCapacity: Double? = nil,
                currentCapacity: Double? = nil, voltage: Double? = nil, currentMA: Double? = nil,
                temperature: Double? = nil, systemWatts: Double? = nil,
                adapterWatts: Double? = nil, minutesRemaining: Int? = nil) {
        self.date = date; self.level = level; self.state = state; self.cycleCount = cycleCount
        self.designCapacity = designCapacity; self.fullCapacity = fullCapacity
        self.currentCapacity = currentCapacity; self.voltage = voltage; self.currentMA = currentMA
        self.temperature = temperature; self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts; self.minutesRemaining = minutesRemaining
    }
    public static let unavailable = BatterySnapshot(level: 0, state: .unavailable)
}

public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1 hour", day = "24 hours", week = "7 days", month = "30 days"
    public var id: Self { self }
    public var seconds: TimeInterval {
        switch self { case .hour: 3_600; case .day: 86_400; case .week: 604_800; case .month: 2_592_000 }
    }
}

public struct BatteryStatistics: Sendable {
    public var batterySeconds = 0.0
    public var observedSeconds = 0.0
    public var dischargedWh = 0.0
    public var chargedWh = 0.0
    public var dischargedPercent = 0.0
    public var peakDrainWatts = 0.0
    public var measuredBatterySeconds = 0.0
    public var measuredChargeSeconds = 0.0
    public var averageDrainWatts: Double? { measuredBatterySeconds > 0 ? dischargedWh * 3_600 / measuredBatterySeconds : nil }
    public var equivalentCycles: Double { dischargedPercent / 100 }
    public var cyclesPerDay: Double? {
        observedSeconds >= 3_600 ? equivalentCycles / (observedSeconds / 86_400) : nil
    }
    public init(samples: [BatterySnapshot]) {
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            // Never extrapolate across sleep, shutdown, or a change of power source.
            guard dt > 0, dt <= 180, a.state == b.state, a.state != .unavailable,
                  a.recordingID == b.recordingID else { continue }
            observedSeconds += dt
            if a.state == .discharging {
                batterySeconds += dt
                let drop = a.level - b.level
                if drop > 0, drop <= 5 { dischargedPercent += drop }
                if let wa = a.batteryWatts, let wb = b.batteryWatts {
                    measuredBatterySeconds += dt
                    let drain = max(0, -(wa + wb) / 2)
                    dischargedWh += drain * dt / 3_600
                    peakDrainWatts = max(peakDrainWatts, max(-wa, -wb))
                }
            } else if a.state == .charging, let wa = a.batteryWatts, let wb = b.batteryWatts {
                measuredChargeSeconds += dt
                chargedWh += max(0, (wa + wb) / 2) * dt / 3_600
            }
        }
    }
}

public enum Analytics {
    /// Least-squares trend of a continuous, same-state window; avoids integer-percent noise.
    public static func ratePerHour(_ samples: [BatterySnapshot]) -> Double? {
        guard let last = samples.last, last.state != .unavailable else { return nil }
        var window = [last]
        for item in samples.dropLast().reversed() {
            guard item.state == last.state, last.date.timeIntervalSince(item.date) <= 900,
                  item.recordingID == last.recordingID,
                  window.last!.date.timeIntervalSince(item.date) <= 180 else { break }
            window.append(item)
        }
        guard window.count >= 3, last.date.timeIntervalSince(window.last!.date) >= 120 else { return nil }
        let xs = window.map { $0.date.timeIntervalSince(last.date) / 3_600 }
        let ys = window.map(\.level)
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let variance = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        guard variance > 0 else { return nil }
        return zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / variance
    }

    public static func chartSamples(_ samples: [BatterySnapshot], limit: Int = 360) -> [BatterySnapshot] {
        guard limit > 1, samples.count > limit else { return samples }
        let stride = Double(samples.count - 1) / Double(limit - 1)
        return (0..<limit).map { samples[Int((Double($0) * stride).rounded())] }
    }
}
