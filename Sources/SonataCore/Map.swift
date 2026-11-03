import CoreGraphics
import Foundation

/// The packed 0.5° land bitmap, rasterized from Natural Earth (LandMaskData.swift).
public struct LandMask: Sendable {
    public static let shared = LandMask()
    public static let width = 720, height = 360

    public let bits: [UInt8]

    init() {
        let compact = landMaskBase64.replacingOccurrences(of: "\n", with: "")
        bits = [UInt8](Data(base64Encoded: compact) ?? Data())
    }

    public var isValid: Bool { bits.count == Self.width * Self.height / 8 }

    public static func column(_ lon: Double) -> Int {
        var l = (lon + 180).truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        return min(width - 1, Int(l * 2))
    }

    public static func row(_ lat: Double) -> Int { min(height - 1, max(0, Int((90 - lat) * 2))) }

    public func isLand(row: Int, column: Int) -> Bool {
        let i = row * Self.width + column
        return i >> 3 < bits.count && bits[i >> 3] & (0x80 >> UInt8(i & 7)) != 0
    }

    /// Mask coordinates in cells, measured between cell centers.
    public static func fractionalColumn(_ lon: Double) -> Double {
        var l = (lon + 180).truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        return l * 2 - 0.5
    }

    public static func fractionalRow(_ lat: Double) -> Double { (90 - lat) * 2 - 0.5 }

    /// How much land is at a fractional cell position, 0 … 1: bilinear between the four nearest cells.
    public func land(row: Double, column: Double) -> Double {
        let r0 = Int(row.rounded(.down)), c0 = Int(column.rounded(.down))
        let fr = row - Double(r0), fc = column - Double(c0)
        func bit(_ r: Int, _ c: Int) -> Double {
            let rr = min(max(r, 0), Self.height - 1)
            let cc = ((c % Self.width) + Self.width) % Self.width
            return isLand(row: rr, column: cc) ? 1 : 0
        }
        let top = bit(r0, c0) * (1 - fc) + bit(r0, c0 + 1) * fc
        let bottom = bit(r0 + 1, c0) * (1 - fc) + bit(r0 + 1, c0 + 1) * fc
        return top * (1 - fr) + bottom * fr
    }

    public func isLand(lat: Double, lon: Double) -> Bool { isLand(row: Self.row(lat), column: Self.column(lon)) }
}

/// Equirectangular map framed on a set of places. Wide stretches of empty
/// longitude between them (an ocean between two coasts) are folded into
/// narrow seams so the places get the width. Units are points, y down.
public struct FoldedProjection: Sendable, Equatable {
    /// Squeezes degrees `a ..< b` east of `lon0` into `seam` degrees.
    public struct Fold: Sendable, Equatable {
        public var a, b, seam: Double
    }

    public var lon0: Double
    public var span: Double
    public var latTop: Double
    public var latBottom: Double
    public var folds: [Fold]
    /// Horizontal shrink, cos(mid latitude), so mid-latitude shapes hold.
    public var kx: Double
    /// Degrees per point.
    public var scale: Double
    public var origin: CGPoint

    public static let foldGap = 60.0, foldPad = 15.0, foldSeam = 6.0
    static let latLimits = (-50.0, 74.0)

    public func squeeze(_ d: Double) -> Double {
        var out = d
        for f in folds {
            if d >= f.b {
                out -= f.b - f.a - f.seam
            } else if d > f.a {
                out -= (d - f.a) * (1 - f.seam / (f.b - f.a))
            }
        }
        return out
    }

    func unsqueeze(_ s: Double) -> Double {
        var shift = 0.0
        for f in folds {
            let a = f.a - shift
            if s >= a + f.seam {
                shift += f.b - f.a - f.seam
            } else if s > a {
                return f.a + (s - a) * (f.b - f.a) / f.seam
            } else {
                return s + shift
            }
        }
        return s + shift
    }

