import AppKit
import SwiftUI
import BatteryCore
import CPlatform
import Security

@main
struct CellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = BatteryMonitor()
    init() {
        if CommandLine.arguments.contains("--validate-charge-installer") {
            for name in ["install-charge-helper", "remove-charge-helper"] {
                guard let url = Bundle.main.url(forResource: name, withExtension: "sh"),
                      let script = NSAppleScript(source: ChargeLimitController.installerSource(url)) else {
                    print("Missing charging installer."); Foundation.exit(1)
                }
                var error: NSDictionary?
                guard script.compileAndReturnError(&error) else {
                    print("Installer authorization script is invalid: \(error?.description ?? "unknown error")"); Foundation.exit(1)
                }
            }
            guard let requirementURL = Bundle.main.url(forResource: "helper-requirement", withExtension: "txt"),
                  let requirementString = try? String(contentsOf: requirementURL, encoding: .utf8) else {
                print("Missing helper signing requirement."); Foundation.exit(1)
            }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(requirementString.trimmingCharacters(in: .whitespacesAndNewlines) as CFString,
                                                [], &requirement) == errSecSuccess else {
                print("Invalid helper signing requirement."); Foundation.exit(1)
            }
            print("Charging installer authorization scripts and signing requirement are valid. Nothing was installed or executed.")
            Foundation.exit(0)
        }
        if CommandLine.arguments.contains("--diagnostics") {
            let reading = BatteryReader().read()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(reading) { print(String(decoding: data, as: UTF8.self)) }
            var processes = [CellProcess](repeating: CellProcess(), count: 16_384)
            let count = cell_read_processes(&processes, Int32(processes.count))
            print("Readable user processes: \(count)")
            Foundation.exit(reading.state == .unavailable ? 2 : 0)
        }
    }
    var body: some Scene {
        Window("Cell", id: "main") {
            DashboardView(monitor: monitor)
                .preferredColorScheme(.dark)
                .onAppear { delegate.monitor = monitor }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 830)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Battery") {
                Button("Refresh readings") { Task { await monitor.refresh() } }.keyboardShortcut("r")
                Button("Export selected history…") { monitor.exportHistory() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        Settings {
            ScrollView { PreferencesView(monitor: monitor).padding(28) }
                .frame(width: 900, height: 720)
                .background(Palette.background).foregroundStyle(Palette.text).tint(Palette.violet)
                .preferredColorScheme(.dark)
        }
        MenuBarExtra(isInserted: Binding(get: { monitor.features[.menuBar] }, set: { visible in
            guard monitor.features[.menuBar] != visible else { return }
            monitor.features[.menuBar] = visible
        })) {
            MenuBarContent(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                BatteryLevelIcon(level: monitor.snapshot.level, charging: monitor.snapshot.state == .charging,
                                 available: monitor.snapshot.state != .unavailable)
                if monitor.showPercentage {
                    Text(monitor.snapshot.state == .unavailable ? "—" : "\(Int(monitor.snapshot.level.rounded()))%")
                }
            }
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var monitor: BatteryMonitor?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.title == "Cell" }?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { monitor?.shutdown() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor else { return .terminateNow }
        Task { await monitor.prepareForTermination(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct MenuBarContent: View {
    @ObservedObject var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Cell", systemImage: "bolt.fill").font(.headline)
                Spacer()
                Text(monitor.snapshot.state.title).font(.caption).foregroundStyle(Palette.mint)
            }
            HStack(alignment: .firstTextBaseline) {
                BatteryLevelIcon(level: monitor.snapshot.level, charging: monitor.snapshot.state == .charging,
                                 available: monitor.snapshot.state != .unavailable)
                Text(monitor.snapshot.state == .unavailable ? "—" : "\(Int(monitor.snapshot.level.rounded()))%")
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                Spacer()
                Text(Display.number(monitor.snapshot.batteryWatts.map(abs), digits: 2, unit: " W"))
                    .foregroundStyle(Palette.muted)
            }
            DetailRow(title: "Health", value: Display.number(monitor.snapshot.health, digits: 0, unit: "%"))
            DetailRow(title: "Charge cycles", value: monitor.snapshot.cycleCount.map(String.init) ?? "—")
            MenuBarLimitControls(controller: monitor.chargeLimit)
            ActiveReminderAlarmControls(controller: monitor.notifications.alarm)
            MenuBarForecast(controller: monitor.insights)
            Divider()
            Button("Open dashboard") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                .buttonStyle(.borderedProminent).tint(Palette.violet).frame(maxWidth: .infinity)
            Button("Quit Cell") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Palette.muted)
        }.padding(22).frame(width: 300).background(Palette.background).preferredColorScheme(.dark)
    }
}

struct MenuBarForecast: View {
    @ObservedObject var controller: InsightsController
    var body: some View {
        if let forecast = controller.forecast {
            DetailRow(title: "Recent-use forecast", value: Display.duration(forecast.hours * 3_600), color: Palette.violet)
        }
    }
}

struct MenuBarLimitControls: View {
    @ObservedObject var controller: ChargeLimitController
    var body: some View {
        if let status = controller.status, status.configuration.enabled {
            DetailRow(title: "Charging limit", value: "\(status.configuration.percentage)%", color: Palette.violet)
            Text(controller.title).font(.caption).foregroundStyle(Palette.muted)
            Button("Charge to full this time") { Task { await controller.chargeToFull() } }
                .buttonStyle(.bordered).disabled(controller.busy || !status.onAC || status.override)
        }
    }
}
