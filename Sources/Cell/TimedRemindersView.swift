import SwiftUI
import BatteryCore

struct TimedRemindersView: View {
    @ObservedObject var controller: TimedReminderController
    @State private var action: ChargingReminderAction = .plugIn
    @State private var repetition: ReminderRepeat = .daily
    @State private var date = Date.now.addingTimeInterval(3_600)
    @State private var onlyIfNeeded = true
    private var selectedMinute: Date { Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date }
    private var invalidDate: Bool { repetition == .once && selectedMinute <= .now }
    var body: some View {
        VStack(spacing: 20) {
            Panel("Time reminders", subtitle: "Remind yourself to plug in or unplug at a time you choose.") {
                if controller.reminders.isEmpty {
                    EmptyMessage(icon: "clock.badge", title: "Make charging part of your routine",
                        detail: "For example, plug in at 9:00 AM on weekdays or unplug at 6:00 PM every day.")
                }
                ForEach(controller.reminders) { rule in
                    TimedReminderRow(rule: rule, controller: controller)
                }
            }
            Panel("Add a time reminder") {
                HStack(spacing: 16) {
                    Picker("Remind me to", selection: $action) {
                        ForEach(ChargingReminderAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 195)
                    DatePicker("At", selection: $date, displayedComponents: repetition == .once ? [.date, .hourAndMinute] : [.hourAndMinute])
                    Spacer(minLength: 0)
                    Picker("Repeat", selection: $repetition) {
                        ForEach(ReminderRepeat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 190)
                }.font(.system(size: 12))
                HStack {
                    Toggle(action == .plugIn ? "Skip if already connected to power" : "Skip if already unplugged", isOn: $onlyIfNeeded)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    Spacer()
                    Button("Add time reminder") {
                        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                        controller.add(.init(action: action, hour: components.hour ?? 9, minute: components.minute ?? 0,
                            repetition: repetition, onceDate: repetition == .once ? selectedMinute : nil, onlyIfNeeded: onlyIfNeeded))
                    }.buttonStyle(.borderedProminent)
                        .disabled(invalidDate || controller.reminders.count >= TimedReminderController.maximumReminders)
                }
                if invalidDate { Text("Choose a future date and time for a one-time reminder.").font(.system(size: 11)).foregroundStyle(Palette.amber) }
                if let error = controller.error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber) }
                Text("Daily and weekday reminders follow your Mac’s local clock. Weekdays means Monday–Friday. Cell must be running; after sleep or a restart, reminders up to 15 minutes late are checked, and older ones are skipped. A reminder does not change charging automatically.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }
    }
}

private struct TimedReminderRow: View {
    var rule: TimedChargeReminder
    @ObservedObject var controller: TimedReminderController
    private var pickerDate: Date {
        if let date = rule.onceDate, rule.repetition == .once { return date }
        return Calendar.current.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: .now) ?? .now
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 15) {
                Image(systemName: rule.action == .plugIn ? "powerplug.fill" : "powerplug")
                    .font(.system(size: 21)).foregroundStyle(rule.action == .plugIn ? Palette.amber : Palette.mint)
                    .frame(width: 42, height: 45).background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(rule.action.reminderTitle).font(.system(size: 14, weight: .medium))
                    Text(description).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DatePicker("Time for \(rule.action.title) reminder", selection: Binding(get: { pickerDate }, set: updateDate),
                    displayedComponents: rule.repetition == .once ? [.date, .hourAndMinute] : [.hourAndMinute])
                    .labelsHidden().fixedSize()
                Toggle("Enable \(rule.action.title) time reminder", isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch)
                Button(role: .destructive) { controller.remove(rule.id) } label: { Image(systemName: "trash").padding(8) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Delete \(rule.action.title) time reminder")
            }
            Toggle("Skip if the action is already done", isOn: binding(\.onlyIfNeeded))
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.leading, 57)
        }.padding(.vertical, 7)
    }
    private var description: String {
        guard rule.enabled, controller.enabled else { return "\(rule.repetition.title) · Paused" }
        guard let next = controller.nextDates[rule.id] else { return "\(rule.repetition.title) · Finished" }
        return "\(rule.repetition.title) · Next \(next.formatted(date: .abbreviated, time: .shortened))"
    }
    private func binding(_ key: WritableKeyPath<TimedChargeReminder, Bool>) -> Binding<Bool> {
        Binding(get: { rule[keyPath: key] }, set: { value in var copy = rule; copy[keyPath: key] = value; controller.update(copy) })
    }
    private func updateDate(_ value: Date) {
        var copy = rule
        let components = Calendar.current.dateComponents([.hour, .minute], from: value)
        copy.hour = components.hour ?? rule.hour; copy.minute = components.minute ?? rule.minute
        if copy.repetition == .once { copy.onceDate = Calendar.current.dateInterval(of: .minute, for: value)?.start ?? value }
        controller.update(copy)
    }
}

struct ChargeReminderCount: View {
    var percentageCount: Int
    @ObservedObject var controller: TimedReminderController
    var body: some View {
        let count = percentageCount + controller.nextDates.count
        if count > 0 {
            Text("\(count)").font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.08), in: Capsule())
        }
    }
}
