import Foundation

extension WeeklyReport {
    public func plainText() -> String {
        func number(_ value: Double?, unit: String = "") -> String {
            value.map { String(format: "%.2f", $0) + unit } ?? "Unavailable"
        }
        var lines = ["Cell weekly battery report", "\(start.formatted()) to \(end.formatted())", "",
            "Recorded coverage: \(number(current.observedSeconds / 3_600)) hours",
            "On battery: \(number(current.batterySeconds / 3_600)) hours",
            "Battery energy discharged: \(current.measuredBatterySeconds > 0 ? number(current.dischargedWh) + " Wh" : "Unavailable")",
            "Battery energy charged: \(current.measuredChargeSeconds > 0 ? number(current.chargedWh) + " Wh" : "Unavailable")",
            "Average measured drain: \(number(current.averageDrainWatts, unit: " W"))",
            "Change in average drain vs preceding 7 days: \(number(observedDrainChange, unit: "%"))",
            "Equivalent observed cycles: \(number(current.equivalentCycles))",
            "Recorded sleep sessions: \(sleeps.count)",
            "Capacity health change: \(number(healthChange, unit: " percentage points"))", "", "App activity (hourly buckets; boundary hours may be included):"]
        for app in apps.prefix(10) {
            lines.append("\(app.name): \(app.measuredSeconds > 0 ? number(app.wattHours) + " Wh reported process energy" : "Watts unavailable"), \(number(app.cpuSeconds / 60)) CPU minutes")
        }
        lines += ["", "Only intervals recorded while Cell was running are included. Gaps and sleep are excluded from energy integration. App energy is OS-attributed process energy, not total system consumption. Unattributed hardware energy is excluded."]
        return lines.joined(separator: "\n") + "\n"
    }
}
