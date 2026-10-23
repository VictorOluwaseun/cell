import Foundation

public enum ReminderTone: String, CaseIterable, Codable, Sendable {
    case chime, bell, pulse
    public var title: String { rawValue.capitalized }
}

public enum ReminderRingDuration: Int, CaseIterable, Codable, Sendable {
    case thirtySeconds = 30, oneMinute = 60, untilStopped = 0
    public var title: String {
        switch self {
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .untilStopped: "Until stopped"
        }
    }
}

public struct ReminderAlarmPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var volume = 0.75
    public var tone = ReminderTone.chime
    public var duration = ReminderRingDuration.oneMinute
    public init() {}
    public var sanitized: Self {
        var value = self
        value.volume = volume.isFinite ? min(1, max(0.1, volume)) : 0.75
        return value
    }
}

public struct ReminderAlarmMessage: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var ruleID: UUID?
    public var title: String
    public var body: String
    public init(id: UUID = UUID(), ruleID: UUID? = nil, title: String, body: String) {
        self.id = id; self.ruleID = ruleID; self.title = title; self.body = body
    }
}

/// One shared alarm for simultaneous thresholds. A snooze defers new reminders too.
public struct ReminderAlarmSession: Equatable, Sendable {
    public private(set) var messages: [ReminderAlarmMessage] = []
    public private(set) var snoozedUntil: Date?
    public init() {}
    public mutating func enqueue(_ message: ReminderAlarmMessage) {
        guard !messages.contains(where: { $0.id == message.id || (message.ruleID != nil && $0.ruleID == message.ruleID) }) else { return }
        messages.append(message)
    }
    public mutating func snooze(now: Date) {
        guard !messages.isEmpty else { return }
        snoozedUntil = now.addingTimeInterval(300)
    }
    public mutating func resume(now: Date) -> Bool {
        guard let deadline = snoozedUntil, now >= deadline, !messages.isEmpty else { return false }
        snoozedUntil = nil; return true
    }
    public mutating func remove(id: UUID) { messages.removeAll { $0.id == id }; if messages.isEmpty { snoozedUntil = nil } }
    public mutating func retainRules(_ active: Set<UUID>) {
        messages.removeAll { $0.ruleID.map { !active.contains($0) } ?? false }
        if messages.isEmpty { snoozedUntil = nil }
    }
    public mutating func reconcile(_ snapshot: BatterySnapshot, rules: [ChargeAlert], timeRules: [TimedChargeReminder] = []) {
        guard snapshot.state != .unavailable else { return }
        let relevant = rules.filter { rule in
            rule.enabled && (rule.direction == .below
                ? snapshot.state == .discharging && snapshot.level <= Double(rule.threshold)
                : snapshot.state.onAC && snapshot.level >= Double(rule.threshold))
        }
        let timed = timeRules.filter { $0.enabled && (!$0.onlyIfNeeded || !$0.action.isSatisfied(by: snapshot)) }
        retainRules(Set(relevant.map(\.id) + timed.map(\.id)))
    }
    public mutating func dismiss() { messages.removeAll(); snoozedUntil = nil }
}

/// A short PCM phrase rendered once per selected tone, then looped by the audio API.
/// No polling, external sound files, network services or system-volume changes.
public enum ReminderAlarmAudio {
    public static let sampleRate = 24_000
    public static let seconds = 3
    public static func wav(tone: ReminderTone) -> Data {
        let count = sampleRate * seconds
        var data = Data(capacity: 44 + count * 2)
        func word(_ number: UInt16) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func integer(_ number: UInt32) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); integer(UInt32(36 + count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        integer(16); word(1); word(1); integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2))
        word(2); word(16); data.append(contentsOf: "data".utf8); integer(UInt32(count * 2))
        let frequencies: [Double] = switch tone {
        case .chime: [880, 1_108.73, 1_318.51]
        case .bell: [660, 660]
        case .pulse: [880, 660, 880, 660]
        }
        let spacing = tone == .bell ? 0.65 : 0.32
        let length = tone == .bell ? 0.6 : 0.27
        for frame in 0..<count {
            let time = Double(frame) / Double(sampleRate)
            var sample = 0.0
            for (index, frequency) in frequencies.enumerated() {
                let local = time - Double(index) * spacing
                guard local >= 0, local < length else { continue }
                let envelope = min(1, local / 0.012) * min(1, (length - local) / 0.04) * exp(-local * 2.5)
                sample += envelope * (0.48 * sin(2 * .pi * frequency * local) + 0.12 * sin(4 * .pi * frequency * local))
            }
            word(UInt16(bitPattern: Int16((max(-0.95, min(0.95, sample)) * Double(Int16.max)).rounded())))
        }
        return data
    }
}
