import SwiftUI

struct ApplicationQuitButton: View {
    var app: AppActivity
    @ObservedObject var controller: ApplicationQuitController
    var confirm: () -> Void
    var body: some View {
        Group {
            if let target = app.quitTarget {
                let pending = controller.pending.contains(target)
                if pending {
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text("Quitting…").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("Waiting for \(app.name) to quit")
                } else {
                    Button("Quit…", action: confirm)
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Quit \(app.name)")
                        .help("Ask \(app.name) to quit normally")
                }
            } else {
                Text("—").foregroundStyle(Palette.muted)
                    .accessibilityLabel("Quit unavailable for \(app.name)")
                    .help("Quit is available for running apps. Processes and system services are shown for information.")
            }
        }.frame(width: 82, alignment: .trailing)
    }
}

struct ApplicationQuitStatus: View {
    @ObservedObject var controller: ApplicationQuitController
    var body: some View {
        if let message = controller.message {
            HStack(spacing: 12) {
                Label(message, systemImage: controller.failed ? "exclamationmark.triangle" : "info.circle")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { controller.dismissMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss quit status")
            }.foregroundStyle(controller.failed ? Palette.amber : Palette.mint).padding(14)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
