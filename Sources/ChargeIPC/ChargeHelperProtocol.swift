import Foundation

public enum ChargeHelperIdentity {
    public static let service = "com.cellapp.charge-helper"
    public static let executable = "/Library/PrivilegedHelperTools/com.cellapp.charge-helper"
    public static let directory = "/Library/Application Support/CellChargeHelper"
    public static let launchDaemon = "/Library/LaunchDaemons/com.cellapp.charge-helper.plist"
}

/// No paths, shell commands or arbitrary SMC keys cross this interface.
@objc public protocol ChargeHelperProtocol {
    func status(reply: @escaping @Sendable (Data) -> Void)
    func configure(percentage: Int, enabled: Bool, reply: @escaping @Sendable (Data) -> Void)
    func chargeToFull(reply: @escaping @Sendable (Data) -> Void)
}
