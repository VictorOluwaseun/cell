import Foundation

public enum AppEnergyCSV {
    public static func encode(_ values: [AppEnergyTotal]) -> String {
        func field(_ value: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = ["application,reported_energy_Wh,cpu_core_minutes,observed_seconds,measured_seconds"]
        rows += values.map { value in
            [field(value.name), value.measuredSeconds > 0 ? String(value.wattHours) : "", String(value.cpuSeconds / 60),
             String(value.observedSeconds), String(value.measuredSeconds)].joined(separator: ",")
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
