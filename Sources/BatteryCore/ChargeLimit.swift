import Foundation

public struct ChargeLimitConfiguration: Codable, Sendable, Equatable {
    public static let allowedRange = 20...100
    public static let hysteresis = 3
    public var enabled: Bool
    public var percentage: Int
    public init(enabled: Bool = false, percentage: Int = 80) {
        self.enabled = enabled; self.percentage = percentage
    }
    public var isValid: Bool { Self.allowedRange.contains(percentage) }
}

public enum ChargeLimitAction: Sendable, Equatable { case pause, release, unchanged }

public enum ChargeLimitPolicy {
    public static func action(configuration: ChargeLimitConfiguration, level: Double?, onAC: Bool,
                              held: Bool, override: Bool) -> ChargeLimitAction {
        guard configuration.enabled, configuration.isValid, !override, onAC,
              let level, level.isFinite, (0...100).contains(level) else {
            return held ? .release : .unchanged
        }
        if level >= Double(configuration.percentage) { return held ? .unchanged : .pause }
        if level <= Double(configuration.percentage - ChargeLimitConfiguration.hysteresis) {
            return held ? .release : .unchanged
        }
        return .unchanged
    }
}

public struct ChargeHelperStatus: Codable, Sendable {
    public var configuration: ChargeLimitConfiguration
    public var supported: Bool
    public var held: Bool
    public var override: Bool
    public var level: Double?
    public var onAC: Bool
    public var error: String?
    public init(configuration: ChargeLimitConfiguration = .init(), supported: Bool = false,
                held: Bool = false, override: Bool = false, level: Double? = nil, onAC: Bool = false, error: String? = nil) {
        self.configuration = configuration; self.supported = supported; self.held = held
        self.override = override; self.level = level; self.onAC = onAC; self.error = error
    }
}
