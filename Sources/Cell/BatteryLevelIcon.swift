import SwiftUI

/// The fill represents the measured charge, independently of charging state.
/// Vector drawing keeps small menu-bar icons sharp without animation or timers.
struct BatteryLevelIcon: View {
    var level: Double
    var charging: Bool
    var available = true
    private var hasReading: Bool { available && level.isFinite }
    private var fraction: Double { hasReading ? min(100, max(0, level)) / 100 : 0 }
    private var description: String {
        guard hasReading else { return "Battery level unavailable" }
        return "Battery \(Int((fraction * 100).rounded())) percent\(charging ? ", charging" : "")"
    }
    var body: some View {
        HStack(spacing: 2) {
            Canvas { context, _ in
                let outline = CGRect(x: 0.75, y: 1.25, width: 21, height: 10.5)
                context.stroke(Path(roundedRect: outline, cornerRadius: 2.25), with: .foreground, lineWidth: 1.25)
                context.fill(Path(roundedRect: CGRect(x: 23, y: 4.25, width: 1.5, height: 4.5), cornerRadius: 0.75), with: .foreground)
                if hasReading {
                    let fill = CGRect(x: 2.5, y: 3, width: 17.5 * fraction, height: 7)
                    context.fill(Path(roundedRect: fill, cornerRadius: min(1, fill.width / 2)), with: .foreground)
                } else {
                    context.stroke(Path { path in
                        path.move(to: CGPoint(x: 8, y: 6.5)); path.addLine(to: CGPoint(x: 14.5, y: 6.5))
                    }, with: .foreground, lineWidth: 1.25)
                }
            }.frame(width: 25, height: 13)
            if charging && hasReading {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .semibold)).frame(width: 7, height: 13)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .help(description)
    }
}
