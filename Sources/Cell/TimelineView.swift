import SwiftUI
import BatteryCore

struct TimelineView: View {
    @ObservedObject var controller: InsightsController
    @State private var filter = "All events"
    private let filters = ["All events", "Power", "Charge control", "Sleep", "Alerts"]
    private var events: [PowerEvent] {
        controller.dashboard.events.filter { event in
            switch filter {
            case "Power": [.connected, .disconnected, .charging, .paused, .full].contains(event.kind)
            case "Charge control": [.limit, .profile, .override, .paused].contains(event.kind)
            case "Sleep": [.sleep, .wake].contains(event.kind)
            case "Alerts": [.alert, .anomaly].contains(event.kind)
            default: true
            }
        }
    }
    var body: some View {
        VStack(spacing: 20) {
            InsightsRangeControl(controller: controller)
            Panel("Charging sessions", subtitle: "Continuous recorded segments on external power. Gaps over 3 minutes start a new segment.") {
                if controller.dashboard.sessions.isEmpty {
                    EmptyMessage(icon: "powerplug", title: "No recorded charging sessions", detail: "Connect your charger while Cell is running to start a recorded segment.")
                } else {
                    ForEach(Array(controller.dashboard.sessions.prefix(20))) { session in
                        HStack(spacing: 16) {
                            Image(systemName: "powerplug.fill").foregroundStyle(Palette.mint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.start.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium))
                                Text("\(Display.duration(session.end.timeIntervalSince(session.start))) recorded • \(session.ongoing ? "ongoing segment" : "ended or coverage stopped")")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Text("\(Int(session.firstLevel))% → \(Int(session.lastLevel))%").font(.system(size: 13)).monospacedDigit()
                            Text(Display.number(session.measuredSeconds > 0 ? session.chargedWh : nil, digits: 2, unit: " Wh"))
                                .font(.system(size: 13)).foregroundStyle(Palette.mint).monospacedDigit().frame(width: 95, alignment: .trailing)
                        }.padding(.vertical, 9)
                    }
                }
            }
            Panel {
                HStack {
                    Text("Power timeline").font(.system(size: 15, weight: .semibold)); Spacer()
                    Picker("Event filter", selection: $filter) { ForEach(filters, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 150)
                }
                if events.isEmpty {
                    EmptyMessage(icon: "clock", title: "No matching events", detail: "Power changes, sleep, charging controls and reminders appear here as Cell observes them.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 15) {
                                Image(systemName: event.kind.symbol).foregroundStyle(event.kind == .anomaly ? Palette.amber : Palette.violet).frame(width: 22)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(event.title).font(.system(size: 13, weight: .medium))
                                    if !event.detail.isEmpty { Text(event.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3) }
                                }
                                Spacer()
                                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }.padding(.vertical, 14)
                                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.5)).frame(height: 1) }
                        }
                    }
                }
                Text("Shows up to 300 recent events in this period. The timeline retains up to 10,000 events for 90 days. Unobserved activity while Cell is closed is not reconstructed.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }.task { await controller.reload() }
    }
}
