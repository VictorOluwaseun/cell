import Foundation
import IOKit.ps
import CChargeControl

public struct ChargeHardwareReading: Sendable {
    public var level: Double?
    public var onAC: Bool
    public init(level: Double?, onAC: Bool) { self.level = level; self.onAC = onAC }
}

public struct ChargeSwitchState: Sendable {
    public var backend: Int
    public var inhibited: Bool
}

public struct ChargeHardwareError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum ChargeHardware {
    public static let willSleepMessage = UInt32(CellPowerWillSleep)
    public static let canSleepMessage = UInt32(CellPowerCanSleep)
    public static let didWakeMessage = UInt32(CellPowerDidWake)
    public static func battery() -> ChargeHardwareReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .init(level: nil, onAC: false)
        }
        for source in sources {
            guard let item = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  item[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = (item[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (item[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0 else { continue }
            return .init(level: min(100, max(0, current / maximum * 100)),
                         onAC: item[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return .init(level: nil, onAC: false)
    }

    public static func probe() throws -> ChargeSwitchState {
        var state = CellChargeControlState()
        guard cell_charge_probe(&state) != 0 else {
            throw ChargeHardwareError("Charge control is unavailable or another controller has set an unrecognized state (IOKit \(state.io_error), SMC \(state.smc_error)).")
        }
        return .init(backend: Int(state.backend), inhibited: state.inhibited != 0)
    }
    public static func setInhibited(_ inhibited: Bool) throws {
        var state = CellChargeControlState()
        guard cell_charge_set_inhibited(inhibited ? 1 : 0, &state) != 0 else {
            throw ChargeHardwareError("macOS did not confirm the charging change (IOKit \(state.io_error), SMC \(state.smc_error)).")
        }
    }
}
