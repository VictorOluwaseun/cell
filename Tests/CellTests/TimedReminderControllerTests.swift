import Foundation
import Testing
import BatteryCore
@testable import Cell

private func time(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
@MainActor private final class ReminderClock {
    var date = time("2026-10-23T08:00:00+01:00")
    var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Africa/Lagos")!; return value
    }()
}
@MainActor private func scheduler(_ clock: ReminderClock) -> (TimedReminderController, UserDefaults, String) {
    let domain = "Cell-timed-reminders-\(UUID().uuidString)"
    let isolated = UserDefaults(suiteName: domain)!
    return (TimedReminderController(defaults: isolated, automaticScheduling: false, now: { clock.date }, calendar: { clock.calendar }), isolated, domain)
}
private func scheduled(_ minute: Int = 0, action: ChargingReminderAction = .plugIn) -> TimedChargeReminder {
    .init(action: action, hour: 9, minute: minute)
}

@Test @MainActor func timeSchedulerPersistsAndDoesNotRepeatAfterRelaunch() async {
    let clock = ReminderClock(), (active, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain); active.shutdown() }
    var fired: [TimedReminderOccurrence] = []; active.deliver = { fired.append($0) }
    active.add(scheduled()); active.start(enabled: true)
    #expect(active.nextFireDate == time("2026-10-23T09:00:00+01:00"))
    clock.date = time("2026-10-23T09:00:00+01:00"); await active.check(); await active.check()
    #expect(fired.count == 1 && active.reminders[0].lastHandled == clock.date)
    let restored = TimedReminderController(defaults: defaults, automaticScheduling: false, now: { clock.date }, calendar: { clock.calendar })
    restored.deliver = { fired.append($0) }; restored.start(enabled: true); await restored.check()
    #expect(fired.count == 1 && restored.nextFireDate == time("2026-10-24T09:00:00+01:00"))
    restored.shutdown()
}

@Test @MainActor func timeSchedulerDoesNotReplayRemindersPausedByMasterSwitch() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var fired = 0; controller.deliver = { _ in fired += 1 }
    controller.add(scheduled()); controller.start(enabled: false)
    clock.date = time("2026-10-23T09:05:00+01:00"); await controller.check()
    #expect(fired == 0 && controller.nextFireDate == nil)
    controller.setEnabled(true); await controller.check()
    #expect(fired == 0 && controller.nextFireDate == time("2026-10-24T09:00:00+01:00"))
}

@Test @MainActor func timeSchedulerHandlesSleepWakeAndIndividualPause() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var fired = 0; controller.deliver = { _ in fired += 1 }
    controller.add(scheduled()); controller.start(enabled: true)
    var rule = controller.reminders[0]; rule.enabled = false; controller.update(rule)
    clock.date = time("2026-10-23T09:01:00+01:00")
    rule.enabled = true; controller.update(rule); await controller.check()
    #expect(fired == 0)
    controller.suspend(); clock.date = time("2026-10-24T09:10:00+01:00"); await controller.check()
    #expect(fired == 0 && controller.nextFireDate == nil)
    controller.resume(); await controller.check(); #expect(fired == 1)
    controller.suspend(); clock.date = time("2026-10-25T09:16:00+01:00"); controller.resume(); await controller.check()
    #expect(fired == 1 && controller.reminders[0].lastHandled == time("2026-10-25T09:00:00+01:00"))
}

@Test @MainActor func timeSchedulerConsumesAlreadySatisfiedActions() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var fired = 0; controller.deliver = { _ in fired += 1 }
    controller.readBattery = { .init(level: 80, state: .charging) }
    controller.add(scheduled()); controller.start(enabled: true)
    clock.date = time("2026-10-23T09:00:00+01:00"); await controller.check()
    controller.readBattery = { .init(level: 80, state: .discharging) }
    clock.date = clock.date.addingTimeInterval(60); await controller.check()
    #expect(fired == 0 && controller.reminders[0].lastHandled != nil)
}

