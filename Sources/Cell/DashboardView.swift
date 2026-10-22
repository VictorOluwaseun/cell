import SwiftUI
import BatteryCore

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "Statistics", activity = "App activity", insights = "Insights", timeline = "Timeline", reports = "Reports", limit = "Charging limit", alerts = "Charge alerts", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .history: "chart.xyaxis.line"
        case .activity: "square.stack.3d.up"
        case .insights: "sparkle.magnifyingglass"
        case .timeline: "clock"
        case .reports: "doc.text"
        case .limit: "battery.100percent.bolt"
        case .alerts: "bell"
        case .settings: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "A little clarity for every charge."
        case .history: "Understand how your battery changes over time."
        case .activity: "Find the work that asks the most of your Mac."
        case .insights: "See the patterns behind your battery readings."
        case .timeline: "Power changes, sleep and charging, in context."
        case .reports: "A measured look at your week."
        case .limit: "Choose where your battery takes a break."
        case .alerts: "The right reminder, at the right percentage."
        case .settings: "Make Cell work your way."
        }
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var page: DashboardPage = .overview
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let message = monitor.error ?? monitor.notice { messageBanner(message) }
                        InsightsErrorBanner(controller: monitor.insights)
                        if monitor.snapshot.state == .unavailable {
                            Panel { EmptyMessage(icon: "battery.0percent", title: "Waiting for a battery",
                                detail: "Cell needs a Mac with an internal battery. Readings will appear automatically when macOS makes them available.") }
                        }
                        switch page {
                        case .overview: OverviewView(monitor: monitor, showActivity: { page = .activity })
                        case .history: StatisticsView(monitor: monitor)
                        case .activity: ActivityView(monitor: monitor)
                        case .insights: InsightsView(controller: monitor.insights)
                        case .timeline: TimelineView(controller: monitor.insights)
                        case .reports: ReportsView(controller: monitor.insights)
                        case .limit:
                            if monitor.features[.chargingProfiles] {
                                ChargingProfilesView(monitor: monitor, controller: monitor.insights, chargeLimit: monitor.chargeLimit)
                            }
                            ChargeLimitView(controller: monitor.chargeLimit)
                        case .alerts: AlertsView(monitor: monitor, notifications: monitor.notifications)
                        case .settings: PreferencesView(monitor: monitor)
                        }
                    }.padding(28)
                }
                footer
            }
        }
        .frame(minWidth: 1_020, minHeight: 720)
        .background(Palette.background).foregroundStyle(Palette.text).tint(Palette.violet)
        .onChange(of: page) { _, _ in Task { await monitor.refresh(); await monitor.notifications.refresh() } }
        .onChange(of: monitor.features) { _, _ in if !available(page) { page = .overview } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.sidebar).frame(width: 35, height: 39)
                    .background(Palette.violet, in: RoundedRectangle(cornerRadius: 11))
                Text("cell").font(.system(size: 29, weight: .semibold, design: .rounded))
            }.padding(.top, 28).padding(.leading, 12)
            VStack(spacing: 7) {
                ForEach(DashboardPage.allCases.filter { $0 != .settings && available($0) }) { item in navigationButton(item) }
            }
            Spacer()
            navigationButton(.settings)
            HStack(spacing: 6) {
                Circle().fill(monitor.snapshot.state == .unavailable ? Palette.amber : Palette.mint).frame(width: 6, height: 6)
                Text("\(Host.current().localizedName ?? "This Mac")").lineLimit(1)
            }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 12).padding(.bottom, 17)
        }.padding(.horizontal, 14).frame(width: 207).background(Palette.sidebar)
    }
    private func available(_ page: DashboardPage) -> Bool {
        switch page {
        case .history: monitor.features[.batteryHistory]
        case .activity: monitor.features[.appActivity]
        case .timeline: monitor.features.recordsTimeline
        case .reports: monitor.features.generatesReports
        case .alerts: monitor.features[.chargeAlerts]
        case .insights: monitor.features[.runtimeForecast] || monitor.features[.batteryHistory]
        default: true
        }
    }
    private func navigationButton(_ item: DashboardPage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 19)
                Text(item.rawValue).font(.system(size: 12, weight: page == item ? .semibold : .regular))
                Spacer()
                if item == .alerts {
                    let count = monitor.alerts.filter(\.enabled).count
                    if count > 0 { Text("\(count)").font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 2).background(.white.opacity(0.08), in: Capsule()) }
                }
            }.foregroundStyle(page == item ? Palette.violet : Palette.muted)
                .padding(.horizontal, 13).padding(.vertical, 13).contentShape(Rectangle())
                .background(page == item ? Palette.violet.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(page == .overview ? "Battery overview" : page.rawValue).font(.system(size: 26, weight: .semibold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Palette.mint).frame(width: 5, height: 5)
                Text("Live").font(.system(size: 11))
            }.foregroundStyle(Palette.mint).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.mint.opacity(0.08), in: Capsule())
            Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)).padding(9) }
                .buttonStyle(.plain).help("Refresh battery readings (⌘R)").accessibilityLabel("Refresh readings")
        }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 23)
    }
    private var footer: some View {
        HStack {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("All data stays on this Mac")
            Spacer()
            Text("Updated \(monitor.snapshot.date.formatted(date: .omitted, time: .standard))")
        }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 28).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line.opacity(0.5)).frame(height: 1) }
    }
    private func messageBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: monitor.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
            Text(text).font(.system(size: 12))
            Spacer()
            Button { monitor.dismissMessages() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.foregroundStyle(monitor.error == nil ? Palette.mint : Palette.amber).padding(14)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}
