import AppKit
import SonataCore
import SwiftUI

@main
@MainActor
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        SettingsMigration.run()  // before anything reads a setting
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SonataModel()
    lazy var watch = ValidatorWatch(model: model)
    lazy var conductor = Conductor(model: model)
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var settings: NSWindowController?
    private var desktop: DesktopWidgetController?
    private var notifier: TenureNotifier?
    private var debugWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        watch.start()
        _ = conductor
        let actions = PanelActions(openSettings: { [weak self] in self?.openSettings() },
                                   quit: { NSApp.terminate(nil) })
        let panel = PanelController(model: model, watch: watch, actions: actions)
        self.panel = panel
        statusItem = StatusItemController(model: model, watch: watch, menu: makeMenu()) { [weak self] button in
            self?.panel?.toggle(from: button)
        }
        let desktop = DesktopWidgetController(model: model, watch: watch)
        self.desktop = desktop
        if !CommandLine.arguments.contains("--snapshot") { desktop.sync() }
        // Defaults change notifications can arrive in the middle of AppKit's own work (registering
        // defaults during the first text layout, for one): react on the next turn of the run loop.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.desktop?.sync() } }
        }
        prefetchIcons()
        notifier = TenureNotifier(model: model, watch: watch) { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            if self.panel?.isOpen != true { self.panel?.open(from: button) }
        }
        DebugSnapshot.runIfRequested(model: model, watch: watch, actions: actions, statusItem: statusItem?.button) { self.debugWindow = $0 }
        // `--menubar-snapshot <out.png>`: the pinned readout on dark and light menu bars, at 4×.
        if let i = CommandLine.arguments.firstIndex(of: "--menubar-snapshot"), i + 1 < CommandLine.arguments.count {
            let samples: [(String?, String?)] = [(timer(42), "≈◎44.52"), ("• 2/4", "◎0.0256"), (nil, "◎177.26"), (timer(4_512), nil)]
            let cell = NSSize(width: 110, height: 24), scale = 4.0
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell.width * Double(samples.count) * scale),
                                       pixelsHigh: Int(cell.height * 2 * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: cell.width * Double(samples.count), height: cell.height * 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for (row, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    let y = Double(1 - row) * cell.height
                    (row == 0 ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(x: 0, y: y, width: rep.size.width, height: cell.height).fill()
                    for (k, sample) in samples.enumerated() {
                        let image = StatusStack.image(countdown: sample.0, amount: sample.1)
                        image.draw(in: NSRect(x: Double(k) * cell.width + (cell.width - image.size.width) / 2, y: y + 1,
                                              width: image.size.width, height: image.size.height))
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            NSApp.terminate(nil)
        }
        // `--settings-snapshot <out.png>`: open Settings, capture it, quit.
        if let i = CommandLine.arguments.firstIndex(of: "--settings-snapshot"), i + 1 < CommandLine.arguments.count {
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            openSettings()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if let w = self.settings?.window {
                    DebugSnapshot.write(DebugSnapshot.captureOwnWindow(w), to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Loads the icons of the next leaders (and the pinned validator) before they're shown.
    private func prefetchIcons() {
        withObservationTracking {
            let ids = model.upcomingWindows.prefix(8).map(\.identity) + [watch.identity].compactMap { $0 }
            for id in ids { IconStore.shared.request(id, url: model.iconURL(id)) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.prefetchIcons() }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsItem), keyEquivalent: ",").target = self
        let desktop = NSMenuItem(title: "Show Map on Desktop", action: #selector(toggleDesktop(_:)), keyEquivalent: "")
        desktop.target = self
        menu.addItem(desktop)
        let mute = NSMenuItem(title: "Mute Music", action: #selector(toggleMute(_:)), keyEquivalent: "")
        mute.target = self
        menu.addItem(mute)
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sonata", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openSettingsItem() { openSettings() }

    @objc private func toggleMute(_ sender: NSMenuItem) { conductor.muted.toggle() }

    @objc private func toggleDesktop(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!DesktopWidgetController.isEnabled, forKey: DesktopWidgetController.defaultsKey)
    }

    func openSettings() {
        panel?.close()
        if settings == nil {
            settings = NSWindowController(window: SettingsWindow.make(model: model, watch: watch))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--settings-tab"), i + 1 < CommandLine.arguments.count,
           let tab = Int(CommandLine.arguments[i + 1]), let tabs = settings?.window?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = tab
        }
        settings?.window?.center()
        settings?.showWindow(nil)
        NSApp.activate()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(toggleDesktop(_:)) }?.state = DesktopWidgetController.isEnabled ? .on : .off
        menu.items.first { $0.action == #selector(toggleMute(_:)) }?.state = conductor.muted ? .on : .off
    }
}

// MARK: Status item

/// The menu bar item: the Solana mark and the current leader's flag.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var button: NSStatusBarButton? { item.button }
    private let model: SonataModel
    private let watch: ValidatorWatch
    private let onClick: (NSStatusBarButton) -> Void
    private let menu: NSMenu
    private var flag: String?

    init(model: SonataModel, watch: ValidatorWatch, menu: NSMenu, onClick: @escaping (NSStatusBarButton) -> Void) {
        self.model = model
        self.watch = watch
        self.onClick = onClick
        self.menu = menu
        super.init()
        guard let button = item.button else { return }
        button.image = SolanaMark.templateImage(height: 13)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Sonata")
        observe()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    /// Re-runs whenever what `update` reads changes: the slot (for the countdown), the leader, earnings.
    /// The title is only set when its text changes, about once a second.
    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        let defaults = UserDefaults.standard
        let leader = model.upcomingWindows.first.map { model.pin($0.identity) }
        var tip = leader.map { "Leading: \($0.displayName)" } ?? "Sonata"
        var countdown: String?
        var amount: String?
        var flagText = ""
        if watch.profile != nil {
            // Pinned: the countdown to your next tenure, and what you've made.
            if defaults.object(forKey: "menuCountdown") as? Bool ?? true {
                if let w = watch.currentWindow, let now = model.tickSlot {
                    countdown = "• \(now - w.firstSlot + 1)/\(w.slotCount)"
                } else if let next = watch.nextWindow {
                    countdown = timer(model.seconds(until: next.firstSlot))
                }
            }
            if defaults.object(forKey: "menuEarnings") as? Bool ?? true {
                let period = EarningsPeriod(rawValue: defaults.string(forKey: EarningsPeriod.defaultsKey) ?? "") ?? .epoch
                if let total = watch.earnings(for: period) {
                    amount = (total.estimated ? "≈" : "") + "◎" + sol(total.revenue)
                    tip = "\(period.title): \(sol(total.revenue)) SOL earned"
                }
            }
        } else if defaults.object(forKey: "showLeaderFlag") as? Bool ?? true {
            flagText = leader?.location?.flag ?? ""
        }
        item.button?.toolTip = tip
        let key = [countdown ?? "", amount ?? "", flagText].joined(separator: "|")
        guard key != flag, let button = item.button else { return }
        flag = key
        debugLog("menu bar: \(key)")
        if countdown != nil || amount != nil {
            // Stacked, like a small status readout: the mark and countdown, the amount beneath in grey.
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.image = StatusStack.image(countdown: countdown, amount: amount)
        } else {
            button.image = SolanaMark.templateImage(height: 13)
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: flagText.isEmpty ? "" : " " + flagText, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ])
        }
    }

    /// Settings changed: redraw even if the leader hasn't.
    func refresh() {
        flag = nil
        update()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onClick(sender)
        }
    }
}

/// The pinned status item's two-line readout, drawn for the menu bar's current appearance.
@MainActor
enum StatusStack {
    static let topFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    static let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    static func image(countdown: String?, amount: String?) -> NSImage {
        let stacked = amount != nil
        let markHeight = stacked ? 8.5 : 11.0, gap = stacked ? 3.0 : 4.0
        let topFont = stacked ? Self.topFont : Self.singleFont
        let markWidth = (markHeight * SolanaMark.viewBox.width / SolanaMark.viewBox.height).rounded(.up)
        let top = countdown.map { NSAttributedString(string: $0, attributes: [.font: topFont, .foregroundColor: NSColor.labelColor]) }
        let bottom = amount.map { NSAttributedString(string: $0, attributes: [.font: bottomFont, .foregroundColor: NSColor.secondaryLabelColor]) }
        let topWidth = markWidth + (top.map { gap + ceil($0.size().width) } ?? 0)
        let width = max(topWidth, ceil(bottom?.size().width ?? 0))
        let height = 22.0
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            // Top row: the mark, then the countdown, centered over the amount.
            let rowHeight = stacked ? 10.0 : height
            let rowY = stacked ? 0.5 : 0
            var x = (width - topWidth) / 2
            let markRect = CGRect(x: x, y: rowY + (rowHeight - markHeight) / 2, width: markWidth, height: markHeight)
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.addPath(SolanaMark().path(in: markRect).cgPath)
                ctx.setFillColor(NSColor.labelColor.cgColor)
                ctx.fillPath()
            }
            x += markWidth + gap
            if let top {
                let size = top.size()
                top.draw(at: NSPoint(x: x, y: rowY + (rowHeight - size.height) / 2))
            }
            if let bottom {
                let size = bottom.size()
                bottom.draw(at: NSPoint(x: (width - size.width) / 2, y: height - size.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: Panel

/// The panel under the status item: a borderless, non-activating NSPanel
/// that fades in a few points below the menu bar and closes on a click outside or Esc.
@MainActor
final class PanelController {
    private let model: SonataModel
    private let watch: ValidatorWatch
    private let actions: PanelActions
    private var panel: KeyPanel?
    private var host: NSHostingController<AnyView>?
    private var monitors: [Any] = []
    private(set) var isOpen = false
    private var turn = 0

    init(model: SonataModel, watch: ValidatorWatch, actions: PanelActions) {
        self.model = model
        self.watch = watch
        self.actions = actions
    }

    /// The status item's frame on screen while open: clicks there belong to the item, not "outside".
    private var anchorFrame: NSRect = .zero
    /// When a click outside last closed the panel: that same click's mouse-up mustn't reopen it.
    private var closedOutsideAt: Date?

    func toggle(from button: NSStatusBarButton) {
        debugLog("toggle isOpen=\(isOpen)")
        if isOpen {
            close()
        } else if let at = closedOutsideAt, Date().timeIntervalSince(at) < 0.4 {
            closedOutsideAt = nil  // the click that closed it, arriving as the item's action
        } else {
            open(from: button)
        }
    }

    func open(from button: NSStatusBarButton) {
        closedOutsideAt = nil
        let p = panel ?? makePanel()
        panel = p
        isOpen = true
        turn += 1
        guard let host else { return }
        // One measurement as it opens; afterwards the geometry callback follows the content.
        let size = host.sizeThatFits(in: NSSize(width: PanelRoot.width, height: 10_000))
        let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        anchorFrame = anchor
        let screen = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 6), screen.maxX - size.width - 6)
        let end = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
        debugLog("open: size=\(size) anchor=\(anchor)")
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !p.isVisible {
            p.alphaValue = 0
            p.setFrame(still ? end : end.offsetBy(dx: 0, dy: 4), display: false)
        }
        p.orderFrontRegardless()
        p.makeKey()
        installMonitors()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = still ? 0.12 : 0.2
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(end, display: true)
        }
    }

    func close() {
        guard let p = panel, isOpen else { return }
        isOpen = false
        turn += 1
        let closing = turn
        removeMonitors()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, self.turn == closing else { return }
            p.orderOut(nil)
            p.alphaValue = 1
        }
    }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: PanelRoot.width, height: 600),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.onEscape = { [weak self] in self?.close() }
        let host = makePanelHost(model: model, watch: watch, actions: actions) { [weak p] size in
            guard let p, p.isVisible, abs(p.frame.height - size.height) > 0.5 else { return }
            var f = p.frame  // keep the top edge under the menu bar
            f.origin.y += f.height - size.height
            f.size = size
            p.setFrame(f, display: false)
        }
        self.host = host
        p.contentViewController = host
        return p
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                debugLog("outside click at \(location) anchor=\(self.anchorFrame)")
                // A click on the status item is its own toggle, which closes the panel.
                if self.anchorFrame.insetBy(dx: -2, dy: -2).contains(location) { return }
                self.closedOutsideAt = Date()
                self.close()
            }
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The panel's content: SwiftUI reports its ideal size through a geometry
/// callback, coalesced to changes, so the window follows it without
/// re-measuring the view graph on every data change.
@MainActor
func makePanelHost(model: SonataModel, watch: ValidatorWatch, actions: PanelActions, onSize: @escaping (CGSize) -> Void) -> NSHostingController<AnyView> {
    let conductor = Main.delegate.conductor
    let resizer = PendingResize(onSize)
    let root = PanelRoot(model: model, watch: watch, actions: actions)
        .environment(conductor)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Never resize the window inside SwiftUI's layout pass: that re-enters text
            // measurement (a recursive lock). Apply the latest size on the next turn of the run loop.
            resizer.schedule(size)
        }
    let host = NSHostingController(rootView: AnyView(root))
    host.sizingOptions = []
    host.view.wantsLayer = true
    host.view.layer?.cornerCurve = .continuous
    host.view.layer?.cornerRadius = Palette.panelRadius
    host.view.layer?.masksToBounds = true
    return host
}

