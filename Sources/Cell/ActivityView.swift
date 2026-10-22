import AppKit
import SwiftUI
import BatteryCore

struct AppActivityRow: View {
    var app: AppActivity
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.bundlePath).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name.isEmpty ? "Process \(app.id)" : app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(compact ? "\(Display.number(app.cpuPercent, unit: "%")) CPU" : "\(app.processes) process\(app.processes == 1 ? "" : "es") · PID \(app.id)")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if !compact {
                Text(Display.number(app.cpuPercent, unit: "%")).frame(width: 75, alignment: .trailing)
                Text(Display.number(app.wakeups, unit: "/s")).frame(width: 85, alignment: .trailing)
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: app.memory), countStyle: .memory)).frame(width: 85, alignment: .trailing)
            }
            Text(app.watts.map { Display.number($0, digits: 3, unit: " W") } ?? (compact ? "CPU proxy" : "—"))
                .foregroundStyle(app.watts == nil ? Palette.muted : Palette.violet)
                .frame(width: compact ? 85 : 90, alignment: .trailing)
        }.font(.system(size: 12)).monospacedDigit().accessibilityElement(children: .combine)
    }
}

struct AppIcon: View {
    var path: String?
    private static let cache = NSCache<NSString, NSImage>()
    private func icon(_ path: String) -> NSImage {
        if let cached = Self.cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        Self.cache.countLimit = 256
        Self.cache.setObject(icon, forKey: path as NSString)
        return icon
    }
    var body: some View {
        Group {
            if let path { Image(nsImage: icon(path)).resizable().interpolation(.high) }
            else { Image(systemName: "app.dashed").resizable().scaledToFit().padding(4).foregroundStyle(Palette.muted) }
        }.accessibilityHidden(true)
    }
}

struct ActivityView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var search = ""
    @State private var onlyApps = false
    @State private var sort: ActivitySort = .power
    @State private var showHistory = false
    private enum ActivitySort: String, CaseIterable { case power = "Power", cpu = "CPU", wakeups = "Wakeups", memory = "Memory" }
    private var filtered: [AppActivity] {
        monitor.apps.filter {
            (!onlyApps || $0.bundlePath != nil) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            switch sort {
            case .power:
                if $0.watts != nil || $1.watts != nil { return ($0.watts ?? -1) > ($1.watts ?? -1) }
                return $0.cpuPercent > $1.cpuPercent
            case .cpu: return $0.cpuPercent > $1.cpuPercent
            case .wakeups: return $0.wakeups > $1.wakeups
            case .memory: return $0.memory > $1.memory
            }
        }
    }
    var body: some View {
        VStack(spacing: 20) {
            if monitor.features.recordsAppEnergy {
                Picker("App activity view", selection: $showHistory) {
                    Text("Live activity").tag(false); Text("Energy history").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300, alignment: .leading)
            }
            if showHistory && monitor.features.recordsAppEnergy { AppEnergyHistoryView(controller: monitor.insights) }
            else { liveContent }
        }
    }
    private var liveContent: some View {
        VStack(spacing: 20) {
            Panel {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "info.circle").foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("A closer look at power use").font(.system(size: 14, weight: .medium))
                        Text("Watts come from process energy counters when macOS makes them available. CPU is a fallback activity signal, not a watt estimate. Some system, GPU and device energy cannot be attributed to apps. Only readable processes belonging to your user are shown.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                }
            }
            Panel {
                HStack(spacing: 14) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        TextField("Search apps and processes", text: $search).textFieldStyle(.plain)
                    }.padding(9).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                    Toggle("Apps only", isOn: $onlyApps).toggleStyle(.checkbox).font(.system(size: 11))
                    Picker("Sort by", selection: $sort) {
                        ForEach(ActivitySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 150)
                }
                HStack {
                    Text("Application"); Spacer()
                    Text("CPU").frame(width: 75, alignment: .trailing)
                    Text("Wakeups").frame(width: 85, alignment: .trailing)
                    Text("Memory").frame(width: 85, alignment: .trailing)
                    Text("Power").frame(width: 90, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                if !monitor.features[.appActivity] {
                    EmptyMessage(icon: "pause.circle", title: "Monitoring is paused", detail: "Turn on app monitoring in Settings to collect app activity.")
                } else if monitor.apps.isEmpty {
                    EmptyMessage(icon: "waveform.path", title: "Collecting the first interval", detail: "Keep Cell active for about 10 seconds to compare process counters.")
                } else if filtered.isEmpty {
                    EmptyMessage(icon: "magnifyingglass", title: "No matching processes", detail: "Try another name or turn off the Apps only filter.")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { app in
                            AppActivityRow(app: app).padding(.vertical, 12)
                                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.55)).frame(height: 1) }
                        }
                    }
                }
                HStack {
                    Text("10–30 seconds while active; 30 seconds in the background")
                    Spacer()
                    Text("\(filtered.count) visible")
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }
}
