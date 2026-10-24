import SwiftUI
import AppKit
import UserNotifications
import BatteryCore

struct AlertsView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var notifications: NotificationService
    @State private var direction: AlertDirection = .above
    @State private var threshold = 80.0
    var body: some View {
        VStack(spacing: 20) {
            permissionPanel
            AppResourceAlertSettingsView(controller: monitor.appResourceAlerts, notifications: notifications)
            AppResourceAlertHistoryView(controller: monitor.appResourceAlerts)
            if monitor.features[.chargeAlerts] {
                ReminderAlarmSettingsView(monitor: monitor, controller: notifications.alarm)
                Panel("Percentage reminders", subtitle: "Reminders fire once, then rearm after the battery moves 2% away.") {
                    if monitor.alerts.isEmpty {
                        EmptyMessage(icon: "bell.badge", title: "Choose your first reminder", detail: "Add a charge target or a low-battery reminder below.")
                    }
                    ForEach($monitor.alerts) { $rule in
                        HStack(spacing: 15) {
                            Image(systemName: rule.direction == .above ? "battery.100percent.bolt" : "battery.25percent")
                                .foregroundStyle(rule.direction == .above ? Palette.mint : Palette.amber)
                                .font(.system(size: 22)).frame(width: 42, height: 45)
                                .background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rule.title).font(.system(size: 14, weight: .medium))
                                Text("\(rule.direction.title) \(rule.threshold)% \(rule.direction == .above ? "while connected" : "on battery")")
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Toggle("Enable \(rule.title) at \(rule.threshold)%", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                            Button(role: .destructive) { monitor.alerts.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash").padding(8) }
                                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Delete reminder").accessibilityLabel("Delete \(rule.title) at \(rule.threshold)%")
                        }.padding(.vertical, 7)
                    }
                }
                Panel("Add a percentage reminder") {
                    HStack(spacing: 20) {
                        Picker("When the battery", selection: $direction) {
                            ForEach(AlertDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.frame(width: 230)
                        Slider(value: $threshold, in: 1...100, step: 1).accessibilityLabel("Battery threshold")
                        Text("\(Int(threshold))%").font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 58)
                        Button("Add reminder") {
                            monitor.alerts.append(ChargeAlert(direction: direction, threshold: Int(threshold)))
                        }.buttonStyle(.borderedProminent).disabled(duplicate)
                    }
                    if duplicate { Text("You already have a reminder at this threshold.").font(.system(size: 11)).foregroundStyle(Palette.amber) }
                }
                TimedRemindersView(controller: monitor.timeReminders)
            }
            Panel {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "moon.zzz").foregroundStyle(Palette.violet)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep Cell running for reminders").font(.system(size: 13, weight: .medium))
                        Text("Closing the window keeps Cell in the menu bar. Reminders are checked while your Mac is awake and when it wakes. macOS Focus and notification settings can affect delivery. A charge reminder does not stop charging.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                }
            }
        }.task { await notifications.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await notifications.refresh() }
            }
    }
    private var duplicate: Bool { monitor.alerts.contains { $0.direction == direction && $0.threshold == Int(threshold) } }
    private var permissionPanel: some View {
        Panel {
            HStack(spacing: 15) {
                Image(systemName: notifications.authorization == .authorized ? "bell.badge.fill" : "bell.slash")
                    .font(.system(size: 22)).foregroundStyle(Palette.violet)
                VStack(alignment: .leading, spacing: 6) {
                    Text(notifications.bannerStatus)
                        .font(.system(size: 14, weight: .medium))
                    Text("For macOS pop-ups, choose Banners or Alerts for Cell in System Settings → Notifications. Focus can still silence them. Cell’s own alarm works separately.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    if notifications.authorization == .authorized || notifications.authorization == .provisional {
                        Text(notifications.soundsAllowed ? "macOS notification sound is enabled." : "macOS notification sound is off; Cell’s alarm can still play when Play sound is on.")
                            .font(.system(size: 11)).foregroundStyle(notifications.soundsAllowed ? Palette.muted : Palette.amber)
                    }
                    if let error = notifications.failure { Text(error).font(.caption).foregroundStyle(Palette.amber) }
                }
                Spacer()
                VStack(spacing: 8) {
                    Button("Notification settings") { notifications.openSettings() }.buttonStyle(.bordered)
                    if notifications.authorization == .notDetermined {
                        Button("Enable notifications") { Task { await notifications.request() } }.buttonStyle(.borderedProminent)
                    } else if notifications.authorization != .denied {
                        Button("Test notification") { Task { await notifications.test(sound: monitor.sound) } }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}
