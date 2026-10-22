import SwiftUI
import ServiceManagement

struct PreferencesView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false
    var body: some View {
        VStack(spacing: 20) {
            Panel("Monitoring") {
                setting("Battery refresh interval", detail: "macOS may update hardware sensors less often than Cell samples them.") {
                    Picker("Battery refresh interval", selection: $monitor.interval) {
                        Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
                        Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0)
                    }.labelsHidden().frame(width: 130)
                }
                Divider().overlay(Palette.line)
                setting("App activity", detail: "Sample every 10 seconds while active and every 30 seconds in the background; save hourly energy aggregates.") {
                    Toggle("App activity", isOn: $monitor.appMonitoring).labelsHidden().toggleStyle(.switch)
                }
                setting("Menu bar percentage", detail: "See your battery level without opening the dashboard.") {
                    Toggle("Menu bar percentage", isOn: $monitor.showPercentage).labelsHidden().toggleStyle(.switch)
                }
            }
            Panel("Reminders & startup") {
                setting("Alert sound", detail: "Enable sound for Cell alarms and macOS notifications. Choose the alarm tone, volume and ringing duration in Charge alerts.") {
                    Toggle("Alert sound", isOn: $monitor.sound).labelsHidden().toggleStyle(.switch)
                }
                setting("Open at login", detail: "Start Cell when you sign in to your Mac.") {
                    Toggle("Open at login", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, enabled in updateLogin(enabled) }
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Allow Cell in Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.bordered)
                }
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(Palette.amber) }
            }
            Panel("Your data", subtitle: "No accounts, analytics, or network connections.") {
                setting("Local history", detail: "90 days of battery, app, sleep and timeline history; up to 2 years of daily health readings. Older records are removed automatically.") {
                    Button("Export CSV…") { monitor.exportHistory() }.buttonStyle(.bordered).disabled(monitor.history.isEmpty)
                }
                setting("Clear recorded history", detail: "Remove battery readings, app energy, sleep comparisons, timeline and health history. Profiles and reminders stay saved.") {
                    Button("Clear history…", role: .destructive) { confirmClear = true }.buttonStyle(.bordered)
                }
            }
            Panel("Cell \(Bundle.main.object(forInfoDictionaryKey: "CellReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")") {
                HStack(spacing: 35) {
                    VStack(alignment: .leading, spacing: 14) {
                        DetailRow(title: "Thermal pressure", value: monitor.thermal)
                        DetailRow(title: "Low Power Mode", value: monitor.lowPower ? "Enabled" : "Disabled")
                    }
                    Text("Built with native macOS frameworks. Some battery fields depend on your Mac model and OS version; unavailable values appear as a dash.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: 340).lineSpacing(4)
                }
            }
        }
        .confirmationDialog("Clear all battery history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { Task { await monitor.clearHistory() } }
        } message: { Text("This permanently deletes battery, app energy, sleep, timeline and health records stored by Cell on this Mac.") }
    }
    private func setting<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 25) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control()
        }.padding(.vertical, 4)
    }
    private func updateLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
