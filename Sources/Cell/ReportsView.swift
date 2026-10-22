import SwiftUI
import Charts
import BatteryCore

struct ReportsView: View {
    @ObservedObject var controller: InsightsController
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Picker("Report period", selection: $controller.reportWeeksAgo) {
                    Text("Past 7 days").tag(0)
                    ForEach(1...11, id: \.self) { Text("Ending \($0) week\($0 == 1 ? "" : "s") ago").tag($0) }
                }.frame(width: 270)
                Spacer()
                if controller.loading { ProgressView().controlSize(.small) }
                Button { controller.exportReport() } label: { Label("Export report", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered).disabled(controller.dashboard.report == nil)
            }
            if let report = controller.dashboard.report {
                Panel("Your week in battery use", subtitle: "\(report.start.formatted(date: .abbreviated, time: .omitted)) – \(report.end.formatted(date: .abbreviated, time: .omitted))") {
                    Text("\(Display.duration(report.current.observedSeconds)) of continuous readings recorded. Reports compare recorded coverage, so a shorter observation period can change totals.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    if report.current.observedSeconds == 0 {
                        EmptyMessage(icon: "doc.text", title: "No readings for this report yet", detail: "Reports fill in from actual observations. Choose a more recent period or leave Cell running.")
                    } else if !report.days.isEmpty {
                        Chart(report.days) { day in
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Energy", day.dischargedWh))
                                .foregroundStyle(by: .value("Flow", "Discharged")).position(by: .value("Flow", "Discharged"))
                            BarMark(x: .value("Day", day.day, unit: .day), y: .value("Energy", day.chargedWh))
                                .foregroundStyle(by: .value("Flow", "Charged")).position(by: .value("Flow", "Charged"))
                        }.chartForegroundStyleScale(["Discharged": Palette.violet, "Charged": Palette.mint])
                            .chartXScale(domain: reportChartDomain(report))
                            .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated).day()) } }
                            .chartYAxisLabel("Recorded energy (Wh)").frame(height: 210)
                            .accessibilityLabel("Daily recorded energy charged and discharged")
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    MetricTile(icon: "battery.75percent", title: "Battery runtime", value: Display.duration(report.current.batterySeconds), detail: "Recorded time on battery")
                    MetricTile(icon: "bolt", title: "Energy used", value: Display.number(report.current.measuredBatterySeconds > 0 ? report.current.dischargedWh : nil, digits: 2, unit: " Wh"), detail: "Battery discharge only", tint: Palette.amber)
                    MetricTile(icon: "waveform.path", title: "Average drain", value: Display.number(report.current.averageDrainWatts, digits: 2, unit: " W"), detail: "Measured battery intervals", tint: Palette.blue)
                    MetricTile(icon: "arrow.up.arrow.down", title: "Drain change", value: Display.number(report.observedDrainChange, digits: 1, unit: "%"), detail: "Vs. preceding 7 days; needs 30m each")
                    if controller.features.recordsSleep {
                        MetricTile(icon: "moon", title: "Sleep sessions", value: String(report.sleeps.count), detail: "Observed sleep/wake comparisons", tint: Palette.blue)
                    }
                    if controller.features.recordsHealth {
                        MetricTile(icon: "heart", title: "Health change", value: Display.number(report.healthChange, digits: 2, unit: " pt"), detail: "Daily capacity estimate; needs 2 days", tint: Palette.mint)
                    }
                }
                if controller.features.recordsAppEnergy {
                    Panel("Apps in this report", subtitle: "Reported process energy is separate from total battery energy.") {
                        AppEnergyList(totals: Array(report.apps.prefix(10)))
                    }
                }
            }
            Panel("Weekly reminders") {
                Text(controller.weeklyNotifications ? "Weekly report notifications are enabled." : "Weekly report notifications are off.").font(.system(size: 13))
                Text("Manage notifications in Settings. Reminders arrive at most once per ISO calendar week while Cell is running, after at least 30 minutes of recorded coverage. Notification permission and macOS Focus settings apply.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }.task { await controller.reload() }
    }
    private func reportChartDomain(_ report: WeeklyReport) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: report.start)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: report.end))!
        return start...end
    }
}
