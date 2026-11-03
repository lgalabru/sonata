import AppKit
import SonataCore
import SwiftUI

/// The map as a desktop widget: a glass card on the desktop, beneath every
/// window like macOS's own widgets, but live: it follows each leader.
/// WidgetKit widgets refresh on a budget of minutes, too slow for leaders
/// that change every 1.6s, so this is a desktop-level window instead.
@MainActor
final class DesktopWidgetController {
    private let model: SonataModel
    private let watch: ValidatorWatch
    private var window: NSWindow?

    static let defaultsKey = "desktopMap"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    init(model: SonataModel, watch: ValidatorWatch) {
        self.model = model
        self.watch = watch
    }

    /// Shows or hides the widget to match the setting.
    func sync() {
        if Self.isEnabled { show() } else { hide() }
    }

    private func show() {
        if window == nil { window = makeWindow() }
        if window?.isVisible == false { window?.orderFrontRegardless() }
    }

    private func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let size = DesktopMapWidget.size
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        // Just above the desktop's icons, below every app window.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DesktopMapWidget(model: model, watch: watch, remove: {
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        }))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.cornerCurve = .continuous
        host.layer?.cornerRadius = DesktopMapWidget.radius
        host.layer?.masksToBounds = true
        w.contentView = host
        if !w.setFrameUsingName("SonataDesktopMap") {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            w.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
        }
        w.setFrameAutosaveName("SonataDesktopMap")
        return w
    }
}

/// The widget's face: who leads, the live map, and who's next.
struct DesktopMapWidget: View {
    let model: SonataModel
    let watch: ValidatorWatch
    var remove: () -> Void
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 364, height: 268)
    static let radius = 22.0

    var body: some View {
        let p = Palette.resolve(scheme)
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(model: model, p: p)
            LiveMap(input: mapInput, model: model, p: p)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            WidgetFooter(model: model, watch: watch, p: p)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background { WidgetBackground(p: p) }
        .contextMenu {
            Button("Remove from Desktop", action: remove)
        }
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
        if let first = upcoming.first, stop(first) != nil { input.route = upcoming.compactMap(stop) }
        input.trail = model.recentWindows.prefix(4).compactMap(stop)
        if let id = watch.identity, let g = model.pin(id).location {
            input.you = MapInput.Stop(identity: id, name: model.pin(id).displayName, lat: g.lat, lon: g.lon)
        }
        return input
    }
}

private struct WidgetBackground: View {
    var p: Palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesktopMapWidget.radius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular.tint(p.panelTint), in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.fill(p.panelTint))
        }
    }
}

private struct WidgetHeader: View {
    let model: SonataModel
    var p: Palette

    var body: some View {
        HStack(spacing: 7) {
            SolanaMark().fill(SolanaMark.gradient).frame(width: 14, height: 12)
            if let w = model.upcomingWindows.first {
                let pin = model.pin(w.identity)
                ValidatorAvatar(model: model, identity: w.identity, size: 18, circle: true)
                Text(pin.displayName).font(.ui(13, .semibold)).foregroundStyle(p.l1).lineLimit(1)
                Spacer(minLength: 6)
                SlotPipsLive(model: model, window: w, p: p)
            } else {
                Text("Connecting…").font(.ui(13, .medium)).foregroundStyle(p.l3)
                Spacer()
            }
        }
    }
}

/// The current window's slots, filling as they're produced.
private struct SlotPipsLive: View {
    let model: SonataModel
    let window: LeaderWindow
    var p: Palette

    var body: some View {
        let now = model.tickSlot ?? window.firstSlot
        HStack(spacing: 3) {
            ForEach(0..<Int(min(window.slotCount, 8)), id: \.self) { i in
                let slot = window.firstSlot + UInt64(i)
                Capsule().fill(slot < now ? p.accent : slot == now ? p.accent.opacity(0.5) : p.fill).frame(width: 12, height: 4)
            }
        }
    }
}

private struct WidgetFooter: View {
    let model: SonataModel
    let watch: ValidatorWatch
    var p: Palette

    var body: some View {
        let now = model.tickSlot ?? 0
        HStack(spacing: 6) {
            if let next = model.upcomingWindows.dropFirst().first {
                let pin = model.pin(next.identity)
                Text("Next").foregroundStyle(p.l3)
                ValidatorAvatar(model: model, identity: next.identity, size: 14, circle: true)
                Text(pin.displayName).foregroundStyle(p.l2).lineLimit(1)
                Text(eta(next.firstSlot, now)).foregroundStyle(p.accent2).fontWeight(.semibold)
                    .contentTransition(.numericText(countsDown: true))
            }
            Spacer(minLength: 6)
            if watch.currentWindow != nil {
                Text("You're leading").foregroundStyle(p.accent).fontWeight(.semibold)
            } else if let mine = watch.nextWindow {
                Text("You in").foregroundStyle(p.l3)
                Text(timer(model.seconds(until: mine.firstSlot))).foregroundStyle(p.accent2).fontWeight(.semibold)
            }
        }
        .font(.mono(11))
        .lineLimit(1)
    }

    private func eta(_ first: UInt64, _ now: UInt64) -> String {
        let t = Double(first > now ? first - now : 0) * model.slotDuration
        if t < 60 { return t.formatted(.number.precision(.fractionLength(1))) + "s" }
        let s = Int(t)
        return s >= 3_600 ? String(format: "%dh %02dm", s / 3_600, s % 3_600 / 60) : String(format: "%dm %02ds", s / 60, s % 60)
    }
}
