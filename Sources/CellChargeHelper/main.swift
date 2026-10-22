import Foundation
import IOKit
import IOKit.pwr_mgt
import BatteryCore
import ChargeIPC
import ChargeHardware
import Security

private struct ClientTrust: Decodable { var requirement: String; var uid: UInt32 }
private struct PersistedState: Codable {
    var configuration = ChargeLimitConfiguration()
    var ownsInhibition = false
}

/// All mutable state and all hardware operations belong to one serial queue.
private final class ChargeService: NSObject, NSXPCListenerDelegate, ChargeHelperProtocol, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.cellapp.charge-helper.control", qos: .utility)
    private var saved = PersistedState()
    private var overrideUntilUnplugged = false
    private var sleeping = false
    private var statusValue = ChargeHelperStatus()
    private var trust: ClientTrust
    private var timer: DispatchSourceTimer?
    private var signalSource: DispatchSourceSignal?
    private let stateURL = URL(fileURLWithPath: ChargeHelperIdentity.directory + "/state.json")
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0

    init(trust: ClientTrust) throws {
        self.trust = trust
        super.init()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            saved = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL))
            guard saved.configuration.isValid else { throw ChargeHardwareError("Invalid saved charging configuration.") }
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
        queue.async { self.tick() }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in
            // Restore only an inhibition that this helper owns; keep the configured target for relaunch.
            try? self?.releaseOwnedInhibition()
            exit(0)
        }
        source.resume(); signalSource = source
        installPowerNotifications()
    }

    private func installPowerNotifications() {
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerPort, { context, _, message, argument in
            guard let context else { return }
            let service = Unmanaged<ChargeService>.fromOpaque(context).takeUnretainedValue()
            let identifier = Int(bitPattern: argument)
            if message == ChargeHardware.willSleepMessage {
                service.queue.sync {
                    service.sleeping = true
                    if service.saved.configuration.enabled && !service.overrideUntilUnplugged && ChargeHardware.battery().onAC {
                        do { try service.pause() } catch { service.statusValue.error = error.localizedDescription }
                    }
                }
                IOAllowPowerChange(service.powerConnection, identifier)
            } else if message == ChargeHardware.canSleepMessage {
                IOAllowPowerChange(service.powerConnection, identifier)
            } else if message == ChargeHardware.didWakeMessage {
                service.queue.async { service.sleeping = false; service.tick() }
            }
        }, &powerNotifier)
        if let powerPort, let runLoopSource = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == trust.uid else { return false }
        // The kernel checks the peer's code requirement on every message, avoiding PID reuse races.
        connection.setCodeSigningRequirement(trust.requirement)
        connection.exportedInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        connection.exportedObject = self
        connection.resume(); return true
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        queue.async { self.tick(); reply(self.encodedStatus()) }
    }
    func configure(percentage: Int, enabled: Bool, reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            do {
                let configuration = ChargeLimitConfiguration(enabled: enabled, percentage: percentage)
                guard configuration.isValid else { throw ChargeHardwareError("Choose a limit from 20% to 100%.") }
                if enabled {
                    guard self.powerConnection != 0 else { throw ChargeHardwareError("Sleep monitoring is unavailable. Cell cannot safely enable the limit.") }
                    guard ChargeHardware.battery().level != nil else { throw ChargeHardwareError("No internal battery is available.") }
                    let hardware = try ChargeHardware.probe()
                    if hardware.inhibited && !self.saved.ownsInhibition {
                        throw ChargeHardwareError("Charging is already inhibited by another controller. Disable that controller before enabling Cell’s limit.")
                    }
                }
                let oldConfiguration = self.saved.configuration
                self.saved.configuration = configuration
                do { try self.persist() } catch { self.saved.configuration = oldConfiguration; throw error }
                self.overrideUntilUnplugged = false
                self.tick()
            } catch { self.updateStatus(error: error.localizedDescription) }
            reply(self.encodedStatus())
        }
    }
    func chargeToFull(reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            do {
                try self.releaseOwnedInhibition()
                self.overrideUntilUnplugged = ChargeHardware.battery().onAC
                self.tick()
            } catch { self.updateStatus(error: error.localizedDescription) }
            reply(self.encodedStatus())
        }
    }

    private func tick() {
        guard !sleeping else { return }
        defer { updatePolling() }
        let battery = ChargeHardware.battery()
        if !battery.onAC { overrideUntilUnplugged = false }
        do {
            if saved.configuration.enabled || saved.ownsInhibition {
                let hardware = try ChargeHardware.probe()
                if saved.ownsInhibition && !hardware.inhibited {
                    saved.ownsInhibition = false; try persist()
                }
                if hardware.inhibited && !saved.ownsInhibition && saved.configuration.enabled {
                    throw ChargeHardwareError("Another controller has paused charging. Cell will not override it.")
                }
                switch ChargeLimitPolicy.action(configuration: saved.configuration, level: battery.level,
                    onAC: battery.onAC, held: saved.ownsInhibition, override: overrideUntilUnplugged) {
                case .pause: try pause()
                case .release: try releaseOwnedInhibition()
                case .unchanged: break
                }
            }
            updateStatus(error: nil)
        } catch { updateStatus(error: error.localizedDescription) }
    }

    private func updatePolling() {
        if saved.configuration.enabled || saved.ownsInhibition {
            timer?.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        } else { timer?.schedule(deadline: .distantFuture) }
    }

    private func pause() throws {
        guard !saved.ownsInhibition else { return }
        let hardware = try ChargeHardware.probe()
        guard !hardware.inhibited else { throw ChargeHardwareError("Charging is already controlled by another app.") }
        // Persist ownership before touching hardware so a crash can be recovered on relaunch.
        saved.ownsInhibition = true
        do { try persist() } catch { saved.ownsInhibition = false; throw error }
        do { try ChargeHardware.setInhibited(true) }
        catch {
            // Keep ownership if rollback failed and the hardware is still inhibited.
            if let reading = try? ChargeHardware.probe(), !reading.inhibited {
                saved.ownsInhibition = false; try? persist()
            }
            throw error
        }
    }
    private func releaseOwnedInhibition() throws {
        guard saved.ownsInhibition else { return }
        let hardware = try ChargeHardware.probe()
        if hardware.inhibited { try ChargeHardware.setInhibited(false) }
        saved.ownsInhibition = false; try persist()
    }
    private func updateStatus(error: String?) {
        let battery = ChargeHardware.battery()
        let supported = (try? ChargeHardware.probe()) != nil
        statusValue = .init(configuration: saved.configuration, supported: supported, held: saved.ownsInhibition,
                            override: overrideUntilUnplugged, level: battery.level, onAC: battery.onAC, error: error)
    }
    private func persist() throws {
        try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    private func encodedStatus() -> Data { (try? JSONEncoder().encode(statusValue)) ?? Data() }
}

