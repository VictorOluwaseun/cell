import AppKit
import SwiftUI
import BatteryCore

@MainActor
final class ReminderAlarmController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var preferences: ReminderAlarmPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences.sanitized) { defaults.set(data, forKey: "reminderAlarm") }
            if !preferences.enabled { dismiss() }
            else if isRinging {
                if oldValue.tone != preferences.tone { playTone() }
                audio?.volume = Float(preferences.sanitized.volume)
                if oldValue.duration != preferences.duration { scheduleStop() }
            }
        }
    }
    @Published private(set) var session = ReminderAlarmSession()
    @Published private(set) var isRinging = false
    @Published private(set) var soundEnabled: Bool
    @Published private(set) var failure: String?
    var readBattery: (@Sendable () async -> BatterySnapshot)?
    private let defaults: UserDefaults
    private var rules: [ChargeAlert] = []
    private var timeRules: [TimedChargeReminder] = []
    private var panel: NSPanel?
    private var audio: NSSound?
    private var sounds: [ReminderTone: NSSound] = [:]
    private var stopTask: Task<Void, Never>?
    private var snoozeTask: Task<Void, Never>?
    private var attention: Int?
    private var testing = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        preferences = defaults.data(forKey: "reminderAlarm").flatMap { try? JSONDecoder().decode(ReminderAlarmPreferences.self, from: $0) }?.sanitized ?? .init()
        soundEnabled = defaults.object(forKey: "alertSound") as? Bool ?? true
        super.init()
    }
    func present(_ message: ReminderAlarmMessage) {
        guard preferences.enabled else { return }
        if testing && message.ruleID != nil { dismiss() }
        let wasEmpty = session.messages.isEmpty
        let previousCount = session.messages.count
        session.enqueue(message)
        guard session.snoozedUntil == nil else { return }
        if wasEmpty { testing = message.ruleID == nil; startRinging() }
        else if session.messages.count > previousCount && !isRinging { startRinging() }
        showPanel()
    }
    func test() {
        // Never replace or dismiss a real reminder while previewing a sound.
        guard session.messages.isEmpty, preferences.enabled else { showPanel(); return }
        present(.init(title: "Test battery alarm", body: "This is how Cell will get your attention. The test sound stops after five seconds."))
    }
    func setSoundEnabled(_ enabled: Bool) {
        guard soundEnabled != enabled else { return }
        soundEnabled = enabled
        if !enabled { stopRinging() }
        else if !session.messages.isEmpty && session.snoozedUntil == nil { startRinging() }
    }
    func dismiss() {
        stopRinging(); snoozeTask?.cancel(); snoozeTask = nil
        session.dismiss(); closePanel()
    }
    func dismiss(id: UUID) {
        session.remove(id: id)
        if session.messages.isEmpty { dismiss() }
    }
    func snooze() {
        guard !session.messages.isEmpty else { return }
        stopRinging(); session.snooze(now: .now); closePanel()
        let deadline = session.snoozedUntil!
        snoozeTask?.cancel()
        snoozeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            let snapshot = await self?.readBattery?()
            guard let self, !Task.isCancelled else { return }
            if let snapshot { self.session.reconcile(snapshot, rules: self.rules, timeRules: self.timeRules) }
            guard self.session.resume(now: max(.now, deadline)) else {
                if self.session.messages.isEmpty { self.dismiss() }
                return
            }
            self.snoozeTask = nil; self.startRinging(); self.showPanel()
        }
    }
    func reveal(id: UUID) {
        guard session.messages.contains(where: { $0.id == id }) else { return }
        showPanel()
        // Explicit Show/notification clicks may focus the window; automatic alarms do not.
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
    func updateRules(_ rules: [ChargeAlert], timeRules: [TimedChargeReminder] = []) {
        let edited = Set(self.timeRules.compactMap { old in
            timeRules.first(where: { $0.id == old.id }).flatMap { old.hasSameConfiguration(as: $0) ? nil : old.id }
        })
        for message in session.messages where message.ruleID.map(edited.contains) == true { session.remove(id: message.id) }
        self.rules = rules
        self.timeRules = timeRules
        session.retainRules(Set(rules.filter(\.enabled).map(\.id) + timeRules.filter(\.enabled).map(\.id)))
        if session.messages.isEmpty { dismiss() }
    }
    func reconcile(_ snapshot: BatterySnapshot, rules: [ChargeAlert], timeRules: [TimedChargeReminder] = []) {
        self.rules = rules
        self.timeRules = timeRules
        guard !session.messages.isEmpty else { return }
        session.reconcile(snapshot, rules: rules, timeRules: timeRules)
        if session.messages.isEmpty { dismiss() }
    }
    private func startRinging() {
        failure = nil
        if soundEnabled { playTone(); scheduleStop() }
        if attention == nil { attention = NSApp.requestUserAttention(.criticalRequest) }
    }
    private func playTone() {
        audio?.stop()
        let tone = preferences.tone
        if sounds[tone] == nil { sounds[tone] = NSSound(data: ReminderAlarmAudio.wav(tone: tone)) }
        audio = sounds[tone]; audio?.loops = true; audio?.volume = Float(preferences.sanitized.volume)
        isRinging = audio?.play() == true
        if !isRinging { failure = "Cell could not start audio playback. Check your sound output device, then try Test alarm." }
    }
    private func scheduleStop() {
        stopTask?.cancel(); stopTask = nil
        let seconds = testing ? 5 : preferences.duration.rawValue
        guard seconds > 0, isRinging else { return }
        stopTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.stopRinging()
        }
    }
    private func stopRinging() {
        stopTask?.cancel(); stopTask = nil; audio?.stop(); audio = nil; isRinging = false
        if let attention { NSApp.cancelUserAttentionRequest(attention); self.attention = nil }
    }
    private func showPanel() {
        guard !session.messages.isEmpty else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Cell battery alarm"; window.isReleasedWhenClosed = false
            window.level = .floating; window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.appearance = NSAppearance(named: .darkAqua); window.delegate = self
            window.contentView = NSHostingView(rootView: ReminderAlarmView(controller: self))
            window.center(); panel = window
        }
        panel?.orderFrontRegardless()
    }
    private func closePanel() {
        let window = panel; panel = nil
        window?.delegate = nil; window?.close(); window?.contentView = nil
    }
    func windowWillClose(_ notification: Notification) {
        let window = panel; panel = nil
        stopRinging(); snoozeTask?.cancel(); snoozeTask = nil; session.dismiss()
        window?.contentView = nil
    }
}

private struct ReminderAlarmView: View {
    @ObservedObject var controller: ReminderAlarmController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: controller.isRinging ? "bell.badge.fill" : "bell.fill")
                    .font(.system(size: 26)).foregroundStyle(Palette.violet)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Battery alarm").font(.system(size: 21, weight: .semibold))
                    Text(status).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(controller.session.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.title).font(.system(size: 15, weight: .semibold))
                            Text(message.body).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let failure = controller.failure { Text(failure).font(.system(size: 12)).foregroundStyle(Palette.amber) }
                }
            }
            HStack {
                Button("Snooze 5 minutes") { controller.snooze() }.buttonStyle(.bordered)
                Spacer()
                Button("Stop alarm") { controller.dismiss() }.buttonStyle(.borderedProminent).tint(Palette.violet)
            }
            Text("Uses your current output device and system volume.").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(26).frame(width: 460, height: 340)
            .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
    }
    private var status: String {
        if let until = controller.session.snoozedUntil { return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))" }
        if !controller.soundEnabled { return "Sound is turned off in Cell settings" }
        return controller.isRinging ? "Ringing · stop or snooze when you’re ready" : "Sound stopped · reminder stays until dismissed"
    }
}
