import SwiftUI

/// The panel's colors: label tiers and fills as the system's, cards a
/// whisper lighter than the glass, and Solana's mint and violet as accents.
struct Palette: Equatable {
    var isDark: Bool
    var l1, l2, l3: Color
    var sep: Color
    var card, cardEdge: Color
    var fill, fill2: Color
    var panelTint: Color
    var accent: Color   // Solana mint: leaders, live
    var accent2: Color  // Solana violet: what's next
    var warn, down: Color

    static func resolve(_ scheme: ColorScheme, increaseContrast hc: Bool = false) -> Palette {
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
        if scheme == .dark {
            return Palette(isDark: true,
                           l1: Color(white: 1, opacity: 0.92),
                           l2: rgb(235, 235, 245, hc ? 0.8 : 0.62),
                           l3: rgb(235, 235, 245, hc ? 0.62 : 0.36),
                           sep: Color(white: 1, opacity: hc ? 0.22 : 0.08),
                           card: Color(white: 1, opacity: 0.068), cardEdge: Color(white: 1, opacity: hc ? 0.3 : 0.05),
                           fill: rgb(120, 120, 128, 0.36), fill2: rgb(120, 120, 128, 0.2),
                           panelTint: rgb(32, 32, 38, 0.55),
                           accent: rgb(25, 251, 155), accent2: rgb(171, 109, 255),
                           warn: .orange, down: .red)
        }
        return Palette(isDark: false,
                       l1: Color(white: 0, opacity: 0.86),
                       l2: rgb(60, 60, 67, hc ? 0.85 : 0.68),
                       l3: rgb(60, 60, 67, hc ? 0.66 : 0.4),
                       sep: Color(white: 0, opacity: hc ? 0.2 : 0.07),
                       card: Color(white: 1, opacity: 0.64), cardEdge: Color(white: 0, opacity: hc ? 0.25 : 0.035),
                       fill: rgb(120, 120, 128, 0.2), fill2: rgb(120, 120, 128, 0.1),
                       panelTint: rgb(250, 250, 253, 0.6),
                       accent: rgb(8, 158, 100), accent2: rgb(124, 63, 228),
                       warn: .orange, down: .red)
    }

    static let panelRadius = 18.0
    static let cardRadius = 13.0
}

extension Font {
    static func ui(_ size: Double, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: Double, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// A section: a rounded card on the panel's glass.
struct Card<Content: View>: View {
    var p: Palette
    var padding = EdgeInsets(top: 8, leading: 11, bottom: 9, trailing: 11)
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Palette.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(p.card))
            .overlay(shape.strokeBorder(p.cardEdge, lineWidth: 0.5))
    }
}

/// A card's heading: its symbol and title, and what it counts at the right.
struct CardTitle: View {
    var symbol: String
    var title: String
    var meta = ""
    var p: Palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).frame(width: 14)
            Text(title).font(.ui(11.5, .semibold))
            Spacer(minLength: 6)
            if !meta.isEmpty { Text(meta).font(.ui(11, .medium)).foregroundStyle(p.l3).lineLimit(1) }
        }
        .foregroundStyle(p.l2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A pill-shaped button, like the footer's Quit.
struct Chip: View {
    var title: String?
    var symbol: String?
    var p: Palette
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                if let title { Text(title).font(.ui(11.5, .medium)) }
            }
            .foregroundStyle(p.l1)
            .padding(.horizontal, title == nil ? 7 : 10).padding(.vertical, 4)
            .background(Capsule().fill(p.fill2))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Fine graduated ticks, lit up to `value` (0 … 1), as topophany's meters.
struct TickMeter: View {
    var value: Double
    var p: Palette
    var color: Color?

    var body: some View {
        Canvas { ctx, s in
            let tick = 1.3, gap = 1.25
            let n = max(1, Int((s.width + gap) / (tick + gap)))
            let pitch = (s.width + gap) / Double(n)
            let w = pitch - gap
            var lit = Path(), track = Path()
            for i in 0..<n {
                let r = CGRect(x: Double(i) * pitch, y: 0, width: w, height: s.height)
                let path = Path(roundedRect: r, cornerRadius: min(0.6, w / 2))
                if (Double(i) + 0.5) / Double(n) < value { lit.addPath(path) } else { track.addPath(path) }
            }
            ctx.fill(track, with: .color(p.fill))
            ctx.fill(lit, with: .color(color ?? p.accent))
        }
    }
}

/// The squircle tile a card leads with, as macOS draws an app's.
struct Tile<Content: View>: View {
    var size = 34.0
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 12 / 44, style: .continuous)
        content
            .frame(width: size, height: size)
            .background(shape.fill(tint.opacity(0.16)))
            .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}
