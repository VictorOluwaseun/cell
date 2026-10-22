import Foundation
import Testing
import Darwin
import CChargeControl
@testable import BatteryCore

private let enabledLimit = ChargeLimitConfiguration(enabled: true, percentage: 80)

@Test func pausesAtTheExactTargetAndAbove() {
    for level in [80.0, 81, 100] {
        #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: level, onAC: true, held: false, override: false) == .pause)
    }
}

@Test func limitResumesOnlyBelowTheRearmThreshold() {
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 78, onAC: true, held: true, override: false) == .unchanged)
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 77, onAC: true, held: true, override: false) == .release)
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 79, onAC: true, held: false, override: false) == .unchanged)
}

@Test func doesNotRepeatedlyWriteTheChargeSwitch() {
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 80, onAC: true, held: true, override: false) == .unchanged)
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 50, onAC: true, held: false, override: false) == .unchanged)
}

@Test func disablingAlwaysReleasesOwnedInhibition() {
    #expect(ChargeLimitPolicy.action(configuration: .init(enabled: false), level: 95, onAC: true, held: true, override: false) == .release)
    #expect(ChargeLimitPolicy.action(configuration: .init(enabled: false), level: 95, onAC: true, held: false, override: false) == .unchanged)
}

@Test func fullChargeOverrideReleasesAndDoesNotReapplyTheLimit() {
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 90, onAC: true, held: true, override: true) == .release)
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 100, onAC: true, held: false, override: true) == .unchanged)
}

@Test func disconnectingDoesNotLeaveChargingInhibited() {
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 85, onAC: false, held: true, override: false) == .release)
    #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: 85, onAC: false, held: false, override: false) == .unchanged)
}

@Test func missingOrInvalidTelemetryReleasesInsteadOfHolding() {
    for level: Double? in [nil, .nan, .infinity, -1, 101] {
        #expect(ChargeLimitPolicy.action(configuration: enabledLimit, level: level, onAC: true, held: true, override: false) == .release)
    }
}

@Test func invalidLimitsFailClosedAndRelease() {
    for limit in [-1, 0, 19, 101, Int.max] {
        let configuration = ChargeLimitConfiguration(enabled: true, percentage: limit)
        #expect(!configuration.isValid)
        #expect(ChargeLimitPolicy.action(configuration: configuration, level: 80, onAC: true, held: true, override: false) == .release)
    }
}

@Test func targetCanBeRaisedOrLoweredWhileHolding() {
    #expect(ChargeLimitPolicy.action(configuration: .init(enabled: true, percentage: 90), level: 80, onAC: true, held: true, override: false) == .release)
    #expect(ChargeLimitPolicy.action(configuration: .init(enabled: true, percentage: 70), level: 80, onAC: true, held: false, override: false) == .pause)
}

@Test func chargeLimitStatusRoundTripsWithoutLosingErrorOrOwnership() throws {
    let status = ChargeHelperStatus(configuration: enabledLimit, supported: true, held: true, level: 80, onAC: true, error: "Write was rejected")
    let result = try JSONDecoder().decode(ChargeHelperStatus.self, from: JSONEncoder().encode(status))
    #expect(result.configuration == enabledLimit)
    #expect(result.held)
    #expect(result.error == "Write was rejected")
}

@Test func unprivilegedCallCannotWriteChargeSwitches() {
    guard geteuid() != 0 else { return }
    var state = CellChargeControlState()
    #expect(cell_charge_set_inhibited(1, &state) == 0)
    #expect(state.io_error != 0)
}

@Test func invalidSwitchRequestsAreRejectedBeforeAnyHardwareAccess() {
    for value: Int32 in [-1, 2, 80, Int32.max] {
        var state = CellChargeControlState()
        #expect(cell_charge_set_inhibited(value, &state) == 0)
        #expect(state.backend == 0)
    }
}
