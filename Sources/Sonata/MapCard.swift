import SonataCore
import SwiftUI

/// What the map draws: every leader location, the leaders now and next,
/// and the ones just before. Equatable, so the map redraws only when the
/// leader changes or locations arrive, never on a slot tick.
struct MapInput: Equatable {
    struct Place: Equatable {
        var id: String
        var lat, lon: Double
        var share: Double
        var city: String
    }

    struct Stop: Equatable {
        var identity: String
        var name: String
        var lat, lon: Double
    }

    var places: [Place] = []
    /// The current leader, then the next ones.
    var route: [Stop] = []
    var trail: [Stop] = []
    /// The pinned validator.
    var you: Stop?
}

/// Where the map looks: magnified `zoom` times about `focus`, a point of
/// the unmagnified map given as fractions of its width and height.
struct MapCamera: Equatable {
    var focus = CGPoint(x: 0.5, y: 0.5)
    var zoom = 1.0

    static let leaderZoom = 9.0

    /// The magnified map always covers the view: never moved past its edges.
    func transform(in size: CGSize) -> (zoom: Double, offset: CGPoint) {
        let z = max(zoom, 1)
        let x = size.width / 2 - focus.x * size.width * z, y = size.height / 2 - focus.y * size.height * z
        return (z, CGPoint(x: min(0, max(size.width - size.width * z, x)), y: min(0, max(size.height - size.height * z, y))))
    }
}

/// The map laid out in a view: sites (places merged where their marks
/// would collide), arcs and labels, in points.
struct MapScene {
    struct Site {
        var point: CGPoint
        var share: Double
        var title: String
    }

    struct Arc {
        var start, control, end: CGPoint

        init(_ a: CGPoint, _ b: CGPoint) {
            start = a
            end = b
            let d = hypot(b.x - a.x, b.y - a.y)
            control = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - d * 0.28)
        }