if CommandLine.arguments.contains("--probe") {
    do {
        let value = try ChargeHardware.probe()
        print("Charge switch backend: \(value.backend == 1 ? "CHTE" : "CH0B + CH0C"); inhibited: \(value.inhibited)")
        exit(0)
    } catch { print(error.localizedDescription); exit(2) }
}

do {
    guard geteuid() == 0 else { throw ChargeHardwareError("Install the charging helper from Cell. It must run as a root launch daemon.") }
    let directory = ChargeHelperIdentity.directory
    let attributes = try FileManager.default.attributesOfItem(atPath: directory)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
          ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
        throw ChargeHardwareError("The helper’s trust directory must be root-owned and private.")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/client-trust.plist"))
    let trust = try PropertyListDecoder().decode(ClientTrust.self, from: data)
    guard trust.uid > 0, !trust.requirement.isEmpty, trust.requirement.utf8.count < 4_096 else {
        throw ChargeHardwareError("Invalid client trust configuration.")
    }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(trust.requirement as CFString, [], &requirement) == errSecSuccess else {
        throw ChargeHardwareError("Invalid client signing requirement.")
    }
    let service = try ChargeService(trust: trust)
    let listener = NSXPCListener(machServiceName: ChargeHelperIdentity.service)
    listener.delegate = service; listener.resume(); service.start()
    RunLoop.main.run()
} catch {
    fputs("CellChargeHelper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
