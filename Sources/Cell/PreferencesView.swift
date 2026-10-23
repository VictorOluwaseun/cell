import SwiftUI
import BatteryCore

struct PreferencesView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var confirmClear = false
    var body: some View {
        VStack(spacing: 20) {
            StartupSettingsView(controller: monitor.startup)
            Panel("Monitoring") {
                setting("Battery refresh interval", detail: "macOS may update hardware sensors less often than Cell samples them.") {
                    Picker("Battery refresh interval", selection: $monitor.interval) {
                        Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
                        Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0)
                    }.labelsHidden().frame(width: 130)
                }
                Divider().overlay(Palette.line)
                feature("Menu bar icon", detail: "Keep the battery summary in the menu bar. Cell continues running when the dashboard is closed.", .menuBar)
                setting("Menu bar percentage", detail: "See your battery level without opening the dashboard.") {
                    Toggle("Menu bar percentage", isOn: $monitor.showPercentage).labelsHidden().toggleStyle(.switch)
                        .disabled(!monitor.features[.menuBar])
                }
                feature("Detailed electrical readings", detail: "Show current, voltage, C-rate and rate of change on the overview.", .advancedReadings)
                feature("Charging explanations", detail: "Explain the current charging state on the overview.", .chargingExplanation)
            }
            Panel("Activity & history", subtitle: "Turning a feature off pauses its work and hides its views. Saved records and choices are kept; normal retention still applies.") {
                feature("App activity", detail: "Sample process power and CPU use every 10–30 seconds. Turning this off stops process sampling.", .appActivity)
                feature("Battery history & statistics", detail: "Record minute readings for charts, energy statistics and reports. Live battery status stays available when off.", .batteryHistory)
                feature("App energy history", detail: "Save hourly app energy totals. Requires app activity and battery history.", .appEnergyHistory)
                    .disabled(!monitor.features[.appActivity] || !monitor.features[.batteryHistory])
                feature("Sleep drain tracking", detail: "Record battery changes across sleep and wake. Requires battery history.", .sleepTracking)
                    .disabled(!monitor.features[.batteryHistory])
                feature("Battery health history", detail: "Save daily capacity and cycle readings. Requires battery history.", .healthHistory)
                    .disabled(!monitor.features[.batteryHistory])
                feature("Power timeline & charging sessions", detail: "Record power changes, helper events and charging sessions. Requires battery history.", .timeline)
                    .disabled(!monitor.features[.batteryHistory])
                feature("Weekly reports", detail: "Build reports inside Cell from recorded history. Requires battery history.", .reports)
                    .disabled(!monitor.features[.batteryHistory])
            }
            InsightPreferencesView(controller: monitor.insights, monitor: monitor)
            ChargingPreferencesView(controller: monitor.chargeLimit)
            Panel("Charge reminders") {
                feature("Charge reminders", detail: "Check your saved percentage rules. Turning this off stops active alarms and snoozes without deleting your rules.", .chargeAlerts)
                setting("Alert sound", detail: "Enable sound for Cell alarms and macOS notifications. Choose the alarm tone, volume and ringing duration below.") {
                    Toggle("Alert sound", isOn: $monitor.sound).labelsHidden().toggleStyle(.switch)
                }
            }
            ReminderAlarmSettingsView(monitor: monitor, controller: monitor.notifications.alarm)
                .disabled(!monitor.features[.chargeAlerts])
            Panel("Your data", subtitle: "No accounts, analytics, or network connections.") {
                setting("Local history", detail: "When enabled, keep up to 90 days of battery, app, sleep and timeline history, and 2 years of daily health readings.") {
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
    private func feature(_ title: String, detail: String, _ feature: CellFeature) -> some View {
        setting(title, detail: detail) {
            Toggle(title, isOn: Binding(get: { monitor.features[feature] }, set: { monitor.features[feature] = $0 }))
                .labelsHidden().toggleStyle(.switch)
        }
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
}
