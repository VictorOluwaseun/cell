import SwiftUI
import Charts
import BatteryCore

struct HistoryChartView: View {
    @ObservedObject var monitor: BatteryMonitor
    var compact = false
    @State private var power = false
    @State private var selected: Date?
    private var selection: BatterySnapshot? {
        guard let selected else { return nil }
        return monitor.chart.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }
    var body: some View {
        Panel {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Battery history").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 13) {
                        legend("Battery", color: Palette.violet)
                        legend("Charging", color: Palette.mint)
                        legend("Connected", color: Palette.blue)
                    }
                }
                Spacer()
                if !compact {
                    Picker("Measurement", selection: $power) {
                        Text("Charge").tag(false)
                        Text("Power").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                Picker("History range", selection: $monitor.range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 115)
            }
            if monitor.history.count < 2 {
                EmptyMessage(icon: "chart.xyaxis.line", title: "Your battery story starts here",
                    detail: "Cell records one reading per minute while awake. Your first trend will appear after the next reading.")
                    .frame(height: compact ? 160 : 230)
            } else {
                chart.frame(height: compact ? 155 : 280)
                HStack {
                    if let selection {
                        Text("\(selection.date.formatted(date: .abbreviated, time: .shortened))  •  \(Display.number(power ? selection.batteryWatts : selection.level, digits: power ? 2 : 0, unit: power ? " W" : "%"))")
                    } else { Text(power ? "Positive = charging · Negative = discharging" : "Move across the chart to inspect a reading") }
                    Spacer()
                    Text("\(monitor.history.count.formatted()) readings")
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }
    private var chart: some View {
        Chart {
            ForEach(monitor.chartSegments) { segment in
                ForEach(segment.samples) { sample in
                    if let y = power ? sample.batteryWatts : sample.level {
                        LineMark(x: .value("Time", sample.date), y: .value(power ? "Watts" : "Charge", y), series: .value("Session", segment.id))
                            .foregroundStyle(color(sample.state)).lineStyle(StrokeStyle(lineWidth: 2))
                        if !power {
                            AreaMark(x: .value("Time", sample.date), yStart: .value("Base", 0), yEnd: .value("Charge", y), series: .value("Session", segment.id))
                                .foregroundStyle(LinearGradient(colors: [color(sample.state).opacity(0.15), .clear], startPoint: .top, endPoint: .bottom))
                        }
                        if segment.samples.count == 1 {
                            PointMark(x: .value("Time", sample.date), y: .value("Reading", y)).foregroundStyle(color(sample.state))
                        }
                    }
                }
            }
            if let selection, let y = power ? selection.batteryWatts : selection.level {
                RuleMark(x: .value("Selected time", selection.date)).foregroundStyle(Palette.muted.opacity(0.4))
                PointMark(x: .value("Time", selection.date), y: .value("Reading", y)).foregroundStyle(Palette.text).symbolSize(35)
            }
        }
        .chartYScale(domain: power ? powerDomain : 0...100)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(Palette.line.opacity(0.45))
                AxisValueLabel(format: axisFormat)
                    .foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(dash: [3, 4])).foregroundStyle(Palette.line.opacity(0.7))
                AxisValueLabel { if let n = value.as(Double.self) { Text("\(Int(n))\(power ? " W" : "%")").foregroundStyle(Palette.muted).font(.system(size: 10)) } }
            }
        }
        .chartXSelection(value: $selected)
        .accessibilityLabel(power ? "Battery power history" : "Battery charge history")
    }
    private var powerDomain: ClosedRange<Double> {
        let values = monitor.chart.compactMap(\.batteryWatts)
        return min(-1, (values.min() ?? -1) * 1.15)...max(1, (values.max() ?? 1) * 1.15)
    }
    private var axisFormat: Date.FormatStyle {
        let span = (monitor.history.last?.date ?? .now).timeIntervalSince(monitor.history.first?.date ?? .now)
        if span < 300 { return .dateTime.hour().minute().second() }
        if monitor.range == .hour || monitor.range == .day { return .dateTime.hour().minute() }
        return .dateTime.month(.abbreviated).day()
    }
    private func color(_ state: BatteryState) -> Color {
        switch state { case .charging: Palette.mint; case .discharging: Palette.violet; default: Palette.blue }
    }
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title) }
            .font(.system(size: 10)).foregroundStyle(Palette.muted)
    }
}

struct StatisticsView: View {
    @ObservedObject var monitor: BatteryMonitor
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Recorded while Cell is running. Gaps represent sleep or time away.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Button { monitor.exportHistory() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered).disabled(monitor.history.isEmpty)
            }
            HistoryChartView(monitor: monitor)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                MetricTile(icon: "battery.75percent", title: "On battery", value: Display.duration(monitor.statistics.batterySeconds),
                           detail: "Recorded time in selected range", tint: Palette.violet)
                MetricTile(icon: "bolt", title: "Energy discharged", value: Display.number(monitor.statistics.measuredBatterySeconds > 0 ? monitor.statistics.dischargedWh : nil, digits: 2, unit: " Wh"),
                           detail: "Integrated battery sensor readings", tint: Palette.amber)
                MetricTile(icon: "powerplug", title: "Energy charged", value: Display.number(monitor.statistics.measuredChargeSeconds > 0 ? monitor.statistics.chargedWh : nil, digits: 2, unit: " Wh"),
                           detail: "Energy entering the battery", tint: Palette.mint)
                MetricTile(icon: "waveform.path", title: "Average drain", value: Display.number(monitor.statistics.averageDrainWatts, digits: 2, unit: " W"),
                           detail: "During recorded battery use", tint: Palette.blue)
                MetricTile(icon: "arrow.triangle.2.circlepath", title: "Equivalent cycles", value: Display.number(monitor.statistics.equivalentCycles, digits: 3),
                           detail: "100% total discharge = one cycle", tint: Palette.violet)
                MetricTile(icon: "calendar", title: "Cycle rate", value: Display.number(monitor.statistics.cyclesPerDay, digits: 3, unit: "/day"),
                           detail: "Per recorded day; needs 1 hour", tint: Palette.mint)
            }
            HStack(alignment: .top, spacing: 18) {
                Panel("Battery capacity", subtitle: "Reported by this Mac’s battery controller") {
                    VStack(spacing: 15) {
                        DetailRow(title: "Design capacity", value: Display.number(monitor.snapshot.designCapacity, digits: 0, unit: " mAh"))
                        DetailRow(title: "Full charge capacity", value: Display.number(monitor.snapshot.fullCapacity, digits: 0, unit: " mAh"))
                        DetailRow(title: "Remaining charge", value: Display.number(monitor.snapshot.currentCapacity, digits: 0, unit: " mAh"))
                        DetailRow(title: "Capacity health", value: Display.number(monitor.snapshot.health, unit: "%"), color: Palette.mint)
                        DetailRow(title: "Lifetime hardware cycles", value: monitor.snapshot.cycleCount.map(String.init) ?? "—")
                    }
                }
                Panel("About these statistics") {
                    VStack(alignment: .leading, spacing: 16) {
                        note("Measured, locally", "History is retained for 90 days, with one reading per minute and extra readings when power changes.")
                        note("Coverage matters", "Energy and cycle estimates include continuous recorded intervals only. Sleep and gaps longer than 3 minutes are excluded.")
                        note("Cycles are cumulative", "Equivalent cycles use observed percentage drops. Your battery’s lifetime counter is maintained separately by its controller.")
                    }
                }
            }
        }
    }
    private func note(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(body).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }
}