    func east(_ lon: Double) -> Double {
        var d = (lon - lon0).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    public func project(lat: Double, lon: Double) -> CGPoint {
        CGPoint(x: origin.x + squeeze(east(lon)) * kx / scale, y: origin.y + (latTop - lat) / scale)
    }

    /// Longitude under a column of points; nil off the map or in a seam.
    public func longitude(atX x: Double) -> Double? {
        let s = (x - origin.x) * scale / kx
        for f in folds {
            let a = squeeze(f.a)
            if s > a && s < a + f.seam { return nil }
        }
        let d = unsqueeze(s)
        guard d >= 0, d <= span else { return nil }
        return lon0 + d
    }

    public func latitude(atY y: Double) -> Double? {
        let lat = latTop - (y - origin.y) * scale
        return lat >= latBottom && lat <= latTop ? lat : nil
    }

    /// Each seam: its x, and how many degrees of longitude it hides.
    public var seams: [(x: Double, degrees: Int)] {
        folds.map { (origin.x + (squeeze($0.a) + $0.seam / 2) * kx / scale, Int(($0.b - $0.a).rounded())) }
    }

    /// The smallest arc of longitude holding every point: (western edge, span).
    static func lonBounds(_ lons: [Double]) -> (west: Double, span: Double) {
        let ls = lons.map { (($0.truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360) - 180 }.sorted()
        guard let first = ls.first, let last = ls.last else { return (-180, 360) }
        var gap = 360 - (last - first), start = first
        for i in 1..<ls.count where ls[i] - ls[i - 1] > gap {
            gap = ls[i] - ls[i - 1]
            start = ls[i]
        }
        return (start, 360 - gap)
    }

    /// The height at which `points` fill `width` exactly, kept within `range`.
    public static func fittingHeight(_ points: [(lat: Double, lon: Double)], width: Double, range: ClosedRange<Double>) -> Double {
        let p = framing(points, size: CGSize(width: width, height: 10_000))
        let used = (p.latTop - p.latBottom) / p.scale
        let natural = used * width / (p.squeeze(p.span) * p.kx / p.scale)
        return min(max(natural, range.lowerBound), range.upperBound)
    }

    /// Frames `points` (lat, lon) in `size`, folding gaps wider than `foldGap`.
    public static func framing(_ points: [(lat: Double, lon: Double)], size: CGSize, fold: Bool = true) -> FoldedProjection {
        let width = max(Double(size.width), 1), height = max(Double(size.height), 1)
        var (west, span) = points.isEmpty ? (-180.0, 360.0) : lonBounds(points.map(\.lon))
        let pad = foldPad
        if span + 2 * pad < 360 {
            west -= pad
            span += 2 * pad
        } else {
            span = 360
        }

        var lo = (points.map(\.lat).min() ?? -45) - 8, hi = (points.map(\.lat).max() ?? 70) + 8
        lo = max(lo, latLimits.0)
        hi = min(hi, latLimits.1)

        var p = FoldedProjection(lon0: west, span: span, latTop: hi, latBottom: lo, folds: [],
                                 kx: max(0.55, cos((lo + hi) / 2 * .pi / 180)), scale: 1, origin: .zero)
        if fold, points.count > 1 {
            let ds = points.map { p.east($0.lon) }.sorted()
            for (a, b) in zip(ds, ds.dropFirst()) where b - a > foldGap {
                let f = Fold(a: a + pad, b: b - pad, seam: foldSeam)
                if f.b - f.a > foldSeam * 2 { p.folds.append(f) }
            }
        }

        // Fit, then spend spare room on more of the world rather than blank margins.
        let contentW = p.squeeze(p.span) * p.kx, contentH = p.latTop - p.latBottom
        p.scale = max(contentW / width, contentH / height)
        let spareLon = (width * p.scale - contentW) / p.kx
        if spareLon > 0.01 {
            let g = max(0, min(spareLon, 360 - p.span))
            p.lon0 -= g / 2
            p.span += g
            p.folds = p.folds.map { Fold(a: $0.a + g / 2, b: $0.b + g / 2, seam: $0.seam) }
        }
        let spareLat = height * p.scale - contentH
        if spareLat > 0.01 {
            let up = min(spareLat / 2, latLimits.1 - p.latTop)
            p.latTop += up
            let down = min(spareLat - up, p.latBottom - latLimits.0)
            p.latBottom -= down
            let rest = spareLat - up - down
            if rest > 0.01 {  // still room: take it above, then center what's left
                let more = min(rest, latLimits.1 - p.latTop)
                p.latTop += more
            }
        }
        let drawnW = p.squeeze(p.span) * p.kx / p.scale
        let drawnH = (p.latTop - p.latBottom) / p.scale
        p.origin = CGPoint(x: (width - drawnW) / 2, y: (height - drawnH) / 2)
        return p
    }
}