@MainActor private final class ReminderBatteryGate {
    private var continuation: CheckedContinuation<BatterySnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read() async -> BatterySnapshot {
        await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { continuation?.resume(returning: .unavailable); continuation = nil }
}

@Test @MainActor func timeSchedulerRejectsDeletedRulesDuringSensorRead() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock), gate = ReminderBatteryGate()
    defer { defaults.removePersistentDomain(forName: domain) }
    var fired = 0; controller.deliver = { _ in fired += 1 }; controller.readBattery = { await gate.read() }
    controller.add(scheduled()); controller.start(enabled: true)
    clock.date = time("2026-10-23T09:00:00+01:00")
    let check = Task { await controller.check() }
    await gate.waitUntilStarted(); controller.remove(controller.reminders[0].id); gate.finish(); await check.value
    #expect(fired == 0 && controller.reminders.isEmpty && controller.nextFireDate == nil)
}

@Test @MainActor func timeSchedulerValidatesDuplicatesAndBoundsSavedRules() {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var invalid = scheduled(); invalid.hour = 24; controller.add(invalid)
    #expect(controller.reminders.isEmpty && controller.error != nil)
    controller.add(scheduled()); controller.add(scheduled())
    #expect(controller.reminders.count == 1 && controller.error != nil)
    for minute in 1...32 { controller.add(scheduled(minute)) }
    #expect(controller.reminders.count == 32 && controller.error != nil)
}

@Test @MainActor func timeSchedulerPreservesConsumedStateOnStaleUpdatesAndRejectsOldDeliveries() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var fired: [TimedReminderOccurrence] = []; controller.deliver = { fired.append($0) }
    controller.add(scheduled()); let stale = controller.reminders[0]; controller.start(enabled: true)
    clock.date = time("2026-10-23T09:00:00+01:00"); await controller.check()
    controller.update(stale); await controller.check()
    #expect(fired.count == 1 && controller.reminders[0].lastHandled == clock.date)
    let occurrence = fired[0]
    controller.setEnabled(false); clock.date = clock.date.addingTimeInterval(60); controller.setEnabled(true)
    #expect(!controller.isCurrent(occurrence))
    var changed = controller.reminders[0]; changed.hour = 10; controller.update(changed)
    #expect(controller.nextFireDate == time("2026-10-23T10:00:00+01:00") && controller.reminders[0].lastHandled == nil)
}

@Test @MainActor func timeSchedulerChecksEachDeliveryAgainstCurrentRules() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    controller.add(scheduled()); controller.add(scheduled(action: .unplug)); controller.start(enabled: true)
    let first = controller.reminders[0].id, second = controller.reminders[1].id
    var fired: [UUID] = []
    controller.deliver = { occurrence in fired.append(occurrence.rule.id); controller.remove(second) }
    clock.date = time("2026-10-23T09:00:00+01:00"); await controller.check()
    #expect(fired == [first])
}

@Test @MainActor func timeSchedulerHasNoDeadlineWhenEmptyOrDisabled() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var deliveries = 0; controller.deliver = { _ in deliveries += 1 }
    controller.start(enabled: true); await controller.check()
    #expect(controller.nextFireDate == nil && deliveries == 0)
    controller.add(scheduled()); #expect(controller.nextFireDate != nil)
    controller.shutdown(); #expect(controller.nextFireDate == nil)
}

@Test @MainActor func timeSchedulerRebuildsCachedDeadlinesWhenTimeZoneChanges() async {
    let clock = ReminderClock(), (controller, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    var fired = 0; controller.deliver = { _ in fired += 1 }
    controller.add(scheduled()); controller.start(enabled: true)
    #expect(controller.nextFireDate == time("2026-10-23T09:00:00+01:00"))
    clock.calendar.timeZone = TimeZone(identifier: "America/New_York")!
    controller.clockChanged()
    #expect(controller.nextFireDate == time("2026-10-23T09:00:00-04:00"))
    #expect(controller.nextDates.count == 1)
    clock.date = time("2026-10-23T09:00:00-04:00"); await controller.check()
    #expect(fired == 1)
}

@Test @MainActor func timeSchedulerFiltersInvalidAndDuplicateSavedIdentities() throws {
    let clock = ReminderClock(), (_, defaults, domain) = scheduler(clock)
    defer { defaults.removePersistentDomain(forName: domain) }
    let valid = scheduled()
    var invalid = scheduled(); invalid.minute = 90
    let data = try JSONEncoder().encode([valid, valid, invalid])
    defaults.set(data, forKey: "timedChargeReminders")
    let restored = TimedReminderController(defaults: defaults, automaticScheduling: false)
    #expect(restored.reminders == [valid])
}
