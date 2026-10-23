import AppKit
import Combine

/// PID alone is insufficient: it can be reused while a confirmation is open.
struct ApplicationQuitTarget: Hashable, Sendable {
    var pid: Int32
    var launchDate: Date
    var bundlePath: String
    var bundleIdentifier: String?

    @MainActor
    static func make(_ application: NSRunningApplication) -> Self? {
        guard !application.isTerminated, application.processIdentifier > 1,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy != .prohibited,
              application.bundleIdentifier != "com.apple.finder",
              let launchDate = application.launchDate, let url = application.bundleURL,
              url.pathExtension == "app", !url.path.hasPrefix("/System/Library/"),
              !url.path.contains(".app/Contents/") else { return nil }
        return .init(pid: application.processIdentifier, launchDate: launchDate,
                     bundlePath: url.standardizedFileURL.path, bundleIdentifier: application.bundleIdentifier)
    }
}

@MainActor
protocol QuittableApplication {
    var target: ApplicationQuitTarget? { get }
    var isTerminated: Bool { get }
    func requestQuit() -> Bool
    func observeTermination(_ action: @escaping @MainActor () -> Void) -> AnyCancellable
}

@MainActor
protocol ApplicationQuitService {
    func application(pid: Int32) -> (any QuittableApplication)?
}

@MainActor
private struct SystemApplicationQuitService: ApplicationQuitService {
    func application(pid: Int32) -> (any QuittableApplication)? {
        NSRunningApplication(processIdentifier: pid).map(SystemQuittableApplication.init)
    }
}

@MainActor
private final class SystemQuittableApplication: QuittableApplication {
    private let application: NSRunningApplication
    init(_ application: NSRunningApplication) { self.application = application }
    var target: ApplicationQuitTarget? { .make(application) }
    var isTerminated: Bool { application.isTerminated }
    func requestQuit() -> Bool { application.terminate() }
    func observeTermination(_ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        application.publisher(for: \.isTerminated, options: [.initial, .new])
            .filter { $0 }.receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { action() } }
    }
}

@MainActor
final class ApplicationQuitController: ObservableObject {
    @Published private(set) var pending: Set<ApplicationQuitTarget> = []
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    var onTermination: ((ApplicationQuitTarget) -> Void)?
    private struct Request {
        var application: any QuittableApplication
        var name: String
        var observation: AnyCancellable?
        var timeout: Task<Void, Never>?
    }
    private let service: any ApplicationQuitService
    private let timeout: Duration
    private var requests: [ApplicationQuitTarget: Request] = [:]

    init(service: any ApplicationQuitService, timeout: Duration = .seconds(20)) {
        self.service = service; self.timeout = timeout
    }
    convenience init() { self.init(service: SystemApplicationQuitService()) }

    func requestQuit(_ app: AppActivity) {
        guard let target = app.quitTarget, target.pid == app.id,
              target.pid > 1, target.pid != ProcessInfo.processInfo.processIdentifier else {
            show("This row is not a quittable application.", failed: true); return
        }
        guard !pending.contains(target) else { return }
        guard let application = service.application(pid: target.pid) else {
            show("\(app.name) is no longer available. Refresh App activity and try again.", failed: true); return
        }
        // Revalidate the same launch and bundle, including eligibility, at the final user action.
        guard !application.isTerminated, application.target == target else {
            show("This instance of \(app.name) is no longer running. Refresh App activity and try again.", failed: true); return
        }
        requests[target] = Request(application: application, name: app.name)
        pending.insert(target)
        let observation = application.observeTermination { [weak self] in self?.didTerminate(target) }
        guard requests[target] != nil else { observation.cancel(); return }
        requests[target]?.observation = observation
        if application.isTerminated { didTerminate(target); return }
        let accepted = application.requestQuit()
        if application.isTerminated { didTerminate(target); return }
        guard requests[target] != nil else { return }
        guard accepted else {
            remove(target)
            show("\(app.name) could not accept the quit request. You can try quitting it from its own menu.", failed: true)
            return
        }
        show("Quit requested for \(app.name). It may ask you to save or close documents.")
        let timeout = self.timeout
        requests[target]?.timeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.checkPending(target)
        }
    }

    func checkPending(_ target: ApplicationQuitTarget) {
        guard let request = requests[target] else { return }
        if request.application.isTerminated { didTerminate(target); return }
        remove(target)
        show("\(request.name) is still running. It may be waiting for you to save work, or the quit request may have been cancelled.")
    }
    private func didTerminate(_ target: ApplicationQuitTarget) {
        guard let request = requests[target] else { return }
        remove(target)
        show("\(request.name) has quit.")
        onTermination?(target)
    }
    private func remove(_ target: ApplicationQuitTarget) {
        let request = requests.removeValue(forKey: target)
        request?.observation?.cancel(); request?.timeout?.cancel()
        pending.remove(target)
    }
    func cancelRequests() {
        for target in Array(requests.keys) { remove(target) }
    }
    func dismissMessage() { message = nil; failed = false }
    private func show(_ text: String, failed: Bool = false) { message = text; self.failed = failed }
}
