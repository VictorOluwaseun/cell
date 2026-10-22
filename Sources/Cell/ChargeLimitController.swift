import AppKit
import Foundation
import Security
import BatteryCore
import ChargeIPC

private struct ChargeConnectionFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Completes an IPC continuation exactly once, including timeouts and connection loss.
private final class ChargeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private let connection: NSXPCConnection
    init(_ continuation: CheckedContinuation<Data, any Error>, connection: NSXPCConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ result: Result<Data, any Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        connection.invalidationHandler = nil; connection.interruptionHandler = nil
        connection.invalidate(); pending.resume(with: result)
    }
}

@MainActor
final class ChargeLimitController: ObservableObject {
    @Published private(set) var status: ChargeHelperStatus?
    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var lastRefresh = Date.distantPast
    private var refreshing = false
    var enabled: Bool { status?.configuration.enabled == true }
    var title: String {
        guard installed else { return "Charging helper is not installed" }
        guard let status else { return "Charging helper is unavailable" }
        if error != nil || status.error != nil { return "Charge control needs attention" }
        if !status.configuration.enabled { return "Charging limit is off" }
        if status.override { return "Charging to full this time" }
        if !status.onAC { return "Limit ready for your next charge" }
        if status.held { return "Charging paused by Cell" }
        return "Charging allowed up to \(status.configuration.percentage)%"
    }

    func refresh(force: Bool = false) async {
        guard !refreshing, !busy, force || Date.now.timeIntervalSince(lastRefresh) >= 15 else { return }
        installed = FileManager.default.fileExists(atPath: ChargeHelperIdentity.executable)
        guard installed else { status = nil; return }
        refreshing = true; defer { refreshing = false; lastRefresh = .now }
        do { status = try await request(.status); error = status?.error }
        catch { status = nil; self.error = "The helper could not be reached. After rebuilding Cell, reinstall the helper to approve the new build. \(error.localizedDescription)" }
    }

    func configure(percentage: Int, enabled: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { status = try await request(.configure(percentage, enabled)); error = status?.error }
        catch { self.error = error.localizedDescription }
    }
    func chargeToFull() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { status = try await request(.full); error = status?.error }
        catch { self.error = error.localizedDescription }
    }
    func install() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await runInstaller(named: "install-charge-helper")
            installed = true
            status = try await request(.status); error = status?.error
        } catch { self.error = error.localizedDescription }
    }
    func uninstall() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let percentage = status?.configuration.percentage ?? 80
            let released = try await request(.configure(percentage, false))
            status = released
            guard released.error == nil, !released.held, !released.configuration.enabled else {
                throw ChargeConnectionFailure(message: released.error ?? "Charging must be released before removing the helper.")
            }
            try await runInstaller(named: "remove-charge-helper")
            status = nil; installed = false; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private enum Request { case status, configure(Int, Bool), full }
    private func request(_ request: Request) async throws -> ChargeHelperStatus {
        guard let helper = Bundle.main.url(forResource: "helper-requirement", withExtension: "txt") else {
            throw ChargeConnectionFailure(message: "Build and run the bundled Cell.app to use charge control.")
        }
        let requirement = try String(contentsOf: helper, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw ChargeConnectionFailure(message: "The helper signing requirement is invalid. Rebuild Cell.")
        }
        let connection = NSXPCConnection(machServiceName: ChargeHelperIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let reply = ChargeReply(continuation, connection: connection)
            connection.invalidationHandler = { reply.finish(.failure(ChargeConnectionFailure(message: "Charge-helper connection was closed."))) }
            connection.interruptionHandler = { reply.finish(.failure(ChargeConnectionFailure(message: "Charge-helper connection was interrupted."))) }
            connection.resume()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                reply.finish(.failure(ChargeConnectionFailure(message: "Charge-helper request timed out.")))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.finish(.failure($0)) }) as? ChargeHelperProtocol else {
                reply.finish(.failure(ChargeConnectionFailure(message: "Charge-helper interface is unavailable."))); return
            }
            let completion: @Sendable (Data) -> Void = { reply.finish(.success($0)) }
            switch request {
            case .status: proxy.status(reply: completion)
            case let .configure(percentage, enabled): proxy.configure(percentage: percentage, enabled: enabled, reply: completion)
            case .full: proxy.chargeToFull(reply: completion)
            }
        }
        return try JSONDecoder().decode(ChargeHelperStatus.self, from: data)
    }

    private func runInstaller(named name: String) async throws {
        guard let script = Bundle.main.url(forResource: name, withExtension: "sh") else {
            throw ChargeConnectionFailure(message: "The charging installer is missing from this app bundle.")
        }
        let source = Self.installerSource(script)
        let result: String? = await Task.detached(priority: .userInitiated) {
            var failure: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return "Could not prepare administrator authorization." }
            _ = script.executeAndReturnError(&failure)
            if let failure { return failure[NSAppleScript.errorMessage] as? String ?? "Administrator authorization failed." }
            return nil
        }.value
        if let result { throw ChargeConnectionFailure(message: result) }
    }

    static func installerSource(_ script: URL) -> String {
        // No user-controlled percentage or other request data is interpolated into this command.
        let command = "/bin/bash '" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(literal)\" with administrator privileges with prompt \"Cell needs a charging helper to pause and resume battery charging.\""
    }
}