        func point(at t: Double) -> CGPoint {
            let m = 1 - t
            return CGPoint(x: m * m * start.x + 2 * m * t * control.x + t * t * end.x,
                           y: m * m * start.y + 2 * m * t * control.y + t * t * end.y)
        }
    }

    struct Label {
        var text: String
        var rect: CGRect
        var strong: Bool
        var color: Color
    }

    var size: CGSize
    var projection: FoldedProjection
    var zoom = 1.0
    var offset = CGPoint.zero
    var sites: [Site] = []
    var maxShare = 1.0
    var route: [CGPoint] = []
    var trail: [CGPoint] = []
    var you: CGPoint?
    var labels: [Label] = []

    static let markRadius = 3.2

    /// The unmagnified map: every place, folded only when seen whole.
    static func base(_ input: MapInput, size: CGSize, fold: Bool) -> FoldedProjection {
        FoldedProjection.framing(input.places.map { ($0.lat, $0.lon) }, size: size, fold: fold)
    }

    @MainActor init(_ input: MapInput, size: CGSize, p: Palette, camera: MapCamera = MapCamera()) {
        self.size = size
        projection = Self.base(input, size: size, fold: camera.zoom <= 1.01)
        (zoom, offset) = camera.transform(in: size)
        let (zoom, offset, projection) = (zoom, offset, projection)
        func project(_ lat: Double, _ lon: Double) -> CGPoint {
            let q = projection.project(lat: lat, lon: lon)
            return CGPoint(x: q.x * zoom + offset.x, y: q.y * zoom + offset.y)
        }

        // Biggest first, so a merged site keeps the biggest place's name.
        for place in input.places.sorted(by: { $0.share > $1.share }) {
            let pt = project(place.lat, place.lon)
            if let i = sites.firstIndex(where: { abs($0.point.x - pt.x) < 7 && abs($0.point.y - pt.y) < 6 }) {
                sites[i].share += place.share
            } else {
                sites.append(Site(point: pt, share: place.share, title: place.city))
            }
        }
        maxShare = sites.map(\.share).max() ?? 1
        route = input.route.map { project($0.lat, $0.lon) }
        trail = input.trail.map { project($0.lat, $0.lon) }
        you = input.you.map { project($0.lat, $0.lon) }
        labels = Self.placeLabels(input: input, route: route, you: you, sites: sites, size: size, p: p)
    }

    func radius(_ s: Site) -> Double { (2 + 2.6 * sqrt(s.share / maxShare)) * (zoom > 1.01 ? 1.25 : 1) }

    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    /// Each seam's x on screen.
    var seams: [(x: Double, degrees: Int)] { projection.seams.map { ($0.x * zoom + offset.x, $0.degrees) } }

    /// The longitude under a screen column, the latitude under a row.
    func longitude(atX x: Double) -> Double? { projection.longitude(atX: (x - offset.x) / zoom) }
    func latitude(atY y: Double) -> Double? { projection.latitude(atY: (y - offset.y) / zoom) }

    /// Leaders first, then the biggest places by name, each beside its mark
    /// where it overlaps no other label, mark or edge.
    @MainActor static func placeLabels(input: MapInput, route: [CGPoint], you: CGPoint?, sites: [Site], size: CGSize, p: Palette) -> [Label] {
        struct Want { var text: String; var at: CGPoint; var strong: Bool; var color: Color; var gap: Double }
        var wants: [Want] = []
        for (i, stop) in input.route.prefix(3).enumerated() {
            let name = stop.name.count > 18 ? String(stop.name.prefix(17)) + "…" : stop.name
            wants.append(Want(text: name, at: route[i], strong: i == 0, color: i == 0 ? p.l1 : p.l2, gap: i == 0 ? 14 : 10))
        }
        if let you {
            wants.insert(Want(text: "You", at: you, strong: true, color: p.accent2, gap: 10), at: min(1, wants.count))
        }
        for site in sites.filter({ CGRect(origin: .zero, size: size).contains($0.point) }).prefix(12) where !site.title.isEmpty {
            wants.append(Want(text: site.title, at: site.point, strong: false, color: p.l3, gap: 5))
        }
        var placed: [Label] = []
        let marks = sites.map(\.point) + route
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 2)
        var spots: [CGPoint] = []
        for want in wants {
            // Leaders sharing a place: the first one names it.
            if want.strong || want.gap >= 6 {
                if spots.contains(where: { hypot($0.x - want.at.x, $0.y - want.at.y) < 6 }) { continue }
                spots.append(want.at)
            }
            let font = NSFont.systemFont(ofSize: 10, weight: want.strong ? .semibold : .medium)
            let w = ceil((want.text as NSString).size(withAttributes: [.font: font]).width), h = 13.0
            let a = want.at, g = want.gap
            let candidates = [
                CGRect(x: a.x + g, y: a.y - h / 2, width: w, height: h),
                CGRect(x: a.x - g - w, y: a.y - h / 2, width: w, height: h),
                CGRect(x: a.x - w / 2, y: a.y - g - h, width: w, height: h),
                CGRect(x: a.x - w / 2, y: a.y + g, width: w, height: h),
            ]
            let fits = candidates.first { r in
                bounds.contains(r)
                    && !placed.contains { $0.rect.insetBy(dx: -3, dy: -1).intersects(r) }
                    && !marks.contains { m in hypot(m.x - a.x, m.y - a.y) > 1 && r.insetBy(dx: -2, dy: -1).contains(m) }
            }
            if let rect = fits ?? (want.strong ? candidates.first(where: bounds.contains) : nil) {
                placed.append(Label(text: want.text, rect: rect, strong: want.strong, color: want.color))
            }
        }
        return placed
    }
}

// MARK: The live map

/// The map, following the leader: 3× on the current one, easing to each new
/// leader as it takes over. Shared by the panel's card and the desktop widget.
struct LiveMap: View {
    var input: MapInput
    let model: SonataModel
    var p: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = MapCamera()

    var body: some View {
        GeometryReader { geo in
            let target = camera(in: geo.size)
            MapViewport(input: input, model: model, p: p, camera: target)
                .animation(animation(from: settled, to: target), value: target)
                .onChange(of: target) { _, new in settled = new }
        }
        .clipped()
    }

