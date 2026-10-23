import Foundation
import Combine
import BatteryCore

/// One timer for the nearest deadline. No timers or sensor reads when there are no scheduled reminders.
@MainActor
final class TimedReminderController: ObservableObject {
    static let maximumReminders = 32
    @Published private(set) var reminders: [TimedChargeReminder]
    @Published private(set) var nextFireDate: Date?
    @Published private(set) var nextDates: [UUID: Date] = [:]
    @Published private(set) var error: String?
    @Published private(set) var enabled = false
    var readBattery: (@Sendable () async -> BatterySnapshot)?
    var deliver: ((TimedReminderOccurrence) async -> Void)?
    var rulesDidChange: (() -> Void)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let automaticScheduling: Bool
    private var timer: Timer?
    private var asleep = false
    private var checking = false
    private var checkAgain = false
    private var generation = 0
    private static let key = "timedChargeReminders"

    init(defaults: UserDefaults, automaticScheduling: Bool = true, now: @escaping () -> Date = { .now },
         calendar: @escaping () -> Calendar = { .autoupdatingCurrent }) {
        self.defaults = defaults; self.automaticScheduling = automaticScheduling
        self.now = now; self.calendar = calendar
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([TimedChargeReminder].self, from: $0) } ?? []
        var seen = Set<UUID>()
        reminders = Array(saved.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(Self.maximumReminders))
    }
    func start(enabled: Bool) {
        self.enabled = enabled
        requestCheck()
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; generation += 1
        if value {
            // Re-enabling reminders starts from now; paused occurrences are not replayed.
            var values = reminders
            for index in values.indices { values[index].activatedAt = max(values[index].activatedAt, now()) }
            replace(values)
        }
        scheduleNext(); requestCheck()
    }
    func add(_ rule: TimedChargeReminder) {
        guard reminders.count < Self.maximumReminders else { error = "You can save up to 32 time reminders."; return }
        guard rule.isValid, rule.repetition != .once || (rule.onceDate ?? .distantPast) > now() else {
            error = "Choose a valid future time for a one-time reminder."; return
        }
        guard !reminders.contains(where: { $0.id == rule.id || sameSchedule($0, rule) }) else { error = "A reminder for this action and time is already saved."; return }
        var value = rule; value.activatedAt = now(); value.lastHandled = nil
        replace(reminders + [value]); requestCheck()
    }
    func update(_ value: TimedChargeReminder) {
        guard let index = reminders.firstIndex(where: { $0.id == value.id }), value.isValid else { return }
        var value = value
        value.activatedAt = reminders[index].activatedAt; value.lastHandled = reminders[index].lastHandled
        if !value.hasSameConfiguration(as: reminders[index]) {
            guard !value.enabled || value.repetition != .once || (value.onceDate ?? .distantPast) > now() else {
                error = "Choose a future date for this one-time reminder."; return
            }
            value.activatedAt = now(); value.lastHandled = nil
        }
        var values = reminders; values[index] = value
        replace(values); requestCheck()
    }
    func remove(_ id: UUID) { replace(reminders.filter { $0.id != id }); requestCheck() }
    private func sameSchedule(_ a: TimedChargeReminder, _ b: TimedChargeReminder) -> Bool {
        a.action == b.action && a.hour == b.hour && a.minute == b.minute && a.repetition == b.repetition && a.onceDate == b.onceDate
    }
    private func replace(_ values: [TimedChargeReminder]) {
        guard values != reminders else { return }
        reminders = values; generation += 1; error = nil
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.key) }
        rulesDidChange?(); scheduleNext()
    }
    func suspend() { asleep = true; generation += 1; timer?.invalidate(); timer = nil; nextFireDate = nil; nextDates = [:] }
    func resume() { asleep = false; requestCheck() }
    func clockChanged() { generation += 1; scheduleNext(); requestCheck() }
    func shutdown() { enabled = false; generation += 1; timer?.invalidate(); timer = nil; nextFireDate = nil; nextDates = [:] }

    func check() async {
        guard enabled, !asleep else { return }
        if checking { checkAgain = true; return }
        checking = true
        defer {
            checking = false; scheduleNext()
            if checkAgain { checkAgain = false; requestCheck() }
        }
        let token = generation, date = now(), calendar = calendar()
        guard reminders.contains(where: { rule in
            guard let occurrence = rule.latestOccurrence(at: date, calendar: calendar) else { return false }
            return occurrence >= rule.activatedAt && occurrence > (rule.lastHandled ?? .distantPast)
        }) else { return }
        let snapshot = await readBattery?() ?? .unavailable
        guard enabled, !asleep, token == generation else { return }
        var values = reminders
        let due = TimedReminderEvaluator.evaluate(&values, at: now(), snapshot: snapshot, calendar: calendar)
        replace(values)
        for occurrence in due where isCurrent(occurrence) {
            await deliver?(occurrence)
        }
    }
    func isCurrent(_ occurrence: TimedReminderOccurrence) -> Bool {
        enabled && !asleep && reminders.contains {
            $0.enabled && occurrence.date >= $0.activatedAt && $0.lastHandled == occurrence.date && $0.hasSameConfiguration(as: occurrence.rule)
        }
    }
    private func requestCheck() {
        guard automaticScheduling else { scheduleNext(); return }
        Task { [weak self] in await self?.check() }
    }
    private func scheduleNext() {
        timer?.invalidate(); timer = nil
        guard enabled, !asleep else {
            if nextFireDate != nil { nextFireDate = nil }
            if !nextDates.isEmpty { nextDates = [:] }
            return
        }
        let date = now(), calendar = calendar()
        let dates = Dictionary(uniqueKeysWithValues: reminders.compactMap { rule in
            rule.nextOccurrence(after: date, calendar: calendar).map { (rule.id, $0) }
        })
        if nextDates != dates { nextDates = dates }
        let next = dates.values.min()
        if nextFireDate != next { nextFireDate = next }
        guard automaticScheduling, let next else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
}
