import Foundation
import Observation

/// Follows the validator the user pinned: its next tenure, its last tenure's
/// numbers, and the epoch so far. Every remote dataset is cached and
/// refreshed on its own schedule; only leader changes drive the UI.
@MainActor
@Observable
public final class ValidatorWatch {
    func setEarnings(_ e: [UInt64: EpochEarnings]) { earnings = e }
    func setBackfill(done: Int, total: Int) { if backfill != (done, total) { backfill = (done, total) } }
    public private(set) var address: String
    public private(set) var profile: ValidatorProfile?
    public private(set) var resolveError: String?
    /// This validator's windows across the schedules we hold.
    public private(set) var windows: [LeaderWindow] = []
    public private(set) var lastReport: TenureReport?
    public private(set) var loadingReport = false
    public private(set) var tipDistribution: TipDistribution?
    public private(set) var jito: [JitoEpochRewards] = []
    public private(set) var ibrl: IBRLScore?
    public private(set) var production: EpochProduction?
    /// Per-epoch earnings: Trillium's for completed epochs, Sonata's own for the current one. Persisted.
    public private(set) var earnings: [UInt64: EpochEarnings] = [:]
    /// Blocks of the current epoch summed so far, of those produced.
    public private(set) var backfill = (done: 0, total: 0)

    /// Slot → leader reward (lamports; -1 = skipped), per epoch: each block is read once.
    @ObservationIgnored var slotRewards: [UInt64: [UInt64: Int64]] = [:]
    @ObservationIgnored var epochStarts: [UInt64: Date] = [:]
    @ObservationIgnored var backfillTask: Task<Void, Never>?
    @ObservationIgnored var inflationSeen: [UInt64: UInt64] = [:]
    /// Called when a tenure that just ended has been summed.
    @ObservationIgnored public var onTenureReport: ((TenureReport) -> Void)?

    @ObservationIgnored let model: SonataModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var refreshed: [String: Date] = [:]
    @ObservationIgnored private var windowsKey = ""
    @ObservationIgnored var cache: DiskCache { DiskCache.forEndpoint(model.rpc?.endpoint ?? URL(string: SonataModel.defaultRPC)!) }

    public static let defaultsKey = "pinnedValidator"

    public init(model: SonataModel) {
        self.model = model
        address = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
    }

    public var isPinned: Bool { !address.isEmpty }

