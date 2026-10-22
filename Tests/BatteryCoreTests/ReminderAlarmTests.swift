import Foundation
import Testing
@testable import BatteryCore

private let alarmDate = Date(timeIntervalSince1970: 1_790_000_000)

@Test func alarmCoalescesDuplicateRulesAndKeepsSeparateThresholds() {
    var session = ReminderAlarmSession()
    let first = ReminderAlarmMessage(ruleID: UUID(), title: "First", body: "80%")
    session.enqueue(first); session.enqueue(first)
    session.enqueue(.init(ruleID: first.ruleID, title: "Same rule", body: "81%"))
    session.enqueue(.init(ruleID: UUID(), title: "Second", body: "90%"))
    #expect(session.messages.count == 2)
}

@Test func snoozeDefersNewThresholdsAndResumesExactlyOnce() {
    var session = ReminderAlarmSession()
    session.enqueue(.init(ruleID: UUID(), title: "First", body: ""))
    session.snooze(now: alarmDate)
    session.enqueue(.init(ruleID: UUID(), title: "Second", body: ""))
    #expect(session.snoozedUntil == alarmDate.addingTimeInterval(300))
    let early = session.resume(now: alarmDate.addingTimeInterval(299))
    let ready = session.resume(now: alarmDate.addingTimeInterval(300))
    let repeated = session.resume(now: alarmDate.addingTimeInterval(301))
    #expect(!early && ready && !repeated)
    #expect(session.messages.count == 2 && session.snoozedUntil == nil)
}

@Test func dismissAndRuleRemovalCancelPendingSnoozes() {
    var session = ReminderAlarmSession()
    let ruleID = UUID()
    session.enqueue(.init(ruleID: ruleID, title: "Reminder", body: ""))
    session.snooze(now: alarmDate)
    session.retainRules([])
    #expect(session.messages.isEmpty && session.snoozedUntil == nil)
    session.enqueue(.init(ruleID: ruleID, title: "Reminder", body: ""))
    session.snooze(now: alarmDate); session.dismiss()
    let resumed = session.resume(now: alarmDate.addingTimeInterval(500))
    #expect(!resumed)
}

@Test func notificationStopCannotDismissUnrelatedOrNewerAlarms() {
    var session = ReminderAlarmSession()
    let first = ReminderAlarmMessage(ruleID: UUID(), title: "First", body: "")
    let second = ReminderAlarmMessage(ruleID: UUID(), title: "Second", body: "")
    session.enqueue(first); session.enqueue(second)
    session.remove(id: UUID())
    #expect(session.messages.count == 2)
    session.remove(id: first.id)
    #expect(session.messages == [second])
}

@Test func pluggingInCancelsALowBatteryAlarmAndUnpluggingCancelsChargeAlarm() {
    var session = ReminderAlarmSession()
    let low = ChargeAlert(direction: .below, threshold: 20)
    session.enqueue(.init(ruleID: low.id, title: low.title, body: ""))
    session.snooze(now: alarmDate)
    session.reconcile(.init(level: 18, state: .charging), rules: [low])
    #expect(session.messages.isEmpty && session.snoozedUntil == nil)
    let high = ChargeAlert(direction: .above, threshold: 80)
    session.enqueue(.init(ruleID: high.id, title: high.title, body: ""))
    session.reconcile(.init(level: 90, state: .discharging), rules: [high])
    #expect(session.messages.isEmpty)
}

@Test func pausedChargingStillKeepsAChargeAlarmAndMissingSensorsDoNotDismissIt() {
    var session = ReminderAlarmSession()
    let high = ChargeAlert(direction: .above, threshold: 80)
    session.enqueue(.init(ruleID: high.id, title: high.title, body: ""))
    session.reconcile(.init(level: 80, state: .pluggedIn), rules: [high])
    session.reconcile(.unavailable, rules: [high])
    #expect(session.messages.count == 1)
    session.reconcile(.init(level: 77, state: .charging), rules: [high])
    #expect(session.messages.isEmpty)
}

@Test func testAlarmDoesNotDependOnBatteryRules() {
    var session = ReminderAlarmSession()
    session.enqueue(.init(title: "Test", body: ""))
    session.retainRules([])
    session.reconcile(.init(level: 50, state: .discharging), rules: [])
    #expect(session.messages.count == 1)
}

@Test func alarmPreferencesRoundTripAndClampUnsafeVolumes() throws {
    var preferences = ReminderAlarmPreferences()
    #expect(preferences.enabled && preferences.duration == .oneMinute)
    preferences.tone = .bell; preferences.duration = .untilStopped
    #expect(try JSONDecoder().decode(ReminderAlarmPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    preferences.volume = .nan; #expect(preferences.sanitized.volume == 0.75)
    preferences.volume = 200; #expect(preferences.sanitized.volume == 1)
    preferences.volume = -1; #expect(preferences.sanitized.volume == 0.1)
}

@Test func generatedTonesHaveValidPCMHeadersAndAvoidClippingAndLoopClicks() {
    var tones = Set<Data>()
    for tone in ReminderTone.allCases {
        let data = ReminderAlarmAudio.wav(tone: tone)
        #expect(String(data: data.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: data[8..<16], encoding: .utf8) == "WAVEfmt ")
        #expect(data.count == 44 + ReminderAlarmAudio.sampleRate * ReminderAlarmAudio.seconds * 2)
        func integer(at offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        #expect(integer(at: 4) == data.count - 8)
        #expect(integer(at: 24) == ReminderAlarmAudio.sampleRate)
        #expect(integer(at: 40) == data.count - 44)
        let samples = stride(from: 44, to: data.count, by: 2).map { offset in
            Int(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8))
        }
        #expect(samples.first == 0 && samples.last == 0)
        #expect(samples.map(abs).max()! < 32_000)
        #expect(samples.contains { abs($0) > 10_000 })
        #expect(samples.suffix(ReminderAlarmAudio.sampleRate).allSatisfy { $0 == 0 })
        tones.insert(data)
    }
    #expect(tones.count == ReminderTone.allCases.count)
}
