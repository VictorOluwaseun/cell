import Foundation

public enum CellFeature: String, CaseIterable, Sendable {
    case batteryHistory, appActivity, appEnergyHistory, runtimeForecast, sleepTracking, healthHistory
    case timeline, reports, chargingProfiles, chargingExplanation, advancedReadings, chargeAlerts, menuBar

    private var key: String { self == .appActivity ? "appMonitoring" : "feature.\(rawValue)" }

    /// Existing installations keep their behavior; a missing preference means enabled.
    fileprivate func load(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
    fileprivate func save(_ enabled: Bool, to defaults: UserDefaults) { defaults.set(enabled, forKey: key) }
}

/// User choices stay independent of prerequisites, so pausing a parent does not erase child choices.
public struct FeaturePreferences: Equatable, Sendable {
    private var disabled: Set<CellFeature> = []
    public init() {}
    public init(defaults: UserDefaults) {
        disabled = Set(CellFeature.allCases.filter { !$0.load(from: defaults) })
    }
    public subscript(_ feature: CellFeature) -> Bool {
        get { !disabled.contains(feature) }
        set { if newValue { disabled.remove(feature) } else { disabled.insert(feature) } }
    }
    public func save(to defaults: UserDefaults) {
        for feature in CellFeature.allCases { feature.save(self[feature], to: defaults) }
    }
    public var recordsAppEnergy: Bool { self[.batteryHistory] && self[.appActivity] && self[.appEnergyHistory] }
    public var recordsSleep: Bool { self[.batteryHistory] && self[.sleepTracking] }
    public var recordsHealth: Bool { self[.batteryHistory] && self[.healthHistory] }
    public var recordsTimeline: Bool { self[.batteryHistory] && self[.timeline] }
    public var generatesReports: Bool { self[.batteryHistory] && self[.reports] }
}
