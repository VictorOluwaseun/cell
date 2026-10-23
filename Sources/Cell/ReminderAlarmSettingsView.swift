import SwiftUI
import BatteryCore

struct ReminderAlarmSettingsView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var controller: ReminderAlarmController
    var body: some View {
        Panel("A reminder you can hear", subtitle: "Cell can show its own alarm window and play a repeating tone while your Mac is awake.") {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cell alarm").font(.system(size: 13, weight: .medium))
                    Text("Adds a visible window and repeating sound to percentage and time reminders.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Toggle("Cell alarm", isOn: $controller.preferences.enabled).labelsHidden().toggleStyle(.switch)
            }
            if controller.preferences.enabled {
                HStack(spacing: 18) {
                    Toggle("Play sound", isOn: $monitor.sound).toggleStyle(.switch)
                    Spacer()
                    Picker("Tone", selection: $controller.preferences.tone) {
                        ForEach(ReminderTone.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 165)
                    Picker("Ring for", selection: $controller.preferences.duration) {
                        ForEach(ReminderRingDuration.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 195)
                }.font(.system(size: 12))
                HStack(spacing: 12) {
                    Label("Alarm volume", systemImage: "speaker.wave.2.fill").font(.system(size: 12))
                    Slider(value: $controller.preferences.volume, in: 0.1...1, step: 0.05)
                        .accessibilityLabel("Alarm volume").disabled(!monitor.sound)
                    Text("\(Int((controller.preferences.volume * 100).rounded()))%")
                        .font(.system(size: 12)).monospacedDigit().frame(width: 42)
                    Button("Test alarm") { controller.test() }.buttonStyle(.borderedProminent)
                        .disabled(!controller.session.messages.isEmpty)
                        .help("Shows the alarm and rings for five seconds when Play sound is enabled")
                }
                if !monitor.sound {
                    Text("Play sound is off. The alarm window will appear silently; turn sound on to hear it.")
                        .font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
                ActiveReminderAlarmControls(controller: controller)
                Text("Stop dismisses the alarm; Snooze brings it back in 5 minutes if the reminder still applies. Test alarm rings for 5 seconds. Audio uses your current output device and system volume, so a muted Mac or headphones can keep you from hearing it. The window stays until dismissed, even after the sound finishes.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
            if let failure = controller.failure { Text(failure).font(.system(size: 12)).foregroundStyle(Palette.amber) }
        }
    }
}

struct ActiveReminderAlarmControls: View {
    @ObservedObject var controller: ReminderAlarmController
    var body: some View {
        if !controller.session.messages.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.session.snoozedUntil.map { "Alarm snoozed until \($0.formatted(date: .omitted, time: .shortened))" }
                     ?? (controller.isRinging ? "Battery alarm is ringing" : "Battery reminder awaiting dismissal"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.amber)
                HStack {
                    Button("Show alarm") { if let id = controller.session.messages.first?.id { controller.reveal(id: id) } }
                    Button("Snooze 5 minutes") { controller.snooze() }
                    Button("Stop alarm") { controller.dismiss() }
                }.buttonStyle(.bordered)
            }
        }
    }
}
