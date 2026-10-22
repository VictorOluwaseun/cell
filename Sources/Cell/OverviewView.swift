import SwiftUI
import BatteryCore

struct OverviewView: View {
    @ObservedObject var monitor: BatteryMonitor
    var showActivity: () -> Void
    private var battery: BatterySnapshot { monitor.snapshot }
    var body: some View {
        VStack(spacing: 20) {
            ChargeLimitSummary(controller: monitor.chargeLimit)
            hero
            HStack(spacing: 14) {
                MetricTile(icon: "heart", title: "Battery health", value: Display.number(battery.health, digits: 0, unit: "%"),
                           detail: "Capacity vs. original design", tint: Palette.mint)
                MetricTile(icon: "arrow.triangle.2.circlepath", title: "Charge cycles", value: battery.cycleCount.map(String.init) ?? "—",
                           detail: "Lifetime count from your battery", tint: Palette.blue)
                MetricTile(icon: "waveform.path", title: "Battery flow", value: Display.number(battery.batteryWatts.map(abs), digits: 2, unit: " W"),
                           detail: battery.state == .charging ? "Power flowing into the battery" : "Net battery power, not total system", tint: Palette.violet)
                MetricTile(icon: "thermometer.medium", title: "Temperature", value: Display.number(battery.temperature, unit: "°C"),
                           detail: "Battery sensor reading", tint: Palette.amber)
            }
            RuntimeForecastPanel(controller: monitor.insights)
            ChargingExplanationPanel(controller: monitor.chargeLimit, battery: battery)
            HistoryChartView(monitor: monitor, compact: true)
            HStack(alignment: .top, spacing: 18) {
                Panel("Live electrical readings", subtitle: "Precision beyond the percentage") {
                    VStack(spacing: 15) {
                        DetailRow(title: "Instantaneous change", value: Display.number(battery.instantaneousRate, digits: 3, unit: "%/h"), color: Palette.violet)
                        DetailRow(title: "C-rate", value: Display.number(battery.cRate, digits: 4, unit: " C"))
                        DetailRow(title: "Current", value: Display.number(battery.currentMA, digits: 0, unit: " mA"))
                        DetailRow(title: "Voltage", value: Display.number(battery.voltage, digits: 3, unit: " V"))
                        DetailRow(title: "15-minute trend", value: Display.number(monitor.trend, digits: 2, unit: "%/h"))
                    }
                    Text("Positive current means charging. Sensor precision and refresh rate depend on your Mac.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Panel {
                    HStack {
                        Text("Power activity").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("View all", action: showActivity).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.violet)
                    }
                    if !monitor.appMonitoring {
                        EmptyMessage(icon: "pause.circle", title: "App monitoring is off", detail: "Enable it in Settings to see activity.")
                    } else if monitor.apps.isEmpty {
                        EmptyMessage(icon: "waveform.path", title: "Measuring app activity", detail: "The first comparison takes about 10 seconds while this window is active.")
                    } else {
                        VStack(spacing: 15) {
                            ForEach(Array(monitor.apps.prefix(4))) { app in AppActivityRow(app: app, compact: true) }
                        }
                        Text(monitor.apps.contains { $0.watts != nil } ? "Process energy reported by macOS." : "CPU activity is a power-use proxy; watts are unavailable.")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }
    private var hero: some View {
        Panel {
            HStack(spacing: 32) {
                BatteryGauge(level: battery.level, available: battery.state != .unavailable, charging: battery.state == .charging)
                    .frame(width: 170, height: 170)
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 6) {
                        BatteryLevelIcon(level: battery.level, charging: battery.state == .charging,
                                         available: battery.state != .unavailable)
                        Text(battery.state.title)
                    }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.mint)
                    Text(statusHeadline).font(.system(size: 25, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(statusDetail).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let minutes = battery.minutesRemaining {
                        Label("About \(Display.duration(Double(minutes * 60))) \(battery.state == .charging ? "until full" : "remaining")", systemImage: "clock")
                            .font(.system(size: 11)).foregroundStyle(Palette.violet)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Palette.line).frame(width: 1, height: 105)
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(battery.state.onAC ? "Adapter rating" : "Battery discharge").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(Display.number(battery.state.onAC ? battery.adapterWatts : battery.batteryWatts.map(abs), digits: battery.state.onAC ? 0 : 2, unit: " W"))
                            .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(battery.state.onAC ? "System input" : "Power mode").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(battery.state.onAC ? Display.number(battery.systemWatts, digits: 2, unit: " W") : (monitor.lowPower ? "Low Power" : "Standard"))
                            .font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                }.frame(width: 145, alignment: .leading)
            }.padding(.vertical, 3)
        }
    }
    private var statusHeadline: String {
        switch battery.state {
        case .charging: "A little more energy."
        case .discharging: "Ready to go unplugged."
        case .pluggedIn: "Powered by your adapter."
        case .full: "All charged up."
        case .unavailable: "Let’s find your battery."
        }
    }
    private var statusDetail: String {
        switch battery.state {
        case .charging: "Your Mac is connected and the battery is charging."
        case .discharging: "Your battery is powering your Mac. Keep an eye on the activity below."
        case .pluggedIn: "Your Mac is connected. macOS or a charge limit may be holding the battery at this level."
        case .full: "Your battery is full and your Mac is connected to external power."
        case .unavailable: "Live readings will appear when an internal battery is available."
        }
    }
}

struct BatteryGauge: View {
    var level: Double
    var available: Bool
    var charging: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Palette.line, lineWidth: 10)
            Circle().trim(from: 0, to: available ? min(1, max(0, level / 100)) : 0)
                .stroke(AngularGradient(colors: [Palette.violet, Palette.blue, Palette.mint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 7) {
                BatteryLevelIcon(level: level, charging: charging, available: available).foregroundStyle(Palette.mint)
                Text(available ? "\(Int(level.rounded()))%" : "—").font(.system(size: 40, weight: .medium, design: .rounded)).monospacedDigit()
                Text("Battery level").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(8).accessibilityElement(children: .ignore)
            .accessibilityLabel(available ? "Battery level \(Int(level)) percent" : "Battery unavailable")
    }
}
