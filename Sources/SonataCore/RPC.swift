import Foundation

/// The read calls Sonata makes, over its own minimal JSON-RPC client.
public struct RPCClient: Sendable {
    public let endpoint: URL
    let rpc: JSONRPC

    public init(endpoint: URL) {
        self.endpoint = endpoint
        rpc = JSONRPC(endpoint: endpoint)
    }

    public func epochInfo() async throws -> EpochInfo {
        try await rpc.call("getEpochInfo", params: [["commitment": "processed"]], timeout: 10)
    }

    public func slot() async throws -> UInt64 {
        try await rpc.call("getSlot", params: [["commitment": "processed"]], timeout: 5)
    }

    /// Seconds per slot over the last few minutes (`getRecentPerformanceSamples`).
    public func slotDuration() async throws -> Double? {
        struct Sample: Decodable {
            let numSlots: UInt64
            let samplePeriodSecs: UInt64
        }
        let samples: [Sample] = try await rpc.call("getRecentPerformanceSamples", params: [.int(5)])
        let slots = samples.reduce(0) { $0 + $1.numSlots }, secs = samples.reduce(0) { $0 + $1.samplePeriodSecs }
        guard slots > 0, secs > 0 else { return nil }
        return Double(secs) / Double(slots)
    }

    /// Leader schedule for the epoch containing `slot` (current epoch when nil).
    /// Keys are validator identities, values are slot indices relative to the epoch's first slot.
    public func leaderSchedule(slot: UInt64?) async throws -> [String: [UInt64]] {
        let schedule: [String: [UInt64]]? = try await rpc.call("getLeaderSchedule", params: [slot.map { .int($0) } ?? .null])
        guard let schedule else { throw RPCError.noResult(method: "getLeaderSchedule for slot \(slot ?? 0)") }
        return schedule
    }

    public func clusterNodes() async throws -> [ClusterNode] {
        try await rpc.call("getClusterNodes", timeout: 30)
    }

    /// Validator info published on-chain through `solana validator-info publish`: names and icons.
    public func validatorInfo() async throws -> [String: PublishedInfo] {
        let accounts: [ConfigAccount] = try await rpc.call(
            "getProgramAccounts",
            params: [.string("Config1111111111111111111111111111111111111"), ["encoding": "jsonParsed"]],
            timeout: 90)
        var out: [String: PublishedInfo] = [:]
        for account in accounts {
            guard let parsed = account.account.data.parsed, parsed.type == "validatorInfo",
                  let info = parsed.info,
                  let identity = info.keys?.first(where: { $0.signer })?.pubkey,
                  let data = info.configData
            else { continue }
            let name = data.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let icon = data.iconUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = PublishedInfo(name: name?.isEmpty == false ? name : nil, iconURL: icon?.isEmpty == false ? icon : nil,
                                      website: data.website)
            if entry.name != nil || entry.iconURL != nil { out[identity] = entry }
        }
        return out
    }

    /// HTTP 429 from the RPC node, which public endpoints return under load.
    public static func isRateLimited(_ error: any Error) -> Bool {
        (error as? RPCError)?.isRateLimited ?? false
    }
}

public struct EpochInfo: Codable, Sendable, Equatable {
    public let absoluteSlot: UInt64
    public let epoch: UInt64
    public let slotIndex: UInt64
    public let slotsInEpoch: UInt64

    public init(absoluteSlot: UInt64, epoch: UInt64, slotIndex: UInt64, slotsInEpoch: UInt64) {
        self.absoluteSlot = absoluteSlot
        self.epoch = epoch
        self.slotIndex = slotIndex
        self.slotsInEpoch = slotsInEpoch
    }

    public var firstSlot: UInt64 { absoluteSlot - slotIndex }
    public var progress: Double { Double(slotIndex) / Double(max(slotsInEpoch, 1)) }
}

/// What a validator published about itself on-chain.
public struct PublishedInfo: Codable, Sendable, Equatable {
    public let name: String?
    public let iconURL: String?
    public let website: String?

    public init(name: String?, iconURL: String?, website: String?) {
        self.name = name
        self.iconURL = iconURL
        self.website = website
    }
}

/// The parts of a gossip node Sonata keeps (and caches to disk).
public struct ClusterNode: Codable, Sendable {
    public let pubkey: String
    public let gossip: String?
    public let version: String?

    public init(pubkey: String, gossip: String?, version: String?) {
        self.pubkey = pubkey
        self.gossip = gossip
        self.version = version
    }

    /// Host part of the gossip address ("1.2.3.4:8001" or "[::1]:8001").
    public var ip: String? {
        guard let gossip else { return nil }
        if gossip.hasPrefix("["), let end = gossip.firstIndex(of: "]") {
            return String(gossip[gossip.index(after: gossip.startIndex)..<end])
        }
        guard let colon = gossip.lastIndex(of: ":") else { return gossip }
        return String(gossip[..<colon])
    }
}

struct ConfigAccount: Decodable {
    let account: Account

    struct Account: Decodable { let data: AccountData }

    /// `data` is an object when jsonParsed succeeded, otherwise a `[base64, encoding]` array.
    struct AccountData: Decodable {
        let parsed: Parsed?
        enum CodingKeys: String, CodingKey { case parsed }
        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            parsed = (try? container?.decodeIfPresent(Parsed.self, forKey: .parsed)) ?? nil
        }
    }

    struct Parsed: Decodable {
        let type: String
        let info: Info?
        enum CodingKeys: String, CodingKey { case type, info }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            info = try? c.decodeIfPresent(Info.self, forKey: .info)
        }
    }

    struct Info: Decodable {
        let configData: ConfigData?
        let keys: [Key]?
    }

    struct ConfigData: Decodable {
        let name: String?
        let iconUrl: String?
        let website: String?
        enum CodingKeys: String, CodingKey { case name, iconUrl, website }
        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            name = (try? c?.decodeIfPresent(String.self, forKey: .name)) ?? nil
            iconUrl = (try? c?.decodeIfPresent(String.self, forKey: .iconUrl)) ?? nil
            website = (try? c?.decodeIfPresent(String.self, forKey: .website)) ?? nil
        }
    }

    struct Key: Decodable {
        let pubkey: String
        let signer: Bool
    }
}
