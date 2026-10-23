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