// MARK: Debug snapshots

/// `--snapshot <out.png> [--dark|--light]` renders the panel in a window once data has loaded, then quits.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: SonataModel, watch: ValidatorWatch, actions: PanelActions, statusItem: NSStatusBarButton?, keep: (NSWindow) -> Void) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: PanelRoot.width, height: 700),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        let host = makePanelHost(model: model, watch: watch, actions: actions) { [weak window] size in
            window?.setContentSize(size)
        }
        window.contentViewController = host
        window.setContentSize(host.sizeThatFits(in: NSSize(width: PanelRoot.width, height: 10_000)))
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()
        keep(window)
        let widget = NSWindow(contentRect: NSRect(origin: NSPoint(x: 460, y: 60), size: DesktopMapWidget.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        widget.isOpaque = false
        widget.backgroundColor = .clear
        widget.contentView = NSHostingView(rootView: DesktopMapWidget(model: model, watch: watch, remove: {}))
        widget.orderFrontRegardless()
        keep(widget)
        Task { @MainActor in
            for _ in 0..<120 where model.locatedCount == 0 || model.upcomingWindows.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            for _ in 0..<120 where watch.isPinned && (watch.lastReport == nil || watch.tipDistribution == nil || watch.jito.isEmpty) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(5))  // validator info and icons
            let url = URL(fileURLWithPath: args[i + 1])
            write(captureOwnWindow(window), to: url)
            write(captureOwnWindow(widget), to: url.deletingPathExtension().appendingPathExtension("widget.png"))
            if let itemWindow = statusItem?.window {
                write(captureOwnWindow(itemWindow), to: url.deletingPathExtension().appendingPathExtension("item.png"))
            }
            NSApp.terminate(nil)
        }
    }

    static func write(_ image: CGImage?, to url: URL) {
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// CGWindowListCreateImage is hidden from Swift in the macOS 15 SDK, but an app may still capture its own windows.
    static func captureOwnWindow(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard window.windowNumber > 0, window.windowNumber <= Int(UInt32.max), let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue()
    }
}

