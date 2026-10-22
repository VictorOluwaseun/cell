import AppKit
import SwiftUI
import BatteryCore

struct ChargeLimitView: View {
    @ObservedObject var controller: ChargeLimitController
    @State private var target = 80.0
    @State private var confirmRemoval = false
    var body: some View {
        VStack(spacing: 20) {
            Panel {
                HStack(spacing: 20) {
                    Image(systemName: controller.status?.held == true ? "pause.circle.fill" : "battery.100percent.bolt")
                        .font(.system(size: 33)).foregroundStyle(Palette.mint).frame(width: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.title).font(.system(size: 20, weight: .medium))
                        Text(statusDetail).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                    Spacer()
                    if let configuration = controller.status?.configuration, configuration.enabled {
                        Text("\(configuration.percentage)%").font(.system(size: 40, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    if controller.busy { ProgressView().controlSize(.small) }
                }
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                        .foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
            Group {
                Panel("Set your charging limit", subtitle: "Pause charging at your target. Resume 3 percentage points below it.") {
                    HStack(spacing: 20) {
                        Slider(value: $target, in: 20...100, step: 1).accessibilityLabel("Charging limit percentage")
                        Stepper(value: $target, in: 20...100, step: 1) {
                            Text("\(Int(target))%").font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 65)
                        }.fixedSize()
                    }
                    HStack(spacing: 10) {
                        ForEach([60, 70, 80, 90, 100], id: \.self) { value in
                            Button("\(value)%") { target = Double(value) }.buttonStyle(.bordered)
                                .tint(Int(target) == value ? Palette.violet : Palette.muted)
                        }
                        Spacer()
                        Button(controller.enabled ? "Apply limit" : "Enable limit") {
                            Task { await controller.configure(percentage: Int(target), enabled: true) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(controller.busy || controller.status?.supported != true)
                    }
                    Text("If your battery is already above the target, Cell pauses further charging. It does not force the battery to discharge.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                }
                if let status = controller.status, status.configuration.enabled {
                    Panel("Need a full battery?") {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Charge to full this time").font(.system(size: 14, weight: .medium))
                                Text("Bypass Cell’s limit until the charger is disconnected. Other macOS charging settings still apply.")
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(3)
                            }
                            Spacer()
                            Button("Charge to full") { Task { await controller.chargeToFull() } }
                                .buttonStyle(.bordered).disabled(controller.busy || !status.onAC || status.override)
                        }
                        HStack {
                            Text("Turn off Cell’s limit and release its charging pause.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Disable limit") { Task { await controller.configure(percentage: Int(target), enabled: false) } }
                                .buttonStyle(.bordered).disabled(controller.busy)
                        }
                    }
                }
            }
            Panel("Charging helper", subtitle: "One administrator approval to control charging on this Mac.") {
                Text("The helper runs independently of Cell, including after you close or quit the app. It checks the battery every 5 seconds while awake. During sleep, Cell’s helper pauses charging to prevent passing the target, then checks the level again on wake.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                HStack {
                    if controller.installed {
                        Button("Reinstall helper…") { Task { await controller.install() } }.buttonStyle(.bordered).disabled(controller.busy)
                        Button("Remove helper…", role: .destructive) { confirmRemoval = true }
                            .buttonStyle(.bordered).disabled(controller.busy || controller.status == nil)
                        Spacer()
                        Button { Task { await controller.refresh(force: true) } } label: { Label("Check status", systemImage: "arrow.clockwise") }
                            .buttonStyle(.bordered).disabled(controller.busy)
                    } else {
                        Button("Install charging helper…") { Task { await controller.install() } }.buttonStyle(.borderedProminent).disabled(controller.busy)
                        Text("macOS will ask for administrator authorization.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                Text("Use one charge controller at a time. Support depends on your Mac and macOS; Cell reports a hardware error if a change is rejected. Your Mac can remain above the target until the battery naturally drains.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
            Panel("macOS charging settings") {
                HStack(spacing: 20) {
                    Text("Apple silicon Macs with macOS 26.4 or later also offer Apple’s own 80–100% charge limit in Battery settings. Set one controller’s limit at a time to avoid conflicting behavior.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    Spacer()
                    Button("Open Battery settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.bordered)
                }
            }
        }
        .task { await controller.refresh(force: true); target = Double(controller.status?.configuration.percentage ?? 80) }
        .confirmationDialog("Remove the charging helper?", isPresented: $confirmRemoval) {
            Button("Disable limit and remove helper", role: .destructive) { Task { await controller.uninstall() } }
        } message: { Text("Cell will release its charging pause before asking macOS to remove the helper. Administrator authorization is required.") }
    }
    private var statusDetail: String {
        guard let status = controller.status else { return "Install the optional helper, then choose a percentage and enable the limit." }
        if status.override { return "Your saved \(status.configuration.percentage)% limit returns after you unplug the charger." }
        if !status.configuration.enabled { return "Choose a target below, then enable the limit when you’re ready." }
        if status.held { return "Charging will resume at \(status.configuration.percentage - ChargeLimitConfiguration.hysteresis)% or below." }
        return "The helper keeps this limit active even when Cell is closed."
    }
}

struct ChargeLimitSummary: View {
    @ObservedObject var controller: ChargeLimitController
    var body: some View {
        if controller.enabled {
            HStack(spacing: 8) {
                Image(systemName: "battery.100percent.bolt")
                Text(controller.title)
                Spacer()
                if let status = controller.status { Text("\(status.configuration.percentage)% limit").monospacedDigit() }
            }.font(.system(size: 12)).foregroundStyle(controller.error == nil ? Palette.mint : Palette.amber)
                .padding(15).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
