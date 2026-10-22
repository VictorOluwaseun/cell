import SwiftUI
import BatteryCore

struct PreferenceToggle: View {
    var title: String
    var detail: String
    @Binding var enabled: Bool
    var body: some View {
        HStack(spacing: 25) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $enabled).labelsHidden().toggleStyle(.switch)
        }.padding(.vertical, 4)
    }
}

struct InsightPreferencesView: View {
    @ObservedObject var controller: InsightsController
    @ObservedObject var monitor: BatteryMonitor
    var body: some View {
        Panel("Insights & profiles") {
            PreferenceToggle(title: "Runtime forecasts", detail: "Estimate time remaining from recent battery use. Turning this off stops forecast calculations.",
                enabled: binding(.runtimeForecast))
            PreferenceToggle(title: "Unusual-drain alerts", detail: "Compare sustained battery use with your recorded baseline. Requires battery history and macOS notification permission for banners.",
                enabled: $controller.drainAlerts).disabled(!monitor.features[.batteryHistory])
            PreferenceToggle(title: "Weekly report notifications", detail: "Notify at most once a week while Cell is running. Requires weekly reports and macOS notification permission.",
                enabled: $controller.weeklyNotifications).disabled(!monitor.features.generatesReports)
            PreferenceToggle(title: "Charging profiles", detail: "Show saved Desk, Travel and custom profiles. Turning this off keeps the current charging limit and saved profiles.",
                enabled: binding(.chargingProfiles))
        }
    }
    private func binding(_ feature: CellFeature) -> Binding<Bool> {
        Binding(get: { monitor.features[feature] }, set: { monitor.features[feature] = $0 })
    }
}

/// Hardware state is the source of truth: a failed request must never look like a disabled limit.
struct ChargingPreferencesView: View {
    @ObservedObject var controller: ChargeLimitController
    @State private var target = 80.0
    private var needsRelease: Bool { controller.enabled || controller.status?.held == true }
    var body: some View {
        Panel("Automatic charging limit", subtitle: "Requires the optional charging helper. Install or remove it from the Charging limit page.") {
            PreferenceToggle(title: "Limit battery charging", detail: controller.title,
                enabled: Binding(get: { needsRelease }, set: { enabled in
                    Task { await controller.configure(percentage: Int(target), enabled: enabled) }
                }))
                .disabled(controller.busy || controller.status == nil || (!needsRelease && controller.status?.supported != true))
            HStack(spacing: 18) {
                Text("Target").font(.system(size: 12))
                Slider(value: $target, in: 20...100, step: 1).accessibilityLabel("Settings charging target")
                Text("\(Int(target))%").font(.system(size: 16)).monospacedDigit().frame(width: 45)
                if controller.enabled {
                    Button("Apply target") { Task { await controller.configure(percentage: Int(target), enabled: true) } }
                        .buttonStyle(.bordered).disabled(Int(target) == controller.status?.configuration.percentage)
                }
                if controller.busy { ProgressView().controlSize(.small) }
            }.disabled(controller.busy || controller.status == nil)
            Text("Turning this off asks the helper to release Cell’s charging pause. An enabled limit stays active after Cell quits. Other macOS charging rules may still hold charging.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber)
            }
        }
        .task { await controller.refresh(force: true); syncTarget() }
        .onChange(of: controller.status?.configuration) { _, _ in syncTarget() }
    }
    private func syncTarget() { target = Double(controller.status?.configuration.percentage ?? 80) }
}
