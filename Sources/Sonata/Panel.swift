import SonataCore
import SwiftUI

struct PanelActions {
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

/// The panel: cards on glass, as topophany-bar's Native look.
/// The root reads only what changes per leader; slot ticks are read by the
/// small views that show them.
struct PanelRoot: View {
    let model: SonataModel
    let watch: ValidatorWatch
    var actions = PanelActions()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    static let width = 344.0

    var body: some View {
        let p = Palette.resolve(scheme, increaseContrast: contrast == .increased)
        VStack(spacing: 6) {
            Header(model: model, p: p)
            if watch.isPinned { ValidatorCard(model: model, watch: watch, p: p) }
            LeaderCard(model: model, p: p)
            MapCard(input: mapInput, located: model.locatedCount, total: model.pins.count, p: p, model: model).equatable()
            UpNextCard(model: model, you: watch.identity, p: p)
            EpochCard(model: model, p: p)
            Footer(model: model, p: p, actions: actions)
        }
        .padding(8)
        .frame(width: Self.width)
        .background { PanelBackground(p: p) }
    }

    private var mapInput: MapInput {
        func stop(_ w: LeaderWindow) -> MapInput.Stop? {
            let pin = model.pin(w.identity)
            guard let g = pin.location else { return nil }
            return MapInput.Stop(identity: w.identity, name: pin.displayName, lat: g.lat, lon: g.lon)
        }
        var input = MapInput()
        input.places = model.clusters.map { MapInput.Place(id: $0.id, lat: $0.lat, lon: $0.lon, share: $0.share, city: $0.city ?? "") }
        let upcoming = Array(model.upcomingWindows.prefix(4))
        // The route starts at the current leader: if it can't be placed, there's no route.
        if let first = upcoming.first, stop(first) != nil { input.route = upcoming.compactMap(stop) }
        input.trail = model.recentWindows.prefix(4).compactMap(stop)
        if let id = watch.identity, let g = model.pin(id).location {
            input.you = MapInput.Stop(identity: id, name: model.pin(id).displayName, lat: g.lat, lon: g.lon)
        }
        return input
    }
}

extension MapCard: Equatable {
    nonisolated static func == (a: MapCard, b: MapCard) -> Bool {
        MainActor.assumeIsolated { a.input == b.input && a.located == b.located && a.total == b.total && a.p == b.p }
    }
}

/// What the panel sits on: Liquid Glass where there is, the popover's material before.
struct PanelBackground: View {
    var p: Palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Palette.panelRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular.tint(p.panelTint), in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.fill(p.panelTint))
        }
    }
}

// MARK: Header

private struct Header: View {
    let model: SonataModel
    var p: Palette

    var body: some View {
        HStack(spacing: 7) {
            SolanaMark().fill(SolanaMark.gradient).frame(width: 15, height: 13)
            Spacer(minLength: 6)
            if let epoch = model.epoch {
                Text("Epoch \(epoch.epoch.formatted(.number.grouping(.never)))").font(.ui(11, .medium)).foregroundStyle(p.l3)
            }
        }
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 1)
    }
}

// MARK: Leader

private struct LeaderCard: View {
    let model: SonataModel
    var p: Palette

    var body: some View {
        Card(p: p) {
            if let window = model.upcomingWindows.first {
                let pin = model.pin(window.identity)
                CardTitle(symbol: "crown", title: "Leading now",
                          meta: pin.share > 0 ? pin.share.formatted(.percent.precision(.fractionLength(2))) + " of slots" : "", p: p)
                HStack(spacing: 10) {
                    ValidatorAvatar(model: model, identity: window.identity, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pin.displayName).font(.ui(14, .semibold)).foregroundStyle(p.l1).lineLimit(1)
                            .help(window.identity)
                        Text(subtitle(pin)).font(.ui(11)).foregroundStyle(p.l2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                SlotMeter(model: model, window: window, p: p).padding(.top, 9)
            } else {
                CardTitle(symbol: "crown", title: "Leading now", p: p)
                HStack(spacing: 8) {
                    if case .failed = model.phase {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.warn)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(waiting).font(.ui(12)).foregroundStyle(p.l2).lineLimit(2)
                }
                .frame(minHeight: 34)
            }
        }
    }

    private func subtitle(_ pin: ValidatorPin) -> String {
        var parts: [String] = []
        if let place = pin.location?.place, !place.isEmpty { parts.append(place) } else { parts.append("Unknown location") }
        if let version = pin.version { parts.append("v" + version) }
        return parts.joined(separator: " · ")
    }

    private var waiting: String {
        switch model.phase {
        case .failed(let why): why
        case .loading(let what): what + "…"
        default: "Connecting to the cluster…"
        }
    }
}

/// The window's slots as segments, lit as they're produced.
private struct SlotMeter: View {
    let model: SonataModel
    let window: LeaderWindow
    var p: Palette

    var body: some View {
        let now = model.tickSlot ?? window.firstSlot
        let n = Int(min(window.slotCount, 12))
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<n, id: \.self) { i in
                    let slot = window.firstSlot + UInt64(i)
                    Capsule()
                        .fill(slot < now ? p.accent : slot == now ? p.accent.opacity(0.5) : p.fill)
                        .frame(height: 4)
                }
            }
            Text("slot \(now.formatted(.number.grouping(.never)))")
                .font(.mono(10.5, .medium)).foregroundStyle(p.l3)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: now)
        }
    }
}

