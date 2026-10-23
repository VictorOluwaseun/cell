import Foundation

public enum ChargingReminderAction: String, CaseIterable, Codable, Sendable {
    case plugIn, unplug
    public var title: String { self == .plugIn ? "Plug in" : "Unplug" }
    public var reminderTitle: String { self == .plugIn ? "Time to plug in" : "Time to unplug" }
    public func isSatisfied(by snapshot: BatterySnapshot) -> Bool {
        self == .plugIn ? snapshot.state.onAC : snapshot.state == .discharging
    }
}

public enum ReminderRepeat: String, CaseIterable, Codable, Sendable {
    case once, daily, weekdays
    public var title: String {
        switch self { case .once: "Once"; case .daily: "Every day"; case .weekdays: "Weekdays" }
    }
}

public struct TimedChargeReminder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var action: ChargingReminderAction
    public var hour: Int
    public var minute: Int
    public var repetition: ReminderRepeat
    public var onceDate: Date?
    public var enabled: Bool
    public var onlyIfNeeded: Bool
    public var activatedAt: Date
    public var lastHandled: Date?

    public init(id: UUID = UUID(), action: ChargingReminderAction, hour: Int, minute: Int,
                repetition: ReminderRepeat = .daily, onceDate: Date? = nil, enabled: Bool = true,
                onlyIfNeeded: Bool = true, activatedAt: Date = .now, lastHandled: Date? = nil) {
        self.id = id; self.action = action; self.hour = hour; self.minute = minute
        self.repetition = repetition; self.onceDate = onceDate; self.enabled = enabled
        self.onlyIfNeeded = onlyIfNeeded; self.activatedAt = activatedAt; self.lastHandled = lastHandled
    }
    public var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) && activatedAt.timeIntervalSince1970.isFinite &&
        (lastHandled?.timeIntervalSince1970.isFinite ?? true) &&
        (repetition != .once || onceDate?.timeIntervalSince1970.isFinite == true)
    }
    public func hasSameConfiguration(as other: Self) -> Bool {
        id == other.id && action == other.action && hour == other.hour && minute == other.minute &&
        repetition == other.repetition && onceDate == other.onceDate && enabled == other.enabled && onlyIfNeeded == other.onlyIfNeeded
    }
    public func nextOccurrence(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard enabled, isValid else { return nil }
        let lower = max(date, lastHandled ?? .distantPast)
        if repetition == .once {
            guard let onceDate, onceDate > lower, onceDate >= activatedAt else { return nil }
            return onceDate
        }
        let start = calendar.startOfDay(for: max(lower, activatedAt))
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let candidate = occurrence(on: day, calendar: calendar), candidate > lower, candidate >= activatedAt else { continue }
            return candidate
        }
        return nil
    }
    public func latestOccurrence(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard enabled, isValid else { return nil }
        if repetition == .once { return onceDate.flatMap { $0 <= date ? $0 : nil } }
        let start = calendar.startOfDay(for: date)
        // The catch-up window is 15 minutes, so only today and yesterday can be relevant.
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let candidate = occurrence(on: day, calendar: calendar), candidate <= date else { continue }
            return candidate
        }
        return nil
    }
    private func occurrence(on day: Date, calendar: Calendar) -> Date? {
        if repetition == .weekdays, !(2...6).contains(calendar.component(.weekday, from: day)) { return nil }
        let start = calendar.startOfDay(for: day)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        guard let result = calendar.nextDate(after: start.addingTimeInterval(-1), matching: components,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first), calendar.isDate(result, inSameDayAs: day) else { return nil }
        return result
    }
}

public struct TimedReminderOccurrence: Equatable, Sendable {
    public var rule: TimedChargeReminder
    public var date: Date
    public init(rule: TimedChargeReminder, date: Date) { self.rule = rule; self.date = date }
}

public enum TimedReminderEvaluator {
    public static let catchUpSeconds: TimeInterval = 15 * 60
    /// Consume each occurrence before delivery, including occurrences skipped because the action is done.
    public static func evaluate(_ rules: inout [TimedChargeReminder], at date: Date, snapshot: BatterySnapshot,
                                calendar: Calendar = .autoupdatingCurrent) -> [TimedReminderOccurrence] {
        var due: [TimedReminderOccurrence] = []
        for index in rules.indices {
            guard let occurrence = rules[index].latestOccurrence(at: date, calendar: calendar),
                  occurrence >= rules[index].activatedAt, occurrence > (rules[index].lastHandled ?? .distantPast) else { continue }
            rules[index].lastHandled = occurrence
            guard date.timeIntervalSince(occurrence) <= catchUpSeconds,
                  !rules[index].onlyIfNeeded || !rules[index].action.isSatisfied(by: snapshot) else { continue }
            due.append(.init(rule: rules[index], date: occurrence))
        }
        return due
    }
}
