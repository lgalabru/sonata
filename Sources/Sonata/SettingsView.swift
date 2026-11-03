import AppKit
import ServiceManagement
import SonataCore
import SwiftUI
import UserNotifications

/// Settings as macOS apps do them: a toolbar of panes, each a grouped form.
@MainActor
enum SettingsWindow {
    static func make(model: SonataModel, watch: ValidatorWatch) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        func pane(_ title: String, _ symbol: String, _ view: some View) {
            let host = NSHostingController(rootView: view.frame(width: 500).fixedSize(horizontal: false, vertical: true))
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralPane(watch: watch))
        pane("Validator", "checkmark.seal", ValidatorPane(model: model, watch: watch))
        pane("Network", "network", NetworkPane(model: model))
        pane("Data", "externaldrive", DataPane(model: model))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: General

private struct GeneralPane: View {
    let watch: ValidatorWatch
    @AppStorage("showLeaderFlag") private var showLeader = true
    @AppStorage("menuCountdown") private var countdown = true
    @AppStorage("menuEarnings") private var earnings = true
    @AppStorage(EarningsPeriod.defaultsKey) private var period: EarningsPeriod = .epoch
    @AppStorage(TenureAlerts.defaultsKey) private var alerts: TenureAlerts = .every
    @AppStorage("desktopMap") private var desktopMap = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                if watch.isPinned {
                    Toggle("Countdown to your next tenure", isOn: $countdown)
                    Toggle("Earnings", isOn: $earnings)
                    Picker("Earnings over", selection: $period) {
                        ForEach(EarningsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!earnings)
                } else {
                    Toggle("Show the current leader's flag", isOn: $showLeader)
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Footnote(watch.isPinned
                    ? "With a validator pinned, the menu bar shows when it leads next, in seconds, and what it has earned: block rewards, MEV commission and inflation commission. ≈ means blocks are still being read."
                    : "Pin a validator in the Validator pane to see its countdown and earnings here instead.")
            }
            if watch.isPinned {
                Section {
                    Picker("After each tenure", selection: $alerts) {
                        ForEach(TenureAlerts.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: alerts) { _, new in
                        if new != .off {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Footnote("A notification once each tenure is summed: blocks produced, block rewards and MEV, and what you kept. Your validator leads every minute or two, so you may prefer hearing only about skipped blocks.")
                }
            }
            Section {
                Toggle("Show the live map on the desktop", isOn: $desktopMap)
            } header: {
                Text("Desktop")
            } footer: {
                Footnote("The map sits beneath your windows like a widget. Drag it to move it; Control-click it to remove it.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Validator

private struct ValidatorPane: View {
    let model: SonataModel
    let watch: ValidatorWatch
    @State private var draft = ""

    var body: some View {
        Form {
            if !watch.isPinned {
                Section {
                    TextField("Address", text: $draft, prompt: Text("Identity or vote account"))
                        .onSubmit(pin)
                } footer: {
                    Footnote("Pin a validator to see when it leads next, what each tenure earned in block rewards and MEV, and how that splits between the validator and its stakers.")
                }
            } else if let profile = watch.profile {
                Section {
                    ValidatorHeader(model: model, profile: profile) { watch.pin("") }
                }
                Section("Accounts") {
                    AddressRow(title: "Identity", address: profile.identity)
                    AddressRow(title: "Vote account", address: profile.vote)
                }
                Section("Economics") {
                    LabeledContent("Commission", value: "\(profile.commission)%")
                    LabeledContent("MEV commission", value: mevCommission)
                    LabeledContent("Active stake", value: stake(profile.activatedStake))
                    LabeledContent("Status") {
                        Label(profile.delinquent ? "Delinquent" : "Voting", systemImage: "circle.fill")
                            .labelStyle(StatusLabelStyle(color: profile.delinquent ? .orange : .green))
                    }
                }
            } else {
                Section {
                    LabeledContent("Address") {
                        Text(watch.address).truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                    }
                    if let error = watch.resolveError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Looking up…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if !watch.isPinned {
                BottomBar {
                    Button("Pin Validator", action: pin).keyboardShortcut(.defaultAction).disabled(!isValid)
                }
            } else if watch.profile == nil {
                BottomBar { Button("Unpin") { watch.pin("") } }
            }
        }
    }

    private var isValid: Bool {
        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let base58 = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return (32...44).contains(s.count) && s.unicodeScalars.allSatisfy(base58.contains)
    }

    private func pin() {
        guard isValid else { return }
        watch.pin(draft)
        draft = ""
    }

    private var mevCommission: String {
        if let tda = watch.tipDistribution { return "\(tda.commissionBps / 100)%" }
        if let last = watch.jito.first { return "\(last.mev_commission_bps / 100)%" }
        return "—"
    }

    private func stake(_ lamports: UInt64) -> String {
        (Double(lamports) / lamportsPerSOL).formatted(.number.precision(.fractionLength(0))) + " SOL"
    }
}

/// The pinned validator as an identity row, like an account in System Settings.
private struct ValidatorHeader: View {
    let model: SonataModel
    let profile: ValidatorProfile
    var unpin: () -> Void

    var body: some View {
        let pin = model.pin(profile.identity)
        HStack(spacing: 12) {
            ValidatorAvatar(model: model, identity: profile.identity, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.displayName).font(.headline)
                Text(pin.location?.place ?? "Location unknown").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unpin", action: unpin)
        }
        .padding(.vertical, 2)
    }
}

/// A read-only address: middle-truncated, selectable, with a copy button.
private struct AddressRow: View {
    var title: String
    var address: String
    @State private var copied = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(address)
                    .font(.body.monospaced())
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(address)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .frame(maxWidth: 260, alignment: .trailing)
        }
    }
}

// MARK: Network

struct NetworkPane: View {
    @Bindable var model: SonataModel
    @State private var cluster: Cluster = .mainnet
    @State private var customURL = ""

    enum Cluster: String, CaseIterable, Identifiable {
        case mainnet, devnet, testnet, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .mainnet: "Mainnet Beta"
            case .devnet: "Devnet"
            case .testnet: "Testnet"
            case .custom: "Custom RPC"
            }
        }
        var url: String? {
            switch self {
            case .mainnet: "https://api.mainnet-beta.solana.com"
            case .devnet: "https://api.devnet.solana.com"
            case .testnet: "https://api.testnet.solana.com"
            case .custom: nil
            }
        }
        static func matching(_ url: String) -> Cluster { allCases.first { $0.url == url } ?? .custom }
    }

    var body: some View {
        Form {
            Section {
                Picker("Cluster", selection: $cluster) {
                    ForEach(Cluster.allCases.filter { $0 != .custom }) { Text($0.title).tag($0) }
                    Divider()
                    Text(Cluster.custom.title).tag(Cluster.custom)
                }
                .onChange(of: cluster) { _, new in
                    if let url = new.url { model.rpcURL = url } else if customURL.isEmpty { customURL = model.rpcURL }
                }
                if cluster == .custom {
                    TextField("RPC URL", text: $customURL, prompt: Text("https://"))
                        .onSubmit(applyCustom)
                }
                LabeledContent("Status") {
                    Label(statusText, systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: statusColor))
                }
            } footer: {
                Footnote("Public endpoints are rate limited. A private RPC makes tenure reports, which read every block you produce, more reliable.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if cluster == .custom {
                BottomBar {
                    Button("Connect", action: applyCustom)
                        .keyboardShortcut(.defaultAction)
                        .disabled(URL(string: customURL)?.scheme == nil || customURL == model.rpcURL)
                }
            }
        }
        .onAppear {
            cluster = .matching(model.rpcURL)
            customURL = cluster == .custom ? model.rpcURL : ""
        }
    }

    private var statusText: String {
        switch model.phase {
        case .live: "Connected"
        case .stale(let why), .failed(let why): why
        case .loading(let what): what
        case .starting: "Connecting…"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .live: .green
        case .stale: .orange
        case .failed: .red
        default: .gray
        }
    }

    private func applyCustom() {
        guard URL(string: customURL)?.scheme != nil else { return }
        model.rpcURL = customURL
    }
}

// MARK: Data

private struct DataPane: View {
    let model: SonataModel
    @State private var confirmClear = false
    @State private var size: Int64 = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Leader schedules", value: model.book.schedules.keys.sorted().map { "Epoch \($0)" }.joined(separator: ", "))
                LabeledContent("Leaders located", value: "\(model.locatedCount) of \(model.pins.count)")
                LabeledContent("Validator names and IPs") {
                    Button("Refresh") { model.refresh() }
                }
            }
            Section {
                LabeledContent("Cache") {
                    HStack(spacing: 10) {
                        Text(size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                        Button("Clear…") { confirmClear = true }
                    }
                }
            } footer: {
                Footnote("Schedules, validator names, icons, IP locations, tenure reports and earnings are kept in ~/Library/Caches/sonata. Locations come from ip-api.com, MEV from Jito, block-building scores from ibrl.wtf, and completed epochs' rewards are Fueled by Trillium (CC BY 4.0).")
            }
        }
        .formStyle(.grouped)
        .onAppear { size = Self.cacheSize() }
        .confirmationDialog("Clear all cached data?", isPresented: $confirmClear) {
            Button("Clear Cache", role: .destructive) {
                model.clearCache()
                size = 0
            }
        } message: {
            Text("Sonata will download the leader schedule and look up validator locations again.")
        }
    }

    static func cacheSize() -> Int64 {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sonata")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: Pieces

/// A section footer, aligned with the rows above it.
private struct Footnote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A pane's primary action, bottom right as in a sheet.
private struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Spacer()
            content
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
    }
}

/// A small colored dot before a status.
private struct StatusLabelStyle: LabelStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

extension SonataModel {
    static func clusterName(for url: String) -> String {
        switch NetworkPane.Cluster.matching(url) {
        case .mainnet: "Mainnet"
        case .devnet: "Devnet"
        case .testnet: "Testnet"
        case .custom: URL(string: url)?.host ?? "Custom RPC"
        }
    }
}
