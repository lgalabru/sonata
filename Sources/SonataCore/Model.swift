import Foundation
import Observation

/// Everything the map knows about one leader.
public struct ValidatorPin: Sendable, Identifiable, Equatable {
    public let identity: String
    public let name: String?
    public let location: GeoPoint?
    /// Map coordinates (the gossip IP's location).
    public let lat: Double?
    public let lon: Double?
    public let share: Double
    public let version: String?
    public var id: String { identity }

    public var displayName: String { name ?? shortKey(identity) }
}

/// Leaders sharing (roughly) one location, drawn as a single dot.
public struct PinCluster: Sendable, Identifiable, Equatable {
    public let id: String
    public let lat: Double
    public let lon: Double
    public let share: Double
    public let count: Int
    /// The city of its biggest leader.
    public let city: String?
    public let countryCode: String?
}

/// The 1° cell a location falls in; leaders in one cell share a dot.
public func clusterKey(_ g: GeoPoint) -> String { "\(Int(g.lat.rounded()))/\(Int(g.lon.rounded()))" }

public func shortKey(_ key: String) -> String {
    key.count > 10 ? "\(key.prefix(4))…\(key.suffix(4))" : key
}

@MainActor
@Observable
public final class SonataModel {
    public enum Phase: Equatable, Sendable {
        case starting
        case loading(String)
        case live
        case stale(String)
        case failed(String)
    }

    public static let defaultRPC = "https://api.mainnet-beta.solana.com"

    public private(set) var phase: Phase = .starting
    public private(set) var book = ScheduleBook()
    public private(set) var epoch: EpochInfo?
    public private(set) var pins: [String: ValidatorPin] = [:]
    public private(set) var maxShare: Double = 0
    public private(set) var names: [String: String] = [:]
    /// Icons validators published, by identity.
    public private(set) var iconURLs: [String: URL] = [:]
    public private(set) var nodes: [String: ClusterNode] = [:]
    public private(set) var geo: [String: GeoPoint] = [:]
    /// Integer slot, advanced by a ticker; drives the menu bar label and the cards.
    public private(set) var tickSlot: UInt64?
    /// Leader windows around `tickSlot`, reassigned only when the leader changes (every ~1.6s),
    /// so views that only care about leaders don't re-render on every slot.
    public private(set) var upcomingWindows: [LeaderWindow] = []
    public private(set) var recentWindows: [LeaderWindow] = []
    public private(set) var clusters: [PinCluster] = []
    public private(set) var lastSync: Date?
    /// Measured seconds per slot (about 0.21s since faster slots; 0.4s before).
    public private(set) var slotDuration: Double = UserDefaults.standard.object(forKey: "slotDuration") as? Double ?? 0.4
    public private(set) var sources: [String: String] = [:]  // dataset -> "cache" / "rpc" / note

    public var rpcURL: String {
        didSet {
            guard rpcURL != oldValue else { return }
            UserDefaults.standard.set(rpcURL, forKey: "rpcURL")
            restart()
        }
    }

    @ObservationIgnored private var clock: SlotClock?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var cache: DiskCache
    @ObservationIgnored private let geoLocator = GeoLocator()
    @ObservationIgnored private var fetching: Set<UInt64> = []

    static let nodesTTL: TimeInterval = 6 * 3_600
    static let namesTTL: TimeInterval = 24 * 3_600

    public init() {
        let url = UserDefaults.standard.string(forKey: "rpcURL") ?? Self.defaultRPC
        rpcURL = url
        cache = DiskCache.forEndpoint(URL(string: url) ?? URL(string: Self.defaultRPC)!)
    }

    var rpc: RPCClient? {
        URL(string: rpcURL).flatMap { $0.scheme == "https" || $0.scheme == "http" ? RPCClient(endpoint: $0) : nil }
    }

    // MARK: Lifecycle

