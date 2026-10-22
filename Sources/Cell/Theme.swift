import SwiftUI

enum Palette {
    static let background = Color(hex: 0x191B26)
    static let sidebar = Color(hex: 0x14151E)
    static let panel = Color(hex: 0x212330)
    static let line = Color(hex: 0x343646)
    static let text = Color(hex: 0xF0F0F7)
    static let muted = Color(hex: 0xA4A6BA)
    static let violet = Color(hex: 0xB5A2FF)
    static let mint = Color(hex: 0x79DDBB)
    static let blue = Color(hex: 0x8DBBFF)
    static let amber = Color(hex: 0xF1C078)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct Panel<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let title {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                }
            }
            content
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.035)))
    }
}

struct MetricTile: View {
    var icon: String
    var title: String
    var value: String
    var detail: String
    var tint: Color = Palette.violet
    var body: some View {
        Panel {
            HStack {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                    .frame(height: 28, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct DetailRow: View {
    var title: String
    var value: String
    var color: Color = Palette.text
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Palette.muted)
            Spacer(minLength: 16)
            Text(value).foregroundStyle(color).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.system(size: 12))
    }
}

enum Display {
    static func number(_ value: Double?, digits: Int = 1, unit: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits))) + unit
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct EmptyMessage: View {
    var icon: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(Palette.violet)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}
