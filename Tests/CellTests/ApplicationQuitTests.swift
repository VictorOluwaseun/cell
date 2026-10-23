import AppKit
import Combine
import Testing
@testable import Cell

@MainActor
private final class FakeQuitApplication: QuittableApplication {
    var target: ApplicationQuitTarget?
    var isTerminated = false
    var acceptsQuit = true
    var terminateOnRequest = false
    var terminateOnObserve = false
    var quitCalls = 0
    private let termination = PassthroughSubject<Void, Never>()
    init(target: ApplicationQuitTarget) { self.target = target }
    func requestQuit() -> Bool {
        quitCalls += 1
        if terminateOnRequest { finish() }
        return acceptsQuit
    }
    func observeTermination(_ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let observation = termination.sink { action() }
        if terminateOnObserve { finish() }
        return observation
    }
    func finish() { isTerminated = true; termination.send() }
}

@MainActor
private final class FakeQuitService: ApplicationQuitService {
    var applications: [Int32: FakeQuitApplication] = [:]
    var lookups = 0
    func application(pid: Int32) -> (any QuittableApplication)? { lookups += 1; return applications[pid] }
}

private func quitTarget(pid: Int32 = 321) -> ApplicationQuitTarget {
    .init(pid: pid, launchDate: Date(timeIntervalSince1970: 1_700_000_000),
          bundlePath: "/Applications/Example.app", bundleIdentifier: "com.example.app")
}
private func quitRow(_ target: ApplicationQuitTarget? = quitTarget()) -> AppActivity {
    .init(id: target?.pid ?? 321, name: "Example", bundlePath: target?.bundlePath, cpuPercent: 5,
          watts: 1, wakeups: 0, memory: 100, processes: 3, quitTarget: target)
}

@Test @MainActor func quitWaitsForActualExitAndCoalescesRepeatedClicks() {
    let target = quitTarget(), service = FakeQuitService(), application = FakeQuitApplication(target: quitTarget())
    service.applications[target.pid] = application
    let controller = ApplicationQuitController(service: service)
    var completed: [ApplicationQuitTarget] = []
    controller.onTermination = { completed.append($0) }
    controller.requestQuit(quitRow()); controller.requestQuit(quitRow())
    #expect(application.quitCalls == 1 && controller.pending == [target])
    #expect(completed.isEmpty && controller.message?.contains("requested") == true)
    application.finish()
    #expect(controller.pending.isEmpty && completed == [target])
    #expect(controller.message == "Example has quit.")
    application.finish()
    #expect(completed.count == 1)
}

@Test @MainActor func quitRejectsReusedPIDAndChangedBundles() {
    let original = quitTarget()
    var relaunched = original; relaunched.launchDate = original.launchDate.addingTimeInterval(1)
    var otherPath = original; otherPath.bundlePath = "/Applications/Other.app"
    var otherIdentifier = original; otherIdentifier.bundleIdentifier = "com.example.other"
    for changed in [relaunched, otherPath, otherIdentifier] {
        let service = FakeQuitService(), application = FakeQuitApplication(target: changed)
        service.applications[original.pid] = application
        let controller = ApplicationQuitController(service: service)
        controller.requestQuit(quitRow(original))
        #expect(application.quitCalls == 0 && controller.pending.isEmpty && controller.failed)
    }
}

@Test @MainActor func quitCannotTargetProcessesCellOrMismatchedRows() {
    let service = FakeQuitService(), controller = ApplicationQuitController(service: FakeQuitService())
    controller.requestQuit(quitRow(nil))
    #expect(controller.failed && controller.pending.isEmpty)
    let guarded = ApplicationQuitController(service: service)
    guarded.requestQuit(quitRow(quitTarget(pid: ProcessInfo.processInfo.processIdentifier)))
    guarded.requestQuit(quitRow(quitTarget(pid: 1)))
    var mismatched = quitRow(); mismatched.id += 1
    guarded.requestQuit(mismatched)
    #expect(service.lookups == 0 && guarded.pending.isEmpty)
    #expect(ApplicationQuitTarget.make(NSRunningApplication.current) == nil)
}

