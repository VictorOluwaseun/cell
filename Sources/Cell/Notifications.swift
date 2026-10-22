import AppKit
import UserNotifications
import BatteryCore

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var alertsAllowed = false
    @Published private(set) var soundsAllowed = false
    @Published private(set) var alertStyle: UNAlertStyle = .none
    @Published var failure: String?
    var remindersEnabled = true {
        didSet { if !remindersEnabled { alarm.dismiss() } }
    }
    let alarm: ReminderAlarmController
    private let center = UNUserNotificationCenter.current()
    private static let category = "CELL_CHARGE_REMINDER"
    private static let stopAction = "CELL_STOP_ALARM"
    private static let snoozeAction = "CELL_SNOOZE_ALARM"
    init(defaults: UserDefaults) {
        alarm = ReminderAlarmController(defaults: defaults)
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [
            UNNotificationAction(identifier: Self.stopAction, title: "Stop alarm"),
            UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 5 minutes")
        ], intentIdentifiers: [])])
        Task { await refresh() }
    }
    var bannerStatus: String {
        if authorization == .notDetermined { return "Notification permission has not been requested" }
        if authorization == .denied { return "macOS notifications are turned off for Cell" }
        if authorization == .provisional { return "macOS delivers these notifications quietly" }
        if !alertsAllowed || alertStyle == .none { return "Notifications are allowed, but pop-up banners are off" }
        return alertStyle == .alert ? "Persistent macOS notifications are enabled" : "macOS notification banners are enabled"
    }
    func refresh() async {
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
        alertsAllowed = settings.alertSetting == .enabled
        soundsAllowed = settings.soundSetting == .enabled
        alertStyle = settings.alertStyle
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func request() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]); await refresh() }
        catch { failure = error.localizedDescription }
    }
    func deliver(_ rule: ChargeAlert, level: Double, sound: Bool) async -> Bool {
        guard remindersEnabled else { return false }
        let content = UNMutableNotificationContent()
        content.title = rule.title
        content.body = rule.direction == .below
            ? "Your battery is at \(Int(level.rounded()))%. Connect your charger when you’re ready."
            : "Your battery has reached \(Int(level.rounded()))%. Your charge reminder is ready."
        let message = ReminderAlarmMessage(ruleID: rule.id, title: content.title, body: content.body)
        // Local alarms are independent of notification permission, Focus and banner style.
        alarm.setSoundEnabled(sound)
        alarm.present(message)
        await refresh()
        guard remindersEnabled else { return false }
        guard authorization == .authorized || authorization == .provisional else { return !alarm.session.messages.isEmpty }
        // Avoid layering a system chime over the repeating local alarm.
        if sound && !alarm.isRinging && alarm.session.snoozedUntil == nil { content.sound = .default }
        if alarm.preferences.enabled {
            content.categoryIdentifier = Self.category
            content.userInfo = ["cellAlarmID": message.id.uuidString]
        }
        do {
            try await center.add(UNNotificationRequest(identifier: rule.id.uuidString, content: content, trigger: nil))
            if !remindersEnabled {
                center.removeDeliveredNotifications(withIdentifiers: [rule.id.uuidString])
                return false
            }
            failure = nil; return true
        } catch { failure = error.localizedDescription; return false }
    }
    func test(sound: Bool) async {
        if authorization == .notDetermined { await request() }
        await refresh()
        guard authorization == .authorized || authorization == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cell test notification"
        content.body = "This tests macOS notifications. Use Test alarm in Charge alerts to check Cell’s repeating alarm."
        if sound { content.sound = .default }
        do { try await center.add(UNNotificationRequest(identifier: "cell-test", content: content, trigger: nil)) }
        catch { failure = error.localizedDescription }
    }
    func deliverInsight(id: String, title: String, body: String, sound: Bool, enabled: () -> Bool = { true }) async -> Bool {
        await refresh()
        guard enabled(), authorization == .authorized || authorization == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            if !enabled() { center.removeDeliveredNotifications(withIdentifiers: [id]); return false }
            return true
        } catch { failure = error.localizedDescription; return false }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner, .list] : [.banner, .sound, .list]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["cellAlarmID"] as? String,
              let id = UUID(uuidString: value) else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            guard self.alarm.session.messages.contains(where: { $0.id == id }) else { return }
            switch action {
            case Self.stopAction: self.alarm.dismiss(id: id)
            case Self.snoozeAction: self.alarm.snooze()
            case UNNotificationDefaultActionIdentifier: self.alarm.reveal(id: id)
            default: break
            }
        }
    }
}