/// Logs when launched with SONATA_DEBUG set.
func debugLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["SONATA_DEBUG"] != nil { NSLog("sonata %@", message()) }
}

/// Holds the latest size SwiftUI reported and applies it once, after the current layout pass.
@MainActor
final class PendingResize {
    private let apply: (CGSize) -> Void
    private var pending: CGSize?

    init(_ apply: @escaping (CGSize) -> Void) { self.apply = apply }

    func schedule(_ size: CGSize) {
        let idle = pending == nil
        pending = size
        guard idle else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let latest = self.pending else { return }
                self.pending = nil
                self.apply(latest)
            }
        }
    }
}

/// Sonata's bundle identifier was dev.sonata.Sonata; it's sh.scarce.Sonata now. Settings live in
/// a domain named after it, so the first launch under the new name copies the old ones over:
/// the pinned validator, the RPC, the earnings period, mute, window positions.
enum SettingsMigration {
    static let oldDomain = "dev.sonata.Sonata"
    static let doneKey = "migratedSettingsFrom"

    static func run(defaults: UserDefaults = .standard, current: String? = Bundle.main.bundleIdentifier) {
        guard let current, current != oldDomain, defaults.string(forKey: doneKey) == nil else { return }
        defer { defaults.set(oldDomain, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        let existing = defaults.persistentDomain(forName: current) ?? [:]
        for (key, value) in old where existing[key] == nil { defaults.set(value, forKey: key) }
    }
}
