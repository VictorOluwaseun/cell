import SwiftUI

struct StartupSettingsView: View {
    @ObservedObject var controller: StartupController
    var body: some View {
        Panel("Startup") {
            HStack(spacing: 25) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open at login").font(.system(size: 13, weight: .medium))
                    Text(controller.detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if controller.busy { ProgressView().controlSize(.small) }
                Toggle("Open at login", isOn: Binding(get: { controller.registered }, set: { enabled in
                    Task { await controller.setEnabled(enabled) }
                })).labelsHidden().toggleStyle(.switch).disabled(controller.busy)
            }.padding(.vertical, 4)
            HStack(spacing: 14) {
                if controller.needsApproval {
                    Label("Waiting for macOS approval", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(Palette.amber)
                }
                Spacer()
                Button(controller.needsApproval ? "Allow Cell in Login Items…" : "Login Items settings…") {
                    controller.openSettings()
                }.buttonStyle(.bordered)
            }
            Text("Keep Cell in Applications before enabling startup so macOS can launch your installed copy. This opens Cell after sign-in; the charging helper is managed separately.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11))
                    .foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { controller.refresh() }
    }
}