@Test @MainActor func quitHandlesMissingOrNewlyIneligibleApplications() {
    let service = FakeQuitService(), controller = ApplicationQuitController(service: FakeQuitService())
    controller.requestQuit(quitRow())
    #expect(controller.failed && controller.pending.isEmpty)
    let application = FakeQuitApplication(target: quitTarget()); application.target = nil
    service.applications[321] = application
    let guarded = ApplicationQuitController(service: service)
    guarded.requestQuit(quitRow())
    #expect(application.quitCalls == 0 && guarded.failed && guarded.pending.isEmpty)
}

@Test @MainActor func quitRejectionReportsFailureWithoutRemovingTheApp() {
    let service = FakeQuitService(), application = FakeQuitApplication(target: quitTarget())
    application.acceptsQuit = false; service.applications[321] = application
    let controller = ApplicationQuitController(service: service)
    var completed = false; controller.onTermination = { _ in completed = true }
    controller.requestQuit(quitRow())
    #expect(controller.failed && controller.pending.isEmpty && !completed)
    #expect(application.quitCalls == 1 && !application.isTerminated)
}

@Test @MainActor func quitTimeoutDoesNotClaimSuccessOrEscalate() {
    let target = quitTarget(), service = FakeQuitService(), application = FakeQuitApplication(target: quitTarget())
    service.applications[target.pid] = application
    let controller = ApplicationQuitController(service: service)
    var completed = false; controller.onTermination = { _ in completed = true }
    controller.requestQuit(quitRow()); controller.checkPending(target)
    #expect(controller.pending.isEmpty && !completed && !controller.failed)
    #expect(controller.message?.contains("still running") == true)
    #expect(application.quitCalls == 1 && !application.isTerminated)
    application.finish()
    #expect(!completed) // Late exits are picked up by normal activity sampling after the wait expires.
}

@Test @MainActor func quitHandlesExitDuringObservationOrRequestExactlyOnce() {
    for exitsDuringObservation in [false, true] {
        let service = FakeQuitService(), application = FakeQuitApplication(target: quitTarget())
        application.terminateOnObserve = exitsDuringObservation
        application.terminateOnRequest = !exitsDuringObservation
        service.applications[321] = application
        let controller = ApplicationQuitController(service: service)
        var completions = 0; controller.onTermination = { _ in completions += 1 }
        controller.requestQuit(quitRow())
        #expect(completions == 1 && controller.pending.isEmpty && !controller.failed)
        #expect(application.quitCalls == (exitsDuringObservation ? 0 : 1))
        #expect(controller.message == "Example has quit.")
    }
}

@Test @MainActor func disablingQuitTrackingCancelsPendingObservers() {
    let service = FakeQuitService(), application = FakeQuitApplication(target: quitTarget())
    service.applications[321] = application
    let controller = ApplicationQuitController(service: service)
    var completions = 0; controller.onTermination = { _ in completions += 1 }
    controller.requestQuit(quitRow()); controller.cancelRequests(); controller.dismissMessage()
    application.finish()
    #expect(controller.pending.isEmpty && completions == 0 && controller.message == nil)
    #expect(application.quitCalls == 1)
}

@Test @MainActor func separateApplicationsKeepIndependentPendingState() {
    let service = FakeQuitService(), first = quitTarget(), second = quitTarget(pid: 322)
    let a = FakeQuitApplication(target: first), b = FakeQuitApplication(target: second)
    service.applications = [first.pid: a, second.pid: b]
    let controller = ApplicationQuitController(service: service)
    controller.requestQuit(quitRow(first)); controller.requestQuit(quitRow(second))
    a.finish()
    #expect(controller.pending == [second] && a.quitCalls == 1 && b.quitCalls == 1)
    b.finish()
    #expect(controller.pending.isEmpty)
}
