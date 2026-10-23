import Foundation
import Testing
@testable import BatteryCore

private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func reminderCalendar(_ zone: String = "Africa/Lagos") -> Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value
}
private func morning(_ action: ChargingReminderAction = .plugIn, repetition: ReminderRepeat = .daily) -> TimedChargeReminder {
    .init(action: action, hour: 9, minute: 0, repetition: repetition, activatedAt: instant("2026-10-22T08:00:00+01:00"))
}

@Test func timedReminderFindsDailyAndWeekdayDeadlines() {
    let calendar = reminderCalendar(), friday = instant("2026-10-23T09:00:00+01:00")
    #expect(morning().nextOccurrence(after: friday.addingTimeInterval(-1), calendar: calendar) == friday)
    #expect(morning().nextOccurrence(after: friday, calendar: calendar) == instant("2026-10-24T09:00:00+01:00"))
    #expect(morning(repetition: .weekdays).nextOccurrence(after: friday, calendar: calendar) == instant("2026-10-26T09:00:00+01:00"))
    // A clock rollback must retain a future deadline, even if activation is now weeks ahead.
    var futureActivation = morning(); futureActivation.activatedAt = instant("2026-11-23T08:00:00+01:00")
    #expect(futureActivation.nextOccurrence(after: friday, calendar: calendar) == instant("2026-11-23T09:00:00+01:00"))
}

@Test func timedReminderOnceAndInvalidValuesAreHandled() throws {
    let due = instant("2026-10-23T09:00:00+01:00"), calendar = reminderCalendar()
    var rule = morning(repetition: .once); rule.onceDate = due
    #expect(rule.nextOccurrence(after: due.addingTimeInterval(-1), calendar: calendar) == due)
    #expect(rule.nextOccurrence(after: due, calendar: calendar) == nil)
    rule.hour = 24; #expect(!rule.isValid && rule.nextOccurrence(after: due, calendar: calendar) == nil)
    rule.hour = 9; rule.onceDate = nil; #expect(!rule.isValid)
    rule = morning(); rule.minute = -1; #expect(!rule.isValid)
}

@Test func timedReminderConsumesOccurrencesAcrossPersistenceAndClockRollback() throws {
    let due = instant("2026-10-23T09:00:00+01:00"), calendar = reminderCalendar()
    var rules = [morning()]
    #expect(TimedReminderEvaluator.evaluate(&rules, at: due, snapshot: .init(level: 50, state: .discharging), calendar: calendar).count == 1)
    rules = try JSONDecoder().decode([TimedChargeReminder].self, from: JSONEncoder().encode(rules))
    for time in [due.addingTimeInterval(30), due.addingTimeInterval(-30), due] {
        #expect(TimedReminderEvaluator.evaluate(&rules, at: time, snapshot: .unavailable, calendar: calendar).isEmpty)
    }
    #expect(TimedReminderEvaluator.evaluate(&rules, at: due.addingTimeInterval(86_400), snapshot: .unavailable, calendar: calendar).count == 1)
}

@Test func timedReminderCatchesRecentWakeButSkipsOldAndNewlyCreatedOccurrences() {
    let due = instant("2026-10-23T09:00:00+01:00"), calendar = reminderCalendar()
    var recent = [morning()], old = [morning()], new = [morning()]
    #expect(TimedReminderEvaluator.evaluate(&recent, at: due.addingTimeInterval(900), snapshot: .unavailable, calendar: calendar).count == 1)
    #expect(TimedReminderEvaluator.evaluate(&old, at: due.addingTimeInterval(901), snapshot: .unavailable, calendar: calendar).isEmpty)
    #expect(old[0].lastHandled == due)
    new[0].activatedAt = due.addingTimeInterval(1)
    #expect(TimedReminderEvaluator.evaluate(&new, at: due.addingTimeInterval(2), snapshot: .unavailable, calendar: calendar).isEmpty)
}

