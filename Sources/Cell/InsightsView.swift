import SwiftUI
import Charts
import BatteryCore

struct InsightsView: View {
    @ObservedObject var controller: InsightsController
    var body: some View {
        VStack(spacing: 20) {
            InsightsRangeControl(controller: controller)
            RuntimeForecastPanel(controller: controller)
            sleepPanel
            healthPanel
            Panel("Unusual-drain detection") {
                if let baseline = controller.dashboard.baseline {
                    DetailRow(title: "Recorded baseline", value: Display.number(baseline.watts, digits: 2, unit: " W"), color: Palette.violet)
                    DetailRow(title: "Baseline coverage", value: Display.duration(baseline.seconds))
                } else {
                    Text("Cell needs at least 30 minutes of recorded battery use, excluding the most recent 15 minutes, to establish a baseline.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Toggle("Notify me about sustained unusual drain", isOn: $controller.drainAlerts).toggleStyle(.switch).font(.system(size: 13))
                Text("An alert requires 5 continuous minutes above both twice your median drain and 5 W above it, with an 8 W minimum. Alerts have a 2-hour cooldown. Workload changes can explain higher drain; this is a comparison, not a diagnosis.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }.task { await controller.reload() }
    }
    private var sleepPanel: some View {
        Panel("Sleep drain", subtitle: "Compare the last reading before sleep with the first reading after wake.") {
            if controller.dashboard.sleep.isEmpty {
                EmptyMessage(icon: "moon.zzz", title: "Your next sleep will tell a story",
                    detail: "Leave Cell running before your Mac sleeps. A comparison appears after it wakes. Activity during sleep cannot be attributed to apps.")
            } else {
                let chartData = Array(controller.dashboard.sleep.filter { $0.batteryOnly && $0.recoveredAfterRestart != true && $0.drop != nil }.prefix(14).reversed())
                if !chartData.isEmpty {
                    Chart(chartData) { session in
                        BarMark(x: .value("Wake", session.after!.date), y: .value("Percentage points", session.drop!), width: .fixed(12))
                            .foregroundStyle(session.unusual ? Palette.amber : Palette.violet).cornerRadius(3)
                    }.frame(height: 145).chartYAxisLabel("Charge lost (%)")
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour()) } }
                        .accessibilityLabel("Observed charge changes across sleep sessions")
                }
                ForEach(Array(controller.dashboard.sleep.prefix(15))) { session in
                    HStack(alignment: .top) {
                        Image(systemName: session.unusual ? "exclamationmark.circle" : "moon").foregroundStyle(session.unusual ? Palette.amber : Palette.violet)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.before.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium))
                            Text("\(Display.duration(session.duration)) between readings • \(session.recoveredAfterRestart == true ? "recovered after restart; wake time unknown" : (session.batteryOnly ? "battery at both ends" : "external power at an endpoint"))")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("\(Int(session.before.level))% → \(Int(session.after?.level ?? session.before.level))%")
                                .font(.system(size: 13)).monospacedDigit()
                            Text(session.drainPerHour.map { Display.number($0, digits: 2, unit: "%/h") } ?? "Comparable rate unavailable")
                                .font(.system(size: 10)).foregroundStyle(session.unusual ? Palette.amber : Palette.muted)
                        }
                    }.padding(.vertical, 7)
                }
                Text("Amber marks more than 1% loss per hour over at least an hour. Endpoints do not prove the Mac stayed on battery throughout sleep. Readings can also shift after calibration.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }
    }
    private var healthPanel: some View {
        Panel("Battery health over time", subtitle: "One daily capacity reading, retained for up to two years.") {
            if controller.dashboard.health.isEmpty {
                EmptyMessage(icon: "heart", title: "Waiting for a capacity reading", detail: "Health history starts when your Mac reports a full-charge and design capacity.")
            } else {
                Chart(controller.dashboard.health) { reading in
                    LineMark(x: .value("Day", reading.day), y: .value("Capacity health", reading.health)).foregroundStyle(Palette.mint)
                    PointMark(x: .value("Day", reading.day), y: .value("Capacity health", reading.health)).foregroundStyle(Palette.mint).symbolSize(15)
                }.chartYScale(domain: healthDomain).frame(height: 180).chartYAxisLabel("Capacity (%)")
                    .accessibilityLabel("Daily full-charge capacity relative to design capacity")
                HStack(spacing: 25) {
                    DetailRow(title: "Health change", value: healthChange)
                    DetailRow(title: "Cycles added", value: cycleChange)
                }
                Text("Daily capacity estimates fluctuate with temperature and battery calibration. This chart does not predict a replacement date. \(controller.dashboard.health.count) daily readings recorded.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }
    }
    private var healthDomain: ClosedRange<Double> {
        max(0, min(70, (controller.dashboard.health.map(\.health).min() ?? 70) - 3))...100
    }
    private var healthChange: String {
        let values = controller.dashboard.health
        guard values.count >= 2 else { return "Needs 2 days" }
        return Display.number(values.last!.health - values.first!.health, digits: 2, unit: " points")
    }
    private var cycleChange: String {
        let values = controller.dashboard.health
        guard values.count >= 2, let a = values.first?.cycles, let b = values.last?.cycles, b >= a else { return "—" }
        return String(b - a)
    }
}

struct InsightsRangeControl: View {
    @ObservedObject var controller: InsightsController
    var body: some View {
        HStack {
            Text("Recorded data only; gaps remain visible.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            if controller.loading { ProgressView().controlSize(.small) }
            Picker("Insight period", selection: $controller.range) {
                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 130)
            Button { Task { await controller.flushUsage(); await controller.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered).help("Refresh recorded insights").accessibilityLabel("Refresh insights")
        }
    }
}

struct RuntimeForecastPanel: View {
    @ObservedObject var controller: InsightsController
    var body: some View {
        Panel("Runtime forecast", subtitle: "Based on your recent battery use, with a range for uncertainty.") {
            if let forecast = controller.forecast {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    Text(Display.duration(forecast.hours * 3_600)).font(.system(size: 30, weight: .medium, design: .rounded)).foregroundStyle(Palette.violet)
                    Text("Estimated range \(Display.duration(forecast.lowerHours * 3_600)) – \(Display.duration(forecast.upperHours * 3_600))")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    Spacer()
                }
                Text("\(Display.duration(forecast.observedSeconds)) of recent use. Changing your workload, brightness or connected devices can change runtime. This is not a guaranteed remaining time.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            } else {
                Text("A forecast appears after 3 continuous minutes on battery with usable current readings. Connect/disconnect events and sleep restart the observation window.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
        }
    }
}

struct ChargingExplanationPanel: View {
    @ObservedObject var controller: ChargeLimitController
    var battery: BatterySnapshot
    private var explanation: ChargingExplanation { .make(battery, helper: controller.status, helperError: controller.installed ? controller.error : nil) }
    var body: some View {
        Panel("Charging explained") {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: explanation.symbol).font(.system(size: 22)).foregroundStyle(Palette.blue)
                VStack(alignment: .leading, spacing: 7) {
                    Text(explanation.title).font(.system(size: 14, weight: .medium))
                    Text(explanation.detail).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
            }
        }
    }
}

struct InsightsErrorBanner: View {
    @ObservedObject var controller: InsightsController
    var body: some View {
        if let error = controller.error ?? controller.drainWarning {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                Spacer()
                Button { controller.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss insight error")
            }.foregroundStyle(Palette.amber).padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
