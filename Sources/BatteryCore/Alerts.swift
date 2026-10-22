import Foundation

public enum AlertDirection: String, CaseIterable, Codable, Sendable {
    case below, above
    public var title: String { self == .below ? "Falls to" : "Charges to" }
}

public struct ChargeAlert: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var direction: AlertDirection
    public var threshold: Int
    public var enabled: Bool
    public init(id: UUID = UUID(), direction: AlertDirection, threshold: Int, enabled: Bool = true) {
        self.id = id; self.direction = direction; self.threshold = min(100, max(1, threshold)); self.enabled = enabled
    }
    public var title: String { direction == .below ? "Low battery" : "Charge reminder" }
}

/// A latch with hysteresis: one alert per crossing, rearmed after moving 2 points away.
public struct AlertEvaluator: Sendable {
    private var latched = Set<UUID>()
    private var configurations: [UUID: ChargeAlert] = [:]
    public init() {}
    public mutating func evaluate(_ snapshot: BatterySnapshot, rules: [ChargeAlert]) -> [ChargeAlert] {
        guard snapshot.state != .unavailable else { return [] }
        let active = Set(rules.filter(\.enabled).map(\.id))
        latched.formIntersection(active)
        for rule in rules where configurations[rule.id] != rule { latched.remove(rule.id) }
        configurations = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var fired: [ChargeAlert] = []
        for rule in rules where rule.enabled {
            let threshold = Double(rule.threshold)
            if rule.direction == .below {
                if snapshot.level >= threshold + 2 { latched.remove(rule.id) }
                if snapshot.state == .discharging, snapshot.level <= threshold, !latched.contains(rule.id) {
                    latched.insert(rule.id); fired.append(rule)
                }
            } else {
                if snapshot.level <= threshold - 2 { latched.remove(rule.id) }
                if snapshot.state.onAC, snapshot.level >= threshold, !latched.contains(rule.id) {
                    latched.insert(rule.id); fired.append(rule)
                }
            }
        }
        return fired
    }
}