    /// Leaders hand over every ~0.9s (4 slots of ~215ms): the camera has to arrive within one window.
    /// A short hop glides; a long jump (an ocean away) is a quick move that reads as a cut, so
    /// the map never lingers over empty sea.
    func animation(from a: MapCamera, to b: MapCamera) -> Animation? {
        guard !reduceMotion else { return nil }
        let jump = hypot(b.focus.x - a.focus.x, b.focus.y - a.focus.y) * b.zoom
        return jump > 1.1 ? .easeOut(duration: 0.18) : .smooth(duration: 0.45)
    }

    /// On the current leader, or the whole map while there's none.
    func camera(in size: CGSize) -> MapCamera {
        guard let now = input.route.first, size.width > 0, size.height > 0 else { return MapCamera() }
        let base = MapScene.base(input, size: size, fold: false)
        let q = base.project(lat: now.lat, lon: now.lon)
        return MapCamera(focus: CGPoint(x: q.x / size.width, y: q.y / size.height), zoom: MapCamera.leaderZoom)
    }
}

/// The map at one camera position: SwiftUI interpolates the camera between
/// leaders and the scene is laid out again for each step of the move.
private struct MapViewport: View, @MainActor Animatable {
    var input: MapInput
    let model: SonataModel
    var p: Palette
    var camera: MapCamera

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(camera.focus.x, camera.focus.y), camera.zoom) }
        set { camera = MapCamera(focus: CGPoint(x: newValue.first.first, y: newValue.first.second), zoom: newValue.second) }
    }

    var body: some View {
        GeometryReader { geo in
            let scene = MapScene(input, size: geo.size, p: p, camera: camera)
            ZStack {
                // Each in its own GPU layer: the beacon's pulse redraws itself, never the land.
                MapCanvas(scene: scene, p: p).drawingGroup()
                if let current = input.route.first {
                    Beacon(scene: scene, identity: current.identity, model: model, p: p).drawingGroup()
                }
                // Leaders wear their icons: the next ones small, the current one in its ring.
                ForEach(Array(zip(input.route, scene.route).enumerated().reversed()), id: \.element.0.identity) { i, pair in
                    if i < 3, scene.bounds.insetBy(dx: -8, dy: -8).contains(pair.1) {
                        ValidatorAvatar(model: model, identity: pair.0.identity, size: i == 0 ? 17 : 12, circle: true)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                            .position(pair.1)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

// MARK: The card

struct MapCard: View {
    var input: MapInput
    var located: Int
    var total: Int
    var p: Palette
    let model: SonataModel

    static let height = 168.0

    var body: some View {
        Card(p: p) {
            CardTitle(symbol: "map", title: "Map", meta: input.places.isEmpty ? "" : "\(input.places.count) places", p: p)
            LiveMap(input: input, model: model, p: p)
                .frame(height: Self.height)
                .padding(.horizontal, -11)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility)
            HStack(spacing: 6) {
                if total > 0, located < total {
                    Text("\(total - located) without a location")
                } else if total > 0 {
                    Text("\(total) leaders")
                }
                Spacer(minLength: 4)
                Text("located by IP")
            }
            .font(.ui(10.5)).foregroundStyle(p.l3).lineLimit(1)
            .padding(.top, 7)
        }
    }

    private var accessibility: String {
        var parts = ["Map", "\(input.places.count) places"]
        if let now = input.route.first { parts.append("leading: \(now.name)") }
        return parts.joined(separator: ", ")
    }
}

/// Land, seams, arcs, places and labels: redrawn only with its scene.
private struct MapCanvas: View {
    var scene: MapScene
    var p: Palette

    var body: some View {
        Canvas { ctx, size in draw(ctx, size: size) }
    }

    func draw(_ ctx: GraphicsContext, size: CGSize) {
        let clear = scene.labels.map { $0.rect.insetBy(dx: -2, dy: -1) }
        drawLand(ctx, size: size, clear: clear)
        drawSeams(ctx, size: size)

        // The trail behind, faint; the way ahead, dashed; the next hop, solid.
        let trail = [scene.route.first].compactMap { $0 } + scene.trail
        for (i, (a, b)) in zip(trail, trail.dropFirst()).enumerated() {
            stroke(ctx, MapScene.Arc(b, a), color: p.l3.opacity(0.7 - Double(i) * 0.1), width: 0.9, dash: [1.6, 2.4])
        }
        let route = scene.route
        for (i, (a, b)) in zip(route, route.dropFirst()).enumerated() where i > 0 {
            stroke(ctx, MapScene.Arc(a, b), color: p.accent2.opacity(0.75 - Double(i) * 0.15), width: 1, dash: [3, 2.6])
        }
        if route.count > 1 {
            stroke(ctx, MapScene.Arc(route[0], route[1]), color: p.accent.opacity(0.8), width: 1.4, dash: [])
        }

        // Each place: a dot sized by its share of slots, in a quiet ring.
        for site in scene.sites {
            let r = scene.radius(site), c = site.point
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 2.5, y: c.y - r - 2.5, width: 2 * r + 5, height: 2 * r + 5)),
                       with: .color(p.accent.opacity(0.22)), lineWidth: 0.75)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(p.accent.opacity(0.85)))
        }
        // The pinned validator: a violet diamond around its place.
        if let c = scene.you {
            var d = Path()
            d.move(to: CGPoint(x: c.x, y: c.y - 8))
            d.addLine(to: CGPoint(x: c.x + 8, y: c.y))
            d.addLine(to: CGPoint(x: c.x, y: c.y + 8))
            d.addLine(to: CGPoint(x: c.x - 8, y: c.y))
            d.closeSubpath()
            ctx.stroke(d, with: .color(p.accent2), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
        // The next leaders, in violet.
        for c in route.dropFirst().prefix(3) {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(p.accent2), lineWidth: 1.25)
        }

        // The next leader off the view: a violet chevron at the edge, toward it.
        if route.count > 1, !scene.bounds.insetBy(dx: 4, dy: 4).contains(route[1]) {
            drawOffView(ctx, from: route[0], to: route[1], color: p.accent2)
        }

        for label in scene.labels {
            let text = ctx.resolve(Text(label.text).font(.ui(10, label.strong ? .semibold : .medium)).foregroundStyle(label.color))
            ctx.draw(text, in: label.rect)
        }
    }

    func drawOffView(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color) {
        let inner = scene.bounds.insetBy(dx: 10, dy: 10)
        // Where the straight line from the leader toward the next one leaves the view.
        var t = 1.0
        if b.x > inner.maxX { t = min(t, (inner.maxX - a.x) / (b.x - a.x)) }
        if b.x < inner.minX { t = min(t, (inner.minX - a.x) / (b.x - a.x)) }
        if b.y > inner.maxY { t = min(t, (inner.maxY - a.y) / (b.y - a.y)) }
        if b.y < inner.minY { t = min(t, (inner.minY - a.y) / (b.y - a.y)) }
        let pin = CGPoint(x: a.x + (b.x - a.x) * max(0, t), y: a.y + (b.y - a.y) * max(0, t))
        let angle = atan2(b.y - a.y, b.x - a.x)
        var chevron = Path()
        let tip = CGPoint(x: pin.x + cos(angle) * 5, y: pin.y + sin(angle) * 5)
        chevron.move(to: CGPoint(x: tip.x - cos(angle - 0.6) * 5, y: tip.y - sin(angle - 0.6) * 5))
        chevron.addLine(to: tip)
        chevron.addLine(to: CGPoint(x: tip.x - cos(angle + 0.6) * 5, y: tip.y - sin(angle + 0.6) * 5))
        ctx.stroke(chevron, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    func stroke(_ ctx: GraphicsContext, _ arc: MapScene.Arc, color: Color, width: Double, dash: [CGFloat]) {
        let r = 6.0
        var pts: [CGPoint] = []
        for k in 0...40 {
            let q = arc.point(at: Double(k) / 40)
            let fromStart: Double = hypot(q.x - arc.start.x, q.y - arc.start.y)
            let fromEnd: Double = hypot(q.x - arc.end.x, q.y - arc.end.y)
            if fromStart >= r && fromEnd >= r { pts.append(q) }
        }
        guard pts.count > 1 else { return }
        var path = Path()
        path.addLines(pts)
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    /// The land as a matrix of fine dots, ordered-dithered where it meets
    /// the sea so coasts fray instead of stepping; brighter near places,
    /// fading toward the edges, kept clear of marks and labels.
    func drawLand(_ ctx: GraphicsContext, size: CGSize, clear: [CGRect]) {
        let pitch = 2.6, dot = 1.3
        guard LandMask.shared.isValid, size.width > 0, size.height > 0 else { return }
        // The lattice is pinned to the magnified map, not the screen: as the camera pans the dots
        // travel with the land (no shimmer), and each dot's coverage is computed once and cached.
        let off = scene.offset
        let i0 = Int(((-off.x) / pitch).rounded(.down)), i1 = Int(((size.width - off.x) / pitch).rounded(.up))
        let j0 = Int(((-off.y) / pitch).rounded(.down)), j1 = Int(((size.height - off.y) / pitch).rounded(.up))
        let coverage = LandCoverageCache.shared.lattice(for: scene, pitch: pitch)

        // Places near the view brighten its land: bucketed, so each dot checks only its neighbours.
        let bucket = 56.0
        var buckets: [Int: [CGPoint]] = [:]
        let near = scene.bounds.insetBy(dx: -bucket, dy: -bucket)
        for s in scene.sites.map(\.point) + scene.route where near.contains(s) {
            buckets[Int((s.x / bucket).rounded(.down)) &* 4_096 &+ Int((s.y / bucket).rounded(.down)), default: []].append(s)
        }
        let levels = 8
        var paths = Array(repeating: Path(), count: levels)
        for j in j0...j1 {
            for i in i0...i1 {
                let cover = coverage.value(i, j)
                guard cover > 0.01, cover >= Self.bayer(i, j) else { continue }
                let c = CGPoint(x: (Double(i) + 0.5) * pitch + off.x, y: (Double(j) + 0.5) * pitch + off.y)
                guard c.x > 0, c.x < size.width, c.y > 0, c.y < size.height else { continue }
                var nearest = Double.infinity
                let bx = Int((c.x / bucket).rounded(.down)), by = Int((c.y / bucket).rounded(.down))
                for dx in -1...1 {
                    for dy in -1...1 {
                        for s in buckets[(bx + dx) &* 4_096 &+ (by + dy)] ?? [] { nearest = min(nearest, hypot(s.x - c.x, s.y - c.y)) }
                    }
                }
                guard nearest > 5.5, !clear.contains(where: { $0.contains(c) }) else { continue }
                let edge = min(c.x, size.width - c.x, c.y, size.height - c.y)
                let glow = nearest.isFinite ? exp(-nearest / 56) : 0
                let a = Self.smoothstep(0, 14, edge) * (0.42 + 0.58 * glow)
                let level = min(levels - 1, Int(a * Double(levels)))
                guard level > 0 else { continue }
                let d = dot * (0.8 + 0.2 * cover + 0.25 * glow)
                paths[level].addEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            }
        }
        let ink: Color = p.isDark ? .white : .black
        let strength = p.isDark ? 0.34 : 0.24
        for (k, path) in paths.enumerated() where !path.isEmpty {
            ctx.fill(path, with: .color(ink.opacity(min(1, strength * (Double(k) + 0.5) / Double(levels) * 1.5))))
        }
    }


    /// A fold's seam: a dotted rule headed by the degrees it hides, so it's never taken for a coast.
    func drawSeams(_ ctx: GraphicsContext, size: CGSize) {
        for seam in scene.seams where seam.x > 0 && seam.x < size.width {
            var dots = Path()
            var y = 18.0
            while y < size.height - 4 {
                dots.addEllipse(in: CGRect(x: seam.x - 0.5, y: y, width: 1, height: 1))
                y += 3
            }
            ctx.fill(dots, with: .color(p.l3.opacity(0.6)))
            let label = ctx.resolve(Text(verbatim: "\(seam.degrees)°").font(.ui(8.5, .medium)).foregroundStyle(p.l3))
            let w = label.measure(in: CGSize(width: 100, height: 20))
            guard seam.x - w.width / 2 >= 2, seam.x + w.width / 2 <= size.width - 2 else { continue }
            ctx.draw(label, in: CGRect(x: seam.x - w.width / 2, y: 3, width: w.width, height: w.height))
        }
    }

    static let bayer8: [[Double]] = {
        let b = [[0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26], [12, 44, 4, 36, 14, 46, 6, 38],
                 [60, 28, 52, 20, 62, 30, 54, 22], [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
                 [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]]
        return b.map { $0.map { (Double($0) + 0.5) / 64 } }
    }()

    static func bayer(_ i: Int, _ j: Int) -> Double { bayer8[j & 7][i & 7] }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}

/// The current leader, animated on its own small layer: a ring filling as
/// its slots pass, a pulse, and the baton riding the arc to the next leader.
private struct Beacon: View {
    var scene: MapScene
    var identity: String
    let model: SonataModel
    var p: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let window = model.upcomingWindows.first
            let slot = model.estimatedSlot(at: timeline.date)
            let progress: Double = {
                guard let window, let slot, window.identity == identity else { return 0 }
                return min(max((slot - Double(window.firstSlot)) / Double(window.slotCount), 0), 1)
            }()
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                guard let c = scene.route.first else { return }
                if !reduceMotion {
                    let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let r = 11 + 12 * phase
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(p.accent.opacity(0.55 * (1 - phase))), lineWidth: 1)
                }
                // Track and progress.
                let ring = CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)
                ctx.stroke(Path(ellipseIn: ring), with: .color(p.accent.opacity(0.25)), lineWidth: 1.6)
                var arc = Path()
                arc.addArc(center: c, radius: 11, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress), clockwise: false)
                ctx.stroke(arc, with: .color(p.accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.4, y: c.y - 3.4, width: 6.8, height: 6.8)), with: .color(p.accent))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.white))

                if scene.route.count > 1, progress > 0 {
                    let head = MapScene.Arc(c, scene.route[1]).point(at: progress)
                    var glow = ctx
                    glow.addFilter(.blur(radius: 2.5))
                    glow.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)), with: .color(p.accent.opacity(0.8)))
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - 1.6, y: head.y - 1.6, width: 3.2, height: 3.2)), with: .color(.white))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Land coverage per lattice dot, for one projection, size and zoom: computed the first time a
/// dot is drawn, then looked up, so a panning camera costs lookups instead of mask sampling.
@MainActor
final class LandCoverageCache {
    static let shared = LandCoverageCache()

