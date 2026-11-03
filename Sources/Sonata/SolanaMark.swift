import AppKit
import SwiftUI

/// The Solana mark (from pay-web-ui's solana-logo.svg), as a SwiftUI shape and a menu bar template image.
struct SolanaMark: Shape {
    static let viewBox = CGSize(width: 101, height: 88)
    static let pathData = "M100.48 69.3817L83.8068 86.8015C83.4444 87.1799 83.0058 87.4816 82.5185 87.6878C82.0312 87.894 81.5055 88.0003 80.9743 88H1.93563C1.55849 88 1.18957 87.8926 0.874202 87.6912C0.558829 87.4897 0.31074 87.2029 0.160416 86.8659C0.0100923 86.529 -0.0359181 86.1566 0.0280382 85.7945C0.0919944 85.4324 0.263131 85.0964 0.520422 84.8278L17.2061 67.408C17.5676 67.0306 18.0047 66.7295 18.4904 66.5234C18.9762 66.3172 19.5002 66.2104 20.0301 66.2095H99.0644C99.4415 66.2095 99.8104 66.3169 100.126 66.5183C100.441 66.7198 100.689 67.0067 100.84 67.3436C100.99 67.6806 101.036 68.0529 100.972 68.415C100.908 68.7771 100.737 69.1131 100.48 69.3817ZM83.8068 34.3032C83.4444 33.9248 83.0058 33.6231 82.5185 33.4169C82.0312 33.2108 81.5055 33.1045 80.9743 33.1048H1.93563C1.55849 33.1048 1.18957 33.2121 0.874202 33.4136C0.558829 33.6151 0.31074 33.9019 0.160416 34.2388C0.0100923 34.5758 -0.0359181 34.9482 0.0280382 35.3103C0.0919944 35.6723 0.263131 36.0083 0.520422 36.277L17.2061 53.6968C17.5676 54.0742 18.0047 54.3752 18.4904 54.5814C18.9762 54.7875 19.5002 54.8944 20.0301 54.8952H99.0644C99.4415 54.8952 99.8104 54.7879 100.126 54.5864C100.441 54.3849 100.689 54.0981 100.84 53.7612C100.99 53.4242 101.036 53.0518 100.972 52.6897C100.908 52.3277 100.737 51.9917 100.48 51.723L83.8068 34.3032ZM1.93563 21.7905H80.9743C81.5055 21.7907 82.0312 21.6845 82.5185 21.4783C83.0058 21.2721 83.4444 20.9704 83.8068 20.592L100.48 3.17219C100.737 2.90357 100.908 2.56758 100.972 2.2055C101.036 1.84342 100.99 1.47103 100.84 1.13408C100.689 0.79713 100.441 0.510296 100.126 0.308823C99.8104 0.107349 99.4415 1.24074e-05 99.0644 0L20.0301 0C19.5002 0.000878397 18.9762 0.107699 18.4904 0.313848C18.0047 0.519998 17.5676 0.821087 17.2061 1.19848L0.524723 18.6183C0.267681 18.8866 0.0966198 19.2223 0.0325185 19.5839C-0.0315829 19.9456 0.0140624 20.3177 0.163856 20.6545C0.31365 20.9913 0.561081 21.2781 0.875804 21.4799C1.19053 21.6817 1.55886 21.7896 1.93563 21.7905Z"

    /// Parsed once: absolute M, L, H, V, C and Z, which is all the logo uses.
    static let unitPath: Path = parse(pathData)

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / Self.viewBox.width, rect.height / Self.viewBox.height)
        let w = Self.viewBox.width * s, h = Self.viewBox.height * s
        return Self.unitPath.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: rect.minX + (rect.width - w) / 2,
                                                        ty: rect.minY + (rect.height - h) / 2))
    }

    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens: [String] = []
        let pattern = try! NSRegularExpression(pattern: "[MLHVCZmlhvcz]|-?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?")
        for m in pattern.matches(in: d, range: NSRange(d.startIndex..., in: d)) {
            tokens.append(String(d[Range(m.range, in: d)!]))
        }
        var i = 0, command = "M"
        var current = CGPoint.zero
        func number() -> Double { defer { i += 1 }; return Double(tokens[i]) ?? 0 }
        func isNumber(_ t: String) -> Bool { Double(t) != nil }
        while i < tokens.count {
            if !isNumber(tokens[i]) { command = tokens[i]; i += 1 }
            switch command {
            case "M":
                current = CGPoint(x: number(), y: number()); path.move(to: current); command = "L"
            case "L":
                current = CGPoint(x: number(), y: number()); path.addLine(to: current)
            case "H":
                current.x = number(); path.addLine(to: current)
            case "V":
                current.y = number(); path.addLine(to: current)
            case "C":
                let c1 = CGPoint(x: number(), y: number()), c2 = CGPoint(x: number(), y: number())
                current = CGPoint(x: number(), y: number())
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Z", "z":
                path.closeSubpath()
                if i < tokens.count, isNumber(tokens[i]) { command = "L" }
            default:
                i += 1
            }
        }
        return path
    }

    /// Solana's purple-to-mint gradient.
    static let gradient = LinearGradient(colors: [Color(red: 0.6, green: 0.27, blue: 1), Color(red: 0.08, green: 0.95, blue: 0.58)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing)

    /// A template image for the status item, `height` points tall.
    @MainActor static func templateImage(height: Double) -> NSImage {
        let size = NSSize(width: (height * viewBox.width / viewBox.height).rounded(.up), height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(SolanaMark().path(in: rect).cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sonata"
        return image
    }
}