    public func pin(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != self.address else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.defaultsKey)
        self.address = trimmed
        profile = nil
        resolveError = nil
        windows = []
        windowsKey = ""
        lastReport = nil
        tipDistribution = nil
        jito = []
        ibrl = nil
        production = nil
        earnings = [:]
        slotRewards = [:]
        inflationSeen = [:]
        backfill = (0, 0)
        refreshed = [:]
        restart()
    }

    public func start() {
        guard task == nil, isPinned else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func restart() {
        task?.cancel()
        task = nil
        backfillTask?.cancel()
        backfillTask = nil
        start()
    }

    // MARK: Derived

    public var identity: String? { profile?.identity }

    /// The window being led now, if it's ours.
    public var currentWindow: LeaderWindow? {
        guard let now = model.tickSlot else { return nil }
        return windows.first { now >= $0.firstSlot && now < $0.endSlot }
    }

    public var nextWindow: LeaderWindow? {
        guard let now = model.tickSlot else { return nil }
        return windows.first { $0.firstSlot > now }
    }

    /// A tenure has ended and its report isn't in yet.
    var reportPending: Bool {
        guard let w = lastWindow else { return false }
        return lastReport?.firstSlot != w.firstSlot
    }

    public var lastWindow: LeaderWindow? {
        guard let now = model.tickSlot else { return nil }
        return windows.last { $0.endSlot <= now }
    }

    /// Windows left this epoch, after the current one.
    public var remainingThisEpoch: Int {
        guard let now = model.tickSlot, let epoch = model.epoch else { return 0 }
        let end = epoch.firstSlot + epoch.slotsInEpoch
        return windows.filter { $0.firstSlot > now && $0.firstSlot < end }.count
    }

    /// The MEV commission in force: this epoch's tip distribution account, else Jito's latest epoch.
    public var mevCommissionBps: UInt16? { tipDistribution?.commissionBps ?? jito.first?.mev_commission_bps }

    /// The last tenure's split; nil while tips are in but the MEV commission isn't known yet.
    public var split: RewardSplit? {
        guard let r = lastReport else { return nil }
        let commission = mevCommissionBps
        if commission == nil, r.tipsLamports > 0 { return nil }
        let pf = jito.first.flatMap { ($0.priority_fee_rewards ?? 0) > 0 ? $0.priority_fee_commission_bps : nil }
        return RewardSplit(r, mevCommissionBps: commission ?? 10_000, priorityFeeCommissionBps: pf)
    }

    // MARK: Loop

    func due(_ key: String, every interval: TimeInterval) -> Bool {
        if let last = refreshed[key], Date().timeIntervalSince(last) < interval { return false }
        refreshed[key] = Date()
        return true
    }

    private func step() async {
        guard isPinned, let rpc = model.rpc else { return }

        if profile == nil || due("profile", every: 600) {
            if profile == nil, let cached: Stamped<ValidatorProfile> = cache.read(profileFile), cached.value.identity == address || cached.value.vote == address {
                profile = cached.value
            }
            do {
                if let p = try await rpc.resolveValidator(address) {
                    profile = p
                    resolveError = nil
                    cache.write(Stamped(p), to: profileFile)
                } else if profile == nil {
                    resolveError = "No validator with that identity or vote account"
                }
            } catch {
                if profile == nil { resolveError = error.localizedDescription; refreshed["profile"] = nil }
            }
        }
        guard let profile else { return }
        if earnings.isEmpty { loadEarnings(profile) }

        // Our windows, recomputed when the schedules we hold change.
        let key = model.book.schedules.keys.sorted().map(String.init).joined(separator: ",") + profile.identity
        if key != windowsKey {
            windowsKey = key
            windows = model.book.schedules.values.sorted { $0.epoch < $1.epoch }.flatMap { $0.windows(of: profile.identity) }
        }
        // Early in an epoch the last tenure may be in the one before.
        if lastWindow == nil, !windows.isEmpty || model.book.schedules.count > 0, due("previous-schedule", every: 300) {
            await model.loadPreviousEpochSchedule()
        }

        // Commissions before tenure reports, so a split never runs on a guessed commission.
        if let epoch = model.epoch?.epoch {
            if due("production", every: 120) {
                production = try? await rpc.epochProduction(identity: profile.identity, epoch: epoch)
            }
            if due("tda", every: 300) {
                tipDistribution = (try? await rpc.tipDistributions(vote: profile.vote))?.first { $0.epoch == epoch } ?? tipDistribution
            }
        }
        if due("jito", every: 3_600) {
            if let r = try? await ValidatorWeb.jitoRewards(vote: profile.vote) { jito = r } else { refreshed["jito"] = Date().addingTimeInterval(-3_000) }
        }
        await refreshEarnings(rpc, profile: profile)
        await refreshLastReport(rpc)
        if due("ibrl", every: 3_600) {
            if let s = try? await ValidatorWeb.ibrl(identity: profile.identity) { ibrl = s } else { refreshed["ibrl"] = Date().addingTimeInterval(-3_000) }
        }
    }

    private var profileFile: String { "validator-profile.json" }

    /// Once our last window is confirmed (a few slots after it ends), sum its blocks; cached per window.
    private func refreshLastReport(_ rpc: RPCClient) async {
        guard let window = lastWindow, let now = model.tickSlot else { return }
        guard lastReport?.firstSlot != window.firstSlot || lastReport?.identity != window.identity else { return }
        let file = "tenure-\(window.identity.prefix(8))-\(window.firstSlot).json"
        if let cached: TenureReport = cache.read(file) {
            lastReport = cached
            return
        }
        // Show the previous one until this one is in.
        if lastReport == nil, let previous = windows.last(where: { $0.endSlot <= window.firstSlot }),
           let cached: TenureReport = cache.read("tenure-\(previous.identity.prefix(8))-\(previous.firstSlot).json") {
            lastReport = cached
        }
        guard now >= window.endSlot + 8, due("report-\(window.firstSlot)", every: 4) else { return }
        loadingReport = true
        defer { loadingReport = false }
        if let report = try? await rpc.tenureReport(window) {
            cache.write(report, to: file)
            lastReport = report
            pruneReports()
            // Only tenures that just ended: not ones caught up on after a restart or a sleep.
            if let end = report.endTime, Date().timeIntervalSince(end) < 300 { onTenureReport?(report) }
        }
    }

    private func pruneReports() {
        let reports = cache.files(prefix: "tenure-").sorted { a, b in
            (UInt64(a.split(separator: "-").last?.dropLast(5) ?? "") ?? 0) > (UInt64(b.split(separator: "-").last?.dropLast(5) ?? "") ?? 0)
        }
        for old in reports.dropFirst(50) { cache.remove(old) }
    }
}
