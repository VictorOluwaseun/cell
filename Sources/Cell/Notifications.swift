import AppKit
import UserNotifications
import BatteryCore

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .notDetermined
    @Published var failure: String?
    private let center = UNUserNotificationCenter.current()
    override init() {
        super.init()
        center.delegate = self
        Task { await refresh() }
    }
    func refresh() async { authorization = await center.notificationSettings().authorizationStatus }
    func request() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]); await refresh() }
        catch { failure = error.localizedDescription }
    }
    func deliver(_ rule: ChargeAlert, level: Double, sound: Bool) async -> Bool {
        await refresh()
        guard authorization == .authorized || authorization == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = rule.title
        content.body = rule.direction == .below
            ? "Your battery is at \(Int(level.rounded()))%. Connect your charger when you’re ready."
            : "Your battery has reached \(Int(level.rounded()))%. Your charge reminder is ready."
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: rule.id.uuidString, content: content, trigger: nil))
            return true
        } catch { failure = error.localizedDescription; return false }
    }
    func test(sound: Bool) async {
        if authorization == .notDetermined { await request() }
        await refresh()
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cell test notification"
        content.body = "Charge reminders can reach you on this Mac."
        if sound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: "cell-test", content: content, trigger: nil)) }
        catch { failure = error.localizedDescription }
    }
    func deliverInsight(id: String, title: String, body: String, sound: Bool) async -> Bool {
        await refresh()
        guard authorization == .authorized || authorization == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch { failure = error.localizedDescription; return false }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
