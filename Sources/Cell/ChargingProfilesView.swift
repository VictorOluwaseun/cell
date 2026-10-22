import SwiftUI
import BatteryCore

struct ChargingProfilesView: View {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var controller: InsightsController
    @ObservedObject var chargeLimit: ChargeLimitController
    @State private var editing: ChargeProfile?
    @State private var deleting: UUID?
    var body: some View {
        Panel("Charging profiles", subtitle: "Apply a limit and profile reminders together. Other reminders stay saved.") {
            ForEach(controller.profiles) { profile in
                HStack(spacing: 12) {
                    Image(systemName: profile.name == "Travel" ? "airplane" : "square.stack").font(.system(size: 19)).foregroundStyle(Palette.violet).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(profile.name).font(.system(size: 14, weight: .medium))
                            if controller.selectedProfile == profile.id, chargeLimit.enabled,
                               chargeLimit.status?.configuration.percentage == profile.limit {
                                Text(chargeLimit.status?.override == true ? "Bypassed this time" : "In use")
                                    .font(.system(size: 10)).foregroundStyle(Palette.mint)
                            }
                        }
                        Text("\(profile.limit)% limit\(profile.lowReminder.map { " • low reminder \($0)%" } ?? "")\(profile.highReminder.map { " • charge reminder \($0)%" } ?? "")")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button("Apply") { Task { await controller.apply(profile, controller: chargeLimit, monitor: monitor) } }
                        .buttonStyle(.bordered).disabled(chargeLimit.busy || chargeLimit.status?.supported != true)
                    Button { editing = profile } label: { Image(systemName: "pencil") }.buttonStyle(.plain).padding(6).accessibilityLabel("Edit \(profile.name) profile")
                    Button { deleting = profile.id } label: { Image(systemName: "trash") }.buttonStyle(.plain).padding(6).foregroundStyle(Palette.muted).accessibilityLabel("Delete \(profile.name) profile")
                }.padding(.vertical, 8)
            }
            HStack {
                Button { editing = ChargeProfile(name: "Custom", limit: 80) } label: { Label("New profile", systemImage: "plus") }
                    .buttonStyle(.bordered).disabled(controller.profiles.count >= 20)
                Spacer()
                if chargeLimit.status?.supported != true {
                    Text("Install a supported charging helper to apply profiles.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, otherNames: controller.profiles.filter { $0.id != profile.id }.map(\.name)) { saved in
                if let index = controller.profiles.firstIndex(where: { $0.id == saved.id }) { controller.profiles[index] = saved }
                else { controller.profiles.append(saved) }
            }
        }
        .confirmationDialog("Delete this saved profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete profile", role: .destructive) {
                controller.profiles.removeAll { $0.id == deleting }; deleting = nil
            }
        } message: { Text("Deleting a profile does not disable the currently configured charging limit or delete existing reminders.") }
    }
}

private struct ProfileEditor: View {
    @State var profile: ChargeProfile
    var otherNames: [String]
    var save: (ChargeProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool { profile.isValid && !otherNames.contains { $0.localizedCaseInsensitiveCompare(profile.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Charging profile").font(.system(size: 22, weight: .semibold))
            Form {
                TextField("Name", text: $profile.name)
                Stepper("Charging limit: \(profile.limit)%", value: $profile.limit, in: 20...100)
                Toggle("Low-battery reminder", isOn: Binding(get: { profile.lowReminder != nil }, set: { profile.lowReminder = $0 ? 20 : nil }))
                if profile.lowReminder != nil {
                    Stepper("Remind at \(profile.lowReminder ?? 20)%", value: Binding(get: { profile.lowReminder ?? 20 }, set: { profile.lowReminder = $0 }), in: 1...100)
                }
                Toggle("Charge reminder", isOn: Binding(get: { profile.highReminder != nil }, set: { profile.highReminder = $0 ? profile.limit : nil }))
                if profile.highReminder != nil {
                    Stepper("Remind at \(profile.highReminder ?? 80)%", value: Binding(get: { profile.highReminder ?? 80 }, set: { profile.highReminder = $0 }), in: 1...100)
                }
            }.formStyle(.grouped)
            Text("Saving a profile does not apply it. Profile notifications use Cell’s existing notification permission.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                if !valid { Text("Choose a unique name up to 40 characters.").font(.caption).foregroundStyle(Palette.amber) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save profile") {
                    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(profile); dismiss()
                }.buttonStyle(.borderedProminent).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }.padding(25).frame(width: 520).background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
    }
}