    struct Key: Hashable {
        var projection: String
        var zoom: Int
    }

    final class Lattice {
        let scene: MapScene
        let pitch: Double
        private var values: [Int: Float] = [:]

        init(scene: MapScene, pitch: Double) {
            self.scene = scene
            self.pitch = pitch
        }

        /// Fraction of land under dot (i, j), from 3×3 subsamples with bilinear mask lookups.
        func value(_ i: Int, _ j: Int) -> Double {
            let key = j &* 1_000_003 &+ i
            if let v = values[key] { return Double(v) }
            let mask = LandMask.shared
            var hits = 0.0, n = 0
            for sy in 0..<3 {
                let y = (Double(j) + (Double(sy) + 0.5) / 3) * pitch / scene.zoom
                guard let lat = scene.projection.latitude(atY: y) else { continue }
                for sx in 0..<3 {
                    let x = (Double(i) + (Double(sx) + 0.5) / 3) * pitch / scene.zoom
                    guard let lon = scene.projection.longitude(atX: x) else { continue }
                    hits += mask.land(row: LandMask.fractionalRow(lat), column: LandMask.fractionalColumn(lon))
                    n += 1
                }
            }
            let v = n == 0 ? 0 : hits / Double(n)
            values[key] = Float(v)
            return v
        }
    }

    private var lattices: [Key: Lattice] = [:]

    func lattice(for scene: MapScene, pitch: Double) -> Lattice {
        // Zoom animations pass through fractional zooms: those get a lattice of their own, briefly.
        let key = Key(projection: "\(scene.projection)", zoom: Int((scene.zoom * 100).rounded()))
        if let hit = lattices[key] { return hit }
        if lattices.count > 6 { lattices.removeAll() }
        let lattice = Lattice(scene: scene, pitch: pitch)
        lattices[key] = lattice
        return lattice
    }
}
