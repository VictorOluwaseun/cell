import Foundation
import CPlatform
import BatteryCore

struct AppIdentity: Sendable {
    var pid: Int32
    var name: String
    var bundlePath: String?
    var quitTarget: ApplicationQuitTarget? = nil
}

struct AppActivity: Identifiable, Sendable {
    var id: Int32
    var name: String
    var bundlePath: String?
    var cpuPercent: Double
    var watts: Double?
    var wakeups: Double
    var memory: UInt64
    var processes: Int
    var sampledSeconds: Double = 0
    var quitTarget: ApplicationQuitTarget? = nil
    var processStarted: UInt64? = nil
}

actor TelemetryEngine {
    private struct Counter {
        var started: UInt64
        var cpu: UInt64
        var energy: UInt64
        var wakeups: UInt64
    }
    private var previous: [Int32: Counter] = [:]
    private var previousTime: TimeInterval?
    func battery() -> BatterySnapshot { BatteryReader().read() }

    func resetProcesses() { previous.removeAll(); previousTime = nil }

    func applications(catalog: [AppIdentity]) -> [AppActivity] {
        let now = ProcessInfo.processInfo.systemUptime
        var rows = [CellProcess](repeating: CellProcess(), count: 16_384)
        let count = cell_read_processes(&rows, Int32(rows.count))
        guard count >= 0 else { return [] }
        let live = rows.prefix(Int(count))
        let parents = Dictionary(uniqueKeysWithValues: live.map { ($0.pid, $0.parent_pid) })
        let known = Dictionary(catalog.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let dt = previousTime.map { now - $0 } ?? 0
        var next: [Int32: Counter] = [:]
        var grouped: [Int32: AppActivity] = [:]
        for var row in live {
            next[row.pid] = Counter(started: row.started, cpu: row.cpu_ns, energy: row.energy_nj, wakeups: row.wakeups)
            guard dt >= 1, dt <= 90, let old = previous[row.pid], old.started == row.started,
                  row.cpu_ns >= old.cpu else { continue }
            var root = row.pid
            var cursor = row.pid
            for _ in 0..<16 {
                if known[cursor] != nil { root = cursor; break }
                guard let parent = parents[cursor], parent > 1, parent != cursor else { break }
                cursor = parent
            }
            let identity = known[root]
            let fallback = withUnsafePointer(to: &row.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            let cpu = Double(row.cpu_ns - old.cpu) / 1_000_000_000 / dt * 100
            let watts: Double? = row.has_energy != 0 && old.energy > 0 && row.energy_nj >= old.energy
                ? Double(row.energy_nj - old.energy) / 1_000_000_000 / dt : nil
            let wakeups = row.wakeups >= old.wakeups ? Double(row.wakeups - old.wakeups) / dt : 0
            var group = grouped[root] ?? AppActivity(id: root, name: identity?.name ?? fallback,
                bundlePath: identity?.bundlePath, cpuPercent: 0, watts: nil, wakeups: 0, memory: 0, processes: 0,
                quitTarget: identity?.quitTarget)
            group.cpuPercent += cpu
            if let watts { group.watts = (group.watts ?? 0) + watts }
            group.wakeups += wakeups; group.memory += row.memory_bytes; group.processes += 1
            grouped[root] = group
        }
        previous = next; previousTime = now
        return grouped.values.map { value in
            var value = value; value.sampledSeconds = dt; value.processStarted = next[value.id]?.started; return value
        }.sorted {
            if $0.watts != nil || $1.watts != nil { return ($0.watts ?? -1) > ($1.watts ?? -1) }
            return $0.cpuPercent > $1.cpuPercent
        }
    }
}
