import AppKit
import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor
private struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// macOS owns this preference. Reading its state never registers or re-enables a login item.
@MainActor
final class StartupController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let service: any LoginItemService
    private var activation: AnyCancellable?

    var enabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }
    var registered: Bool { enabled || needsApproval }
    var detail: String {
        switch status {
        case .enabled: "Cell will open automatically when you sign in to your Mac."
        case .requiresApproval: "Allow Cell in System Settings → General → Login Items & Extensions to finish enabling startup."
        case .notRegistered: "Cell opens when you launch it. Turn this on to also open it when you sign in."
        case .notFound: "macOS could not find Cell’s login item. Run the installed Cell.app and try again."
        @unknown default: "macOS could not determine the login-item status. Check Login Items in System Settings."
        }
    }

    init(service: any LoginItemService, observeActivation: Bool = true) {
        self.service = service
        status = service.status
        if observeActivation {
            activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    // AppKit posts this notification on the main thread.
                    MainActor.assumeIsolated { self?.refresh() }
                }
        }
    }
    convenience init() { self.init(service: SystemLoginItemService()) }

    func refresh() {
        guard !busy else { return }
        let actual = service.status
        if actual != status { status = actual; error = nil }
    }
    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        refresh()
        // An approval-pending item is already registered; repeated registration cannot approve it.
        guard value != registered else {
            if error != nil { error = nil }
            return
        }
        busy = true; error = nil
        defer { status = service.status; busy = false }
        do {
            if value { try service.register() }
            else { try await service.unregister() }
        } catch {
            self.error = "Could not \(value ? "enable" : "disable") startup: \(error.localizedDescription)"
        }
    }
    func openSettings() { service.openSettings() }
}