// MARK: Up next

private struct UpNextCard: View {
    let model: SonataModel
    var you: String?
    var p: Palette

    var body: some View {
        let windows = Array(model.upcomingWindows.dropFirst().prefix(4))
        Card(p: p) {
            CardTitle(symbol: "forward", title: "Up next", meta: windows.isEmpty ? "" : "\(windows.count)", p: p)
            if windows.isEmpty {
                Text("Waiting for the schedule").font(.ui(11.5)).foregroundStyle(p.l3).padding(.vertical, 4)
            }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 { Rectangle().fill(p.sep).frame(height: 0.5).padding(.leading, 30) }
                NextRow(model: model, window: window, isYou: window.identity == you, p: p)
            }
        }
    }
}

private struct NextRow: View {
    let model: SonataModel
    let window: LeaderWindow
    var isYou = false
    var p: Palette

    var body: some View {
        let pin = model.pin(window.identity)
        HStack(spacing: 9) {
            ValidatorAvatar(model: model, identity: window.identity, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(pin.displayName).font(.ui(12.5, .semibold)).foregroundStyle(p.l1).lineLimit(1)
                    if isYou {
                        Text("YOU").font(.ui(8.5, .bold)).tracking(0.6).foregroundStyle(p.accent2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(p.accent2.opacity(0.16)))
                    }
                }
                Text(subtitle(pin)).font(.ui(11)).foregroundStyle(p.l2).lineLimit(1)
            }
            Spacer(minLength: 6)
            ETA(model: model, first: window.firstSlot, p: p)
        }
        .padding(.vertical, 4.5)
        .help(window.identity)
    }

    private func subtitle(_ pin: ValidatorPin) -> String {
        var parts = [pin.location?.city ?? "Unknown location"]
        if pin.share > 0 { parts.append(pin.share.formatted(.percent.precision(.fractionLength(2)))) }
        if window.slotCount != 4 { parts.append("\(window.slotCount) slots") }
        return parts.joined(separator: " · ")
    }
}

/// Seconds until a slot, ticking down.
private struct ETA: View {
    let model: SonataModel
    let first: UInt64
    var p: Palette

    var body: some View {
        let now = model.tickSlot ?? first
        let seconds = Double(first > now ? first - now : 0) * model.slotDuration
        Text(seconds < 0.05 ? "NOW" : seconds.formatted(.number.precision(.fractionLength(1))) + "s")
            .font(.mono(11, .bold)).tracking(0.6)
            .foregroundStyle(p.accent2)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy(duration: 0.2), value: now)
    }
}

// MARK: Epoch

private struct EpochCard: View {
    let model: SonataModel
    var p: Palette

    var body: some View {
        Card(p: p) {
            if let epoch = model.epoch {
                let slot = max(model.tickSlot ?? epoch.absoluteSlot, epoch.firstSlot)
                let progress = min(Double(slot - epoch.firstSlot) / Double(max(epoch.slotsInEpoch, 1)), 1)
                CardTitle(symbol: "clock", title: "Epoch \(epoch.epoch.formatted(.number.grouping(.never)))",
                          meta: progress.formatted(.percent.precision(.fractionLength(1))), p: p)
                TickMeter(value: progress, p: p).frame(height: 7)
                HStack {
                    Text(remaining(epoch, slot)).foregroundStyle(p.l2)
                    Spacer()
                    Text("\(model.book.schedules.count > 1 ? "next schedule ready" : "schedule cached")").foregroundStyle(p.l3)
                }
                .font(.ui(11)).padding(.top, 7)
            } else {
                CardTitle(symbol: "clock", title: "Epoch", p: p)
                TickMeter(value: 0, p: p).frame(height: 7).redacted(reason: .placeholder)
            }
        }
    }

    private func remaining(_ epoch: EpochInfo, _ slot: UInt64) -> String {
        let end = epoch.firstSlot + epoch.slotsInEpoch
        let seconds = Double(end > slot ? end - slot : 0) * model.slotDuration
        let h = Int(seconds) / 3600, m = Int(seconds) % 3600 / 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }
}

// MARK: Footer

private struct Footer: View {
    let model: SonataModel
    var p: Palette
    var actions: PanelActions

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(status).font(.ui(11.5, .medium)).foregroundStyle(p.l2).lineLimit(1)
            Spacer(minLength: 6)
            Chip(title: nil, symbol: "gearshape", p: p, action: actions.openSettings).help("Settings…")
            Chip(title: "Quit", symbol: nil, p: p, action: actions.quit)
        }
        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 3)
    }

    private var cluster: String { SonataModel.clusterName(for: model.rpcURL) }

    private var status: String {
        switch model.phase {
        case .live: "Connected · \(cluster)"
        case .stale(let why): why
        case .failed(let why): why
        case .loading, .starting: "Connecting · \(cluster)"
        }
    }

    private var dot: Color {
        switch model.phase {
        case .live: p.accent
        case .stale: p.warn
        case .failed: p.down
        default: p.l3
        }
    }
}