@Test func timedReminderSkipsSatisfiedActionsButUnknownSensorsStillRemind() {
    let due = instant("2026-10-23T09:00:00+01:00"), calendar = reminderCalendar()
    for state in [BatteryState.charging, .pluggedIn, .full] {
        var rules = [morning()]
        #expect(TimedReminderEvaluator.evaluate(&rules, at: due, snapshot: .init(level: 80, state: state), calendar: calendar).isEmpty)
        #expect(rules[0].lastHandled == due)
    }
    var unplug = [morning(.unplug)]
    #expect(TimedReminderEvaluator.evaluate(&unplug, at: due, snapshot: .init(level: 50, state: .discharging), calendar: calendar).isEmpty)
    var unknown = [morning(), morning(.unplug)]
    #expect(TimedReminderEvaluator.evaluate(&unknown, at: due, snapshot: .unavailable, calendar: calendar).count == 2)
    var unconditional = morning(); unconditional.onlyIfNeeded = false
    var rules = [unconditional]
    #expect(TimedReminderEvaluator.evaluate(&rules, at: due, snapshot: .init(level: 80, state: .charging), calendar: calendar).count == 1)
}

@Test func timedReminderUsesLocalClockAndHandlesMidnightCatchUp() {
    let now = instant("2026-10-23T00:04:00+01:00"), calendar = reminderCalendar()
    var rule = morning(); rule.hour = 23; rule.minute = 59
    var rules = [rule]
    #expect(TimedReminderEvaluator.evaluate(&rules, at: now, snapshot: .unavailable, calendar: calendar).first?.date == instant("2026-10-22T23:59:00+01:00"))
    let after = instant("2026-10-23T06:00:00Z")
    let lagos = morning().nextOccurrence(after: after, calendar: calendar)!
    let newYork = morning().nextOccurrence(after: after, calendar: reminderCalendar("America/New_York"))!
    #expect(lagos != newYork)
    #expect(calendar.component(.hour, from: lagos) == 9)
    #expect(reminderCalendar("America/New_York").component(.hour, from: newYork) == 9)
}

@Test func timedReminderUsesNextValidSpringTimeAndOnlyFirstAutumnTime() {
    let calendar = reminderCalendar("America/New_York")
    var spring = morning(); spring.hour = 2; spring.minute = 30; spring.activatedAt = instant("2026-03-01T00:00:00Z")
    #expect(spring.nextOccurrence(after: instant("2026-03-08T00:00:00-05:00"), calendar: calendar) == instant("2026-03-08T03:00:00-04:00"))
    var autumn = morning(); autumn.hour = 1; autumn.minute = 30
    let first = instant("2026-11-01T01:30:00-04:00"), second = instant("2026-11-01T01:30:00-05:00")
    #expect(autumn.nextOccurrence(after: instant("2026-11-01T00:00:00-04:00"), calendar: calendar) == first)
    var rules = [autumn]
    #expect(TimedReminderEvaluator.evaluate(&rules, at: first, snapshot: .unavailable, calendar: calendar).count == 1)
    #expect(TimedReminderEvaluator.evaluate(&rules, at: second, snapshot: .unavailable, calendar: calendar).isEmpty)
    #expect(autumn.nextOccurrence(after: first, calendar: calendar) == instant("2026-11-02T01:30:00-05:00"))
}

@Test func timedAndPercentageAlarmsReconcileTogetherAndSnooze() {
    let timed = morning(.unplug), percentage = ChargeAlert(direction: .above, threshold: 80)
    var session = ReminderAlarmSession()
    session.enqueue(.init(ruleID: timed.id, title: "Unplug", body: "Time reminder"))
    session.enqueue(.init(ruleID: percentage.id, title: "Charge target", body: "80%"))
    session.reconcile(.init(level: 80, state: .charging), rules: [percentage], timeRules: [timed])
    #expect(session.messages.count == 2)
    let now = instant("2026-10-23T09:00:00+01:00")
    session.snooze(now: now)
    let resumed = session.resume(now: now.addingTimeInterval(300))
    #expect(resumed)
    session.reconcile(.unavailable, rules: [percentage], timeRules: [timed])
    #expect(session.messages.count == 2)
    session.reconcile(.init(level: 80, state: .discharging), rules: [percentage], timeRules: [timed])
    #expect(session.messages.isEmpty)
    var always = timed; always.onlyIfNeeded = false
    session.enqueue(.init(ruleID: timed.id, title: "Unplug", body: "Time reminder"))
    session.reconcile(.init(level: 80, state: .discharging), rules: [], timeRules: [always])
    #expect(session.messages.count == 1)
    always.enabled = false
    session.reconcile(.init(level: 80, state: .discharging), rules: [], timeRules: [always])
    #expect(session.messages.isEmpty)
}