    public func start() {
        guard tasks.isEmpty else { return }
        guard let rpc else {
            phase = .failed("Invalid RPC URL")
            return
        }
        cache = DiskCache.forEndpoint(rpc.endpoint)
        tasks.append(Task { [weak self] in await self?.run(rpc) })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        })
    }

    public func restart() {
        tasks.forEach { $0.cancel() }
        tasks = []
        book = ScheduleBook()
        epoch = nil
        nodes = [:]
        names = [:]
        pins = [:]
        clock = nil
        tickSlot = nil
        upcomingWindows = []
        recentWindows = []
        clusters = []
        lastSync = nil
        sources = [:]
        fetching = []
        phase = .starting
        start()
    }

    /// Drops every cached dataset (and the geo cache) and starts over.
    public func clearCache() {
        cache.clear()
        let locator = geoLocator
        Task {
            await locator.clear()
            self.geo = [:]
            self.restart()
        }
    }

    /// Re-fetches cluster nodes and names now; schedules are immutable per epoch.
    public func refresh() {
        cache.remove("nodes.json")
        cache.remove("names.json")
        cache.remove(Self.infoFile)
        restart()
    }

    // MARK: Queries

    public func estimatedSlot(at date: Date) -> Double? { clock?.estimate(at: date) }

    public func isClockStale(at date: Date) -> Bool { clock?.isStale(at: date) ?? true }

    public func pin(_ identity: String) -> ValidatorPin {
        pins[identity] ?? ValidatorPin(identity: identity, name: names[identity], location: nil, lat: nil, lon: nil,
                                       share: 0, version: nodes[identity]?.version)
    }

    public func upcoming(_ count: Int) -> [LeaderWindow] {
        guard let tickSlot else { return [] }
        return book.windows(from: tickSlot, count: count)
    }

    public var currentLeader: ValidatorPin? {
        guard let tickSlot, let id = book.leader(at: tickSlot) else { return nil }
        return pin(id)
    }

    public var locatedCount: Int { pins.values.filter { $0.lat != nil }.count }

    // MARK: Loop

    private func tick() {
        guard let slot = clock?.estimate(at: Date()) else { return }
        let whole = UInt64(slot)
        guard whole != tickSlot else { return }
        tickSlot = whole
        if upcomingWindows.first.map({ whole < $0.firstSlot || whole >= $0.endSlot }) ?? true {
            updateWindows()
        }
    }

    private func updateWindows() {
        guard let tickSlot else { return }
        let upcoming = book.windows(from: tickSlot, count: 8)
        if upcoming != upcomingWindows { upcomingWindows = upcoming }
        let recent = book.previousWindows(before: tickSlot, count: 6)
        if recent != recentWindows { recentWindows = recent }
    }

    private func run(_ rpc: RPCClient) async {
        // Bootstrap: retry until we have an epoch and its schedule.
        while !Task.isCancelled {
            do {
                try await bootstrap(rpc)
                break
            } catch {
                phase = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
            }
        }

        var lastEpochCheck = Date()
        var lastSlotTiming = Date.distantPast
        var backoff: TimeInterval = 2
        while !Task.isCancelled {
            do {
                let slot = try await rpc.slot()
                observe(slot: slot)
                backoff = 2
                if Date().timeIntervalSince(lastSlotTiming) > 300 {
                    lastSlotTiming = Date()
                    if let d = try? await rpc.slotDuration(), d > 0.05, d < 2 { setSlotDuration(d) }
                }
                if Date().timeIntervalSince(lastEpochCheck) > 30 {
                    lastEpochCheck = Date()
                    let info = try await rpc.epochInfo()
                    epoch = info
                    try await ensureSchedules(rpc, for: info)
                    await refreshNodesIfStale(rpc)
                }
            } catch is CancellationError {
                return
            } catch where RPCClient.isRateLimited(error) {
                backoff = min(max(10, backoff * 2), 60)
                phase = .stale("Rate limited, retrying in \(Int(backoff))s")
            } catch {
                backoff = min(backoff * 2, 30)
                phase = .stale(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    private func setSlotDuration(_ d: Double) {
        slotDuration = d
        clock?.slotDuration = d
        UserDefaults.standard.set(d, forKey: "slotDuration")
    }

    /// Seconds until `slot`, from the current tick.
    public func seconds(until slot: UInt64) -> Double {
        guard let now = tickSlot, slot > now else { return 0 }
        return Double(slot - now) * slotDuration
    }

    /// Epochs per year at the measured slot time.
    public var epochsPerYear: Double {
        365.25 * 86_400 / (Double(epoch?.slotsInEpoch ?? 432_000) * slotDuration)
    }

    private func observe(slot: UInt64) {
        let now = Date()
        if clock == nil { clock = SlotClock(slot: slot, at: now, slotDuration: slotDuration) } else { clock?.observe(slot: slot, at: now) }
        lastSync = now
        phase = .live
        tick()
    }

    private func bootstrap(_ rpc: RPCClient) async throws {
        phase = .loading("Fetching epoch")
        let info = try await rpc.epochInfo()
        epoch = info
        observe(slot: info.absoluteSlot)
        phase = .loading("Loading leader schedule")
        try await ensureSchedules(rpc, for: info)

        // Cluster nodes give each identity its gossip IP.
        if let cached: Stamped<[ClusterNode]> = cache.read("nodes.json") {
            apply(nodes: cached.value, source: cached.isFresh(ttl: Self.nodesTTL) ? "cache" : "cache (stale)")
        }
        if let cached: Stamped<[String: PublishedInfo]> = cache.read(Self.infoFile) {
            apply(info: cached.value)
            sources["names"] = "cache"
        }
        rebuildPins()
        phase = .live

        await locateLeaders()  // instant from the geo cache when nodes came from disk
        await refreshNodesIfStale(rpc)
        Task { [weak self] in await self?.refreshNamesIfStale(rpc) }
    }

    private func ensureSchedules(_ rpc: RPCClient, for info: EpochInfo) async throws {
        try await ensureSchedule(rpc, epoch: info.epoch, firstSlot: info.firstSlot, slotsInEpoch: info.slotsInEpoch, query: nil)
        // The next epoch's schedule is known a full epoch ahead; prefetch near the boundary.
        if info.progress > 0.9 {
            let next = info.firstSlot + info.slotsInEpoch
            try? await ensureSchedule(rpc, epoch: info.epoch + 1, firstSlot: next, slotsInEpoch: info.slotsInEpoch, query: next)
        }
        // Forget epochs we've left behind.
        for e in book.schedules.keys where e + 1 < info.epoch { book.schedules[e] = nil }
    }

    private func ensureSchedule(_ rpc: RPCClient, epoch: UInt64, firstSlot: UInt64, slotsInEpoch: UInt64, query: UInt64?) async throws {
        guard book.schedules[epoch] == nil, !fetching.contains(epoch) else { return }
        if let cached = cache.schedule(epoch: epoch), cached.firstSlot == firstSlot {
            book.schedules[epoch] = cached
            sources["schedule-\(epoch)"] = "cache"
            rebuildPins()
            return
        }
        fetching.insert(epoch)
        defer { fetching.remove(epoch) }
        let schedule = try await Self.fetchSchedule(rpc, epoch: epoch, firstSlot: firstSlot, slotsInEpoch: slotsInEpoch, query: query)
        let cache = self.cache
        Task.detached(priority: .utility) { cache.store(schedule) }
        book.schedules[epoch] = schedule
        sources["schedule-\(epoch)"] = "rpc"
        rebuildPins()
        await locateLeaders()
    }

    /// Loads the previous epoch's schedule (for a pinned validator's last tenure early in an epoch).
    public func loadPreviousEpochSchedule() async {
        guard let rpc, let info = epoch, info.epoch > 0, info.firstSlot >= info.slotsInEpoch else { return }
        let first = info.firstSlot - info.slotsInEpoch
        try? await ensureSchedule(rpc, epoch: info.epoch - 1, firstSlot: first, slotsInEpoch: info.slotsInEpoch, query: first)
    }

    nonisolated private static func fetchSchedule(_ rpc: RPCClient, epoch: UInt64, firstSlot: UInt64, slotsInEpoch: UInt64,
                                                  query: UInt64?) async throws -> LeaderSchedule {
        let raw = try await rpc.leaderSchedule(slot: query)
        return LeaderSchedule(epoch: epoch, firstSlot: firstSlot, slotsInEpoch: slotsInEpoch, rpc: raw)
    }

    private func refreshNodesIfStale(_ rpc: RPCClient) async {
        if let cached: Stamped<[ClusterNode]> = cache.read("nodes.json"), cached.isFresh(ttl: Self.nodesTTL), !nodes.isEmpty {
            return
        }
        do {
            let fresh = try await rpc.clusterNodes()
            cache.write(Stamped(fresh), to: "nodes.json")
            apply(nodes: fresh, source: "rpc")
        } catch {
            sources["nodes"] = nodes.isEmpty ? "unavailable" : "cache (stale)"
        }
        await locateLeaders()
    }

    private func refreshNamesIfStale(_ rpc: RPCClient) async {
        if let cached: Stamped<[String: PublishedInfo]> = cache.read(Self.infoFile), cached.isFresh(ttl: Self.namesTTL) { return }
        do {
            let fresh = try await rpc.validatorInfo()
            cache.write(Stamped(fresh), to: Self.infoFile)
            apply(info: fresh)
            sources["names"] = "rpc"
            rebuildPins()
        } catch {
            if names.isEmpty { sources["names"] = "unavailable" }
        }
    }

    static let infoFile = "validator-info.json"

    private func apply(info: [String: PublishedInfo]) {
        names = info.compactMapValues(\.name)
        iconURLs = info.compactMapValues { $0.iconURL.flatMap(URL.init(string:)) }
    }

    public func iconURL(_ identity: String) -> URL? { iconURLs[identity] }

    private func apply(nodes list: [ClusterNode], source: String) {
        nodes = Dictionary(list.map { ($0.pubkey, $0) }, uniquingKeysWith: { a, _ in a })
        sources["nodes"] = source
        rebuildPins()
    }

    /// Geolocates the gossip IP of every scheduled leader, cached first, then incrementally.
    private func locateLeaders() async {
        let ids = Set(book.schedules.values.flatMap(\.identities))
        let ips = ids.compactMap { nodes[$0]?.ip }
        guard !ips.isEmpty else { return }
        let locator = geoLocator
        geo.merge(await locator.cached(ips)) { _, new in new }
        rebuildPins()
        let found = await locator.locate(ips) { partial in
            await MainActor.run { [weak self] in
                self?.geo.merge(partial) { _, new in new }
                self?.rebuildPins()
            }
        }
        geo.merge(found) { _, new in new }
        sources["geo"] = "\(found.count)/\(ips.count) located"
        rebuildPins()
    }

    private func rebuildPins() {
        var shares: [String: Double] = [:]
        // Current epoch first; leaders only in the next epoch still get a pin.
        for schedule in book.schedules.values.sorted(by: { $0.epoch > $1.epoch }) {
            shares.merge(schedule.shares()) { _, current in current }
        }
        var out: [String: ValidatorPin] = [:]
        out.reserveCapacity(shares.count)
        for (id, share) in shares {
            let node = nodes[id]
            let location = node?.ip.flatMap { geo[$0] }
            out[id] = ValidatorPin(identity: id, name: names[id], location: location,
                                   lat: location?.lat, lon: location?.lon,
                                   share: share, version: node?.version)
        }
        pins = out
        maxShare = shares.values.max() ?? 0

        // Cluster by ~1° cells so a datacenter reads as one dot sized by its combined share.
        struct Cell { var lat = 0.0, lon = 0.0, share = 0.0, count = 0, top = 0.0, city: String?, country: String? }
        var cells: [String: Cell] = [:]
        for pin in out.values {
            guard let location = pin.location else { continue }
            let key = clusterKey(location)
            var cell = cells[key] ?? Cell()
            cell.lat += location.lat * pin.share
            cell.lon += location.lon * pin.share
            cell.share += pin.share
            cell.count += 1
            if pin.share >= cell.top, let city = location.city, !city.isEmpty {
                cell.top = pin.share
                cell.city = city
                cell.country = location.countryCode
            }
            cells[key] = cell
        }
        clusters = cells.map { key, c in
            let w = max(c.share, .leastNonzeroMagnitude)
            return PinCluster(id: key, lat: c.lat / w, lon: c.lon / w, share: c.share, count: c.count, city: c.city, countryCode: c.country)
        }.sorted { $0.share > $1.share }
        updateWindows()
    }
}
