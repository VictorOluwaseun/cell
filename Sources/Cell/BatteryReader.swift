import Foundation
import IOKit
import IOKit.ps
import BatteryCore

struct BatteryReader: Sendable {
    func read() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .unavailable }
        var description: [String: Any]?
        for source in sources {
            if let item = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               item[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                description = item; break
            }
        }
        guard let description,
              let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0 else { return .unavailable }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        var properties: [String: Any] = [:]
        if service != 0 {
            defer { IOObjectRelease(service) }
            var raw: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                properties = raw?.takeRetainedValue() as? [String: Any] ?? [:]
            }
        }
        func number(_ key: String) -> Double? { (properties[key] as? NSNumber)?.doubleValue }
        func positive(_ key: String) -> Double? { number(key).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let full = description[kIOPSIsChargedKey] as? Bool ?? (current >= maximum)
        let state: BatteryState = charging ? .charging : (onAC ? (full ? .full : .pluggedIn) : .discharging)
        let currentNumber = (properties["InstantAmperage"] ?? properties["Amperage"]) as? NSNumber
        // Drivers may encode negative current as an unsigned two's-complement integer.
        let signedCurrent = currentNumber.map { number -> Double in
            let raw = number.uint64Value
            if raw > UInt64(Int32.max), raw <= UInt64(UInt32.max) {
                return Double(Int32(bitPattern: UInt32(raw)))
            }
            return Double(Int64(bitPattern: raw))
        }
        let currentMA = signedCurrent.flatMap { abs($0) < 100_000 ? $0 : nil }
        let voltage = positive("Voltage").map { $0 / 1_000 }
        let temperature = number("Temperature").map { $0 / 100 }.flatMap { (-20...100).contains($0) ? $0 : nil }
        let telemetry = properties["PowerTelemetryData"] as? [String: Any]
        let systemWatts = (telemetry?["SystemPowerIn"] as? NSNumber)?.doubleValue
        let adapter = properties["AdapterDetails"] as? [String: Any]
        let timeKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let minutes = (description[timeKey] as? NSNumber)?.intValue
        return BatterySnapshot(
            level: min(100, max(0, current / maximum * 100)), state: state,
            cycleCount: number("CycleCount").map(Int.init), designCapacity: positive("DesignCapacity"),
            fullCapacity: positive("NominalChargeCapacity") ?? positive("AppleRawMaxCapacity"),
            currentCapacity: positive("AppleRawCurrentCapacity"), voltage: voltage, currentMA: currentMA,
            temperature: temperature,
            systemWatts: onAC ? systemWatts.flatMap { $0 >= 0 && $0 < 1_000_000 ? $0 / 1_000 : nil } : nil,
            adapterWatts: onAC ? (adapter?["Watts"] as? NSNumber)?.doubleValue : nil,
            minutesRemaining: (charging || !onAC) ? minutes.flatMap { $0 > 0 && $0 < 65_535 ? $0 : nil } : nil
        )
    }
}
