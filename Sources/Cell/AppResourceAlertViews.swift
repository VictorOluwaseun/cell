import SwiftUI
import AppKit
import UserNotifications
import BatteryCore

struct AppResourceAlertSettingsView: View {
    @ObservedObject var controller: AppResourceAlertController
    @ObservedObject var notifications: NotificationService
    var body: some View {
        Panel("App resource alerts", subtitle: "Choose which app warnings to receive. Requires App activity and Cell to remain running.") {
            if !controller.monitoringEnabled {
                Text("App monitoring is paused. Turn on Settings → App activity to receive these alerts; your choices are kept.")
                    .font(.system(size: 12)).foregroundStyle(Palette.amber)
            }
            VStack(spacing: 14) {
                resource(.cpu, detail: "100% represents one CPU core; apps using several cores can exceed it.",
                         enabled: \.cpuEnabled, threshold: \.cpuThreshold, range: 10...6_400, step: 5)
                resource(.memory, detail: "The combined memory footprint of the app and its readable helper processes.",
                         enabled: \.memoryEnabled, threshold: \.memoryGiB, range: 0.25...1_024, step: 0.25)
                resource(.power, detail: "Uses measured process energy where available. Missing watts never trigger a power alert.",
                         enabled: \.powerEnabled, threshold: \.powerWatts, range: 0.1...100, step: 0.5)
                Toggle("Power alerts only while running on battery", isOn: binding(\.powerOnlyOnBattery))
                    .toggleStyle(.checkbox).font(.system(size: 12)).disabled(!controller.preferences.powerEnabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 20) {
                    Picker("Sustained for", selection: binding(\.sustainedSeconds)) {
                        ForEach(AppResourceAlertPreferences.durations, id: \.self) { Text(Display.duration($0)).tag($0) }
                    }.frame(maxWidth: 260)
                    Picker("Per-app cooldown", selection: binding(\.cooldownSeconds)) {
                        ForEach(AppResourceAlertPreferences.cooldowns, id: \.self) { Text(Display.duration($0)).tag($0) }
                    }.frame(maxWidth: 300)
                    Spacer(minLength: 0)
                }.font(.system(size: 12)).disabled(!controller.preferences.anyEnabled)
            }.disabled(!controller.monitoringEnabled)
            Text("Checked every 10–30 seconds while awake. Each resource warns once until usage falls below 90% of its limit; the per-app cooldown also applies. Warnings for different apps are spaced at least a minute apart. CPU and memory alerts also work on external power. Process watts do not measure an app’s entire battery impact.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notifications.bannerStatus).font(.system(size: 12))
                    Text("App warnings use macOS notifications and the Alert sound setting. Banners, sounds and Focus are controlled in System Settings.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if let failure = notifications.failure { Text(failure).font(.system(size: 11)).foregroundStyle(Palette.amber) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if notifications.authorization == .notDetermined {
                    Button("Enable notifications") { Task { await notifications.request() } }.buttonStyle(.borderedProminent)
                }
                Button("Notification settings") { notifications.openSettings() }.buttonStyle(.bordered)
            }
        }
        .task { await notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refresh() }
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<AppResourceAlertPreferences, Value>) -> Binding<Value> {
        Binding(get: { controller.preferences[keyPath: key] }, set: { value in
            var copy = controller.preferences; copy[keyPath: key] = value; controller.update(copy)
        })
    }
    private func resource(_ kind: AppResourceKind, detail: String, enabled: WritableKeyPath<AppResourceAlertPreferences, Bool>,
                          threshold: WritableKeyPath<AppResourceAlertPreferences, Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(kind.title) alerts").font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Stepper(value: binding(threshold), in: range, step: step) {
                Text(kind.formatted(controller.preferences[keyPath: threshold])).monospacedDigit()
            }.font(.system(size: 12)).frame(width: 145)
                .accessibilityLabel("\(kind.title) alert threshold").disabled(!controller.preferences[keyPath: enabled])
            Toggle("\(kind.title) alerts", isOn: binding(enabled)).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct AppResourceAlertHistoryView: View {
    @ObservedObject var controller: AppResourceAlertController
    var body: some View {
        if controller.preferences.anyEnabled || !controller.recent.isEmpty {
            Panel("Recent app alerts", subtitle: "Latest 20 warnings from this session. Alerts also appear in Timeline when recording is enabled.") {
                if controller.recent.isEmpty {
                    Text(controller.active ? "No sustained app limits have been reached yet. Configure thresholds in Settings → App resource alerts."
                         : "App resource alerts are paused.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                ForEach(controller.recent) { alert in
                    HStack(alignment: .top, spacing: 12) {
                        AppIcon(path: alert.identity).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(alert.name).font(.system(size: 13, weight: .medium))
                            Text(alert.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(alert.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.padding(.vertical, 6)
                }
                if !controller.recent.isEmpty {
                    Button("Clear this list") { controller.clearRecent() }.buttonStyle(.bordered)
                }
            }
        }
    }
}
