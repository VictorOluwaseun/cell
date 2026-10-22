import AppKit
import SwiftUI
import BatteryCore

struct AppEnergyHistoryView: View {
    @ObservedObject var controller: InsightsController
    @State private var search = ""
    @State private var sortCPU = false
    private var totals: [AppEnergyTotal] {
        controller.dashboard.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted {
            sortCPU ? $0.cpuSeconds > $1.cpuSeconds : ($0.wattHours == $1.wattHours ? $0.cpuSeconds > $1.cpuSeconds : $0.wattHours > $1.wattHours)
        }
    }
    var body: some View {
        VStack(spacing: 20) {
            InsightsRangeControl(controller: controller)
            Panel("Recorded app energy", subtitle: "Hourly aggregates of readable process counters; boundary hours may be included.") {
                HStack {
                    TextField("Search recorded apps and processes", text: $search).textFieldStyle(.roundedBorder)
                    Picker("Rank by", selection: $sortCPU) { Text("Energy").tag(false); Text("CPU time").tag(true) }.frame(width: 160)
                    Button("Export CSV") { export() }.buttonStyle(.bordered).disabled(totals.isEmpty)
                }
                AppEnergyList(totals: totals)
                Text("Up to 64 active readable processes are considered per interval, balancing energy and CPU activity, with at most 128 identities retained per hour for 90 days. Sampling takes 10–30 seconds while active and 30 seconds in the background. Unknown watts stay unavailable; CPU minutes represent core time, not energy. App, GPU and device attribution can be incomplete.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }.task { await controller.flushUsage(); await controller.reload() }
    }
    private func export() {
        let values = totals
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Cell-app-energy.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try AppEnergyCSV.encode(values).write(to: url, atomically: true, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

struct AppEnergyList: View {
    var totals: [AppEnergyTotal]
    var body: some View {
        if totals.isEmpty {
            EmptyMessage(icon: "chart.bar", title: "No app intervals recorded here", detail: "App monitoring must be enabled. The first counter comparison takes 10–30 seconds; recording starts from that point.")
        } else {
            HStack {
                Text("Application"); Spacer()
                Text("CPU minutes").frame(width: 95, alignment: .trailing)
                Text("Coverage").frame(width: 85, alignment: .trailing)
                Text("Reported energy").frame(width: 115, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            LazyVStack(spacing: 0) {
                ForEach(totals) { app in
                    HStack(spacing: 10) {
                        AppIcon(path: app.bundlePath).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(app.measuredSeconds > 0 ? "\(Display.number(app.averageWatts, digits: 3, unit: " W")) while measured" : "CPU activity only; watts unavailable")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Text(Display.number(app.cpuSeconds / 60, digits: 1)).frame(width: 95, alignment: .trailing)
                        Text(Display.duration(app.observedSeconds)).frame(width: 85, alignment: .trailing)
                        Text(Display.number(app.measuredSeconds > 0 ? app.wattHours : nil, digits: 3, unit: " Wh"))
                            .foregroundStyle(Palette.violet).frame(width: 115, alignment: .trailing)
                    }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.5)).frame(height: 1) }
                }
            }
        }
    }
}
