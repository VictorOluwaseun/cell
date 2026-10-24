import AppKit
import ServiceManagement
import Testing
@testable import Cell

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: (any Error)?
    var unregistrationError: (any Error)?
    var registrations = 0
    var unregistrations = 0
    var settingsOpens = 0
    var delayUnregistration = false
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        status = registrationStatus
    }
    func unregister() async throws {
        unregistrations += 1
        if delayUnregistration {
            await withCheckedContinuation { continuation in
                completion = continuation
                started?.resume(); started = nil
            }
        }
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
    func openSettings() { settingsOpens += 1 }
    func waitForUnregistration() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishUnregistration() { completion?.resume(); completion = nil }
}

private struct LoginItemFailure: LocalizedError {
    var errorDescription: String? { "The requested change was denied." }
}

@Test @MainActor func startupReadsSystemStateWithoutChangingRegistration() {
    let service = FakeLoginItemService(); service.status = .enabled
    let controller = StartupController(service: service, observeActivation: false)
    #expect(controller.enabled && controller.registered)
    #expect(service.registrations == 0 && service.unregistrations == 0)
}

@Test @MainActor func startupEnablesDisablesAndIgnoresDuplicateRequests() async {
    let service = FakeLoginItemService()
    let controller = StartupController(service: service, observeActivation: false)
    await controller.setEnabled(true); await controller.setEnabled(true)
    #expect(controller.enabled && service.registrations == 1)
    await controller.setEnabled(false); await controller.setEnabled(false)
    #expect(!controller.registered && service.unregistrations == 1)
    #expect(controller.error == nil && !controller.busy)
}

@Test @MainActor func startupShowsApprovalAndCanCancelPendingRegistration() async {
    let service = FakeLoginItemService(); service.registrationStatus = .requiresApproval
    let controller = StartupController(service: service, observeActivation: false)
    await controller.setEnabled(true)
    #expect(controller.needsApproval && controller.registered && !controller.enabled)
    await controller.setEnabled(true)
    #expect(service.registrations == 1)
    controller.openSettings()
    #expect(service.settingsOpens == 1)
    await controller.setEnabled(false)
    #expect(!controller.registered && service.unregistrations == 1)
}

@Test @MainActor func startupFailuresKeepConfirmedStateAndDoNotRetry() async {
    let service = FakeLoginItemService(); service.registrationError = LoginItemFailure()
    let controller = StartupController(service: service, observeActivation: false)
    await controller.setEnabled(true)
    #expect(!controller.registered && controller.error != nil && !controller.busy)
    controller.refresh()
    #expect(service.registrations == 1)
    service.registrationError = nil
    await controller.setEnabled(true)
    service.unregistrationError = LoginItemFailure()
    await controller.setEnabled(false)
    #expect(controller.enabled && controller.error != nil && service.unregistrations == 1)
    #expect(service.registrations == 2)
}

@Test @MainActor func startupFollowsSystemSettingsChangesWithoutReenablingItself() {
    let service = FakeLoginItemService(); service.status = .enabled
    let controller = StartupController(service: service, observeActivation: false)
    service.status = .requiresApproval; controller.refresh()
    #expect(controller.needsApproval && !controller.enabled)
    service.status = .enabled; controller.refresh()
    #expect(controller.enabled)
    service.status = .notRegistered; controller.refresh()
    #expect(!controller.registered)
    #expect(service.registrations == 0 && service.unregistrations == 0)
}

@Test @MainActor func startupRefreshesOnAppActivation() {
    let service = FakeLoginItemService()
    let controller = StartupController(service: service)
    service.status = .enabled
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(controller.enabled)
    #expect(service.registrations == 0)
}

@Test @MainActor func startupSerializesChangesDuringAsyncUnregistration() async {
    let service = FakeLoginItemService(); service.status = .enabled; service.delayUnregistration = true
    let controller = StartupController(service: service, observeActivation: false)
    let disable = Task { await controller.setEnabled(false) }
    await service.waitForUnregistration()
    #expect(controller.busy)
    await controller.setEnabled(true)
    #expect(service.registrations == 0 && service.unregistrations == 1)
    service.finishUnregistration(); await disable.value
    #expect(!controller.registered && !controller.busy)
}

@MainActor private func startupDefaults() -> (UserDefaults, String) {
    let domain = "Cell-first-startup-\(UUID().uuidString)"
    return (UserDefaults(suiteName: domain)!, domain)
}
@MainActor private func firstRunStartup(_ service: FakeLoginItemService, defaults: UserDefaults,
                                      path: String = "/Applications/Cell.app") -> StartupController {
    StartupController(service: service, observeActivation: false, defaults: defaults,
                      appURL: URL(fileURLWithPath: path), applicationDirectories: [
                        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/example/Applications")
                      ])
}

@Test(arguments: ["/Applications/Cell.app", "/Applications/Utilities/Cell.app", "/Users/example/Applications/Cell.app"])
@MainActor func startupFreshInstallationRegistersOnce(_ path: String) async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    let controller = firstRunStartup(service, defaults: defaults, path: path)
    #expect(service.registrations == 0) // Construction and state reads remain side-effect free for macOS.
    await controller.configureFirstLaunch(); await controller.configureFirstLaunch()
    #expect(controller.enabled && service.registrations == 1)
    // A later system opt-out survives app restarts.
    service.status = .notRegistered
    let relaunched = firstRunStartup(service, defaults: defaults, path: path)
    await relaunched.configureFirstLaunch()
    #expect(!relaunched.registered && service.registrations == 1)
}

@Test(arguments: ["/Volumes/Cell/Cell.app", "/Users/example/Projects/Cell.app", "/Applications-other/Cell.app"])
@MainActor func startupWaitsUntilFreshAppIsInstalled(_ path: String) async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    let preview = firstRunStartup(service, defaults: defaults, path: path)
    await preview.configureFirstLaunch()
    #expect(!preview.registered && service.registrations == 0)
    // Other controllers save initial data after startup detects the first run.
    defaults.set(Data("[]".utf8), forKey: "chargeProfiles")
    let installed = firstRunStartup(service, defaults: defaults)
    await installed.configureFirstLaunch()
    #expect(installed.enabled && service.registrations == 1)
}

@Test(arguments: ["disabled", "enabled", "approval"])
@MainActor func startupUpgradeKeepsExistingUsersSystemChoice(_ choice: String) async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set(Data("[]".utf8), forKey: "chargeProfiles")
    switch choice { case "enabled": service.status = .enabled; case "approval": service.status = .requiresApproval; default: break }
    let before = service.status, controller = firstRunStartup(service, defaults: defaults)
    await controller.configureFirstLaunch()
    #expect(controller.status == before && service.registrations == 0 && service.unregistrations == 0)
}

@Test @MainActor func startupManualOptOutCancelsPendingFirstRunSetup() async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    let preview = firstRunStartup(service, defaults: defaults, path: "/Volumes/Cell/Cell.app")
    await preview.setEnabled(false)
    let installed = firstRunStartup(service, defaults: defaults)
    await installed.configureFirstLaunch()
    #expect(!installed.registered && service.registrations == 0)
}

@Test @MainActor func startupAutomaticFailureIsVisibleAndDoesNotRetryUntilRequested() async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    service.registrationError = LoginItemFailure()
    let controller = firstRunStartup(service, defaults: defaults)
    await controller.configureFirstLaunch(); await controller.configureFirstLaunch()
    #expect(controller.error != nil && !controller.enabled && service.registrations == 1)
    let relaunched = firstRunStartup(service, defaults: defaults)
    await relaunched.configureFirstLaunch()
    #expect(service.registrations == 1)
    service.registrationError = nil
    await relaunched.setEnabled(true)
    #expect(relaunched.enabled && service.registrations == 2)
}

@Test @MainActor func startupAutomaticRegistrationShowsApprovalAndRespectsCancellation() async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    service.registrationStatus = .requiresApproval
    let controller = firstRunStartup(service, defaults: defaults)
    await controller.configureFirstLaunch()
    #expect(controller.needsApproval && !controller.enabled && service.registrations == 1)
    await controller.configureFirstLaunch(); await controller.setEnabled(false)
    let relaunched = firstRunStartup(service, defaults: defaults)
    await relaunched.configureFirstLaunch()
    #expect(!relaunched.registered && service.registrations == 1 && service.unregistrations == 1)
}

@Test @MainActor func startupExistingSystemRegistrationIsNotReplacedOnFirstRun() async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    service.status = .enabled
    let controller = firstRunStartup(service, defaults: defaults, path: "/Volumes/Cell/Cell.app")
    await controller.configureFirstLaunch()
    service.status = .notRegistered
    let installed = firstRunStartup(service, defaults: defaults)
    await installed.configureFirstLaunch()
    #expect(!installed.registered && service.registrations == 0)
}

@Test @MainActor func startupMissingDevelopmentLoginItemKeepsPendingInstallationSetup() async {
    let (defaults, domain) = startupDefaults(), service = FakeLoginItemService()
    defer { defaults.removePersistentDomain(forName: domain) }
    service.status = .notFound
    let preview = firstRunStartup(service, defaults: defaults, path: "/Users/example/Projects/Cell.app")
    await preview.configureFirstLaunch()
    #expect(service.registrations == 0)
    service.status = .notRegistered
    let installed = firstRunStartup(service, defaults: defaults)
    await installed.configureFirstLaunch()
    #expect(installed.enabled && service.registrations == 1)
}
