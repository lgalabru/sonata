import Foundation
import SolanaErrors
import SolanaPrimitives
import SolanaRPC

extension RPCClient {
    /// Resolves an identity or a vote account to the validator's profile.
    public func resolveValidator(_ address: String) async throws -> ValidatorProfile? {
        let accounts = try await rpc.getVoteAccounts(commitment: .confirmed)
        func profile(_ v: VoteAccount, delinquent: Bool) -> ValidatorProfile {
            ValidatorProfile(identity: v.nodePubkey.base58, vote: v.votePubkey.base58, commission: v.commission,
                             activatedStake: v.activatedStake, delinquent: delinquent)
        }
        for (list, delinquent) in [(accounts.current, false), (accounts.delinquent, true)] {
            if let v = list.first(where: { $0.votePubkey.base58 == address || $0.nodePubkey.base58 == address }) {
                return profile(v, delinquent: delinquent)
            }
        }
        return nil
    }

    public enum SlotOutcome: Sendable {
        case produced(SlotReport)
        case skipped
        /// Not confirmed yet, or the node doesn't have it: try again later.
        case unavailable
    }

    /// One leader slot, summed from its block (accounts-level details keep it to a couple of MB).
    public func slotReport(_ slot: UInt64, leader: String) async throws -> SlotOutcome {
        do {
            let block: AccountsBlock = try await rpc.call("getBlock", params: [
                .int(slot),
                ["commitment": "confirmed", "encoding": "json", "transactionDetails": "accounts", "rewards": true,
                 "maxSupportedTransactionVersion": 1],
            ])
            return .produced(SlotReport(slot: slot, block: block, leader: leader))
        } catch let error as SolanaError {
            switch error.code {
            case .jsonRpcServerErrorSlotSkipped, .jsonRpcServerErrorLongTermStorageSlotSkipped: return .skipped
            case .jsonRpcServerErrorBlockNotAvailable: return .unavailable
            default: throw error
            }
        }
    }

    /// The leader's block reward for one slot, without transactions (a few hundred bytes).
    /// nil when the block isn't available yet; 0 for a skipped slot.
    public func blockReward(_ slot: UInt64, leader: String) async throws -> Int64? {
        struct Rewards: Decodable {
            struct Reward: Decodable {
                let pubkey: String
                let lamports: Int64
                let rewardType: String?
            }
            let rewards: [Reward]?
        }
        do {
            let block: Rewards = try await rpc.call("getBlock", params: [
                .int(slot),
                ["commitment": "confirmed", "transactionDetails": "none", "rewards": true, "maxSupportedTransactionVersion": 1],
            ])
            return block.rewards?.filter { $0.rewardType == "Fee" && $0.pubkey == leader }.reduce(0) { $0 + $1.lamports } ?? 0
        } catch let error as SolanaError {
            switch error.code {
            case .jsonRpcServerErrorSlotSkipped, .jsonRpcServerErrorLongTermStorageSlotSkipped: return -1
            case .jsonRpcServerErrorBlockNotAvailable: return nil
            default: throw error
            }
        }
    }

    /// When a block was produced; tries the next few slots if this one was skipped.
    public func blockTime(near slot: UInt64) async -> Date? {
        for s in slot..<(slot + 8) {
            if let t: Int64 = try? await rpc.call("getBlockTime", params: [.int(s)]) {
                return Date(timeIntervalSince1970: TimeInterval(t))
            }
        }
        return nil
    }

    public func tenureReport(_ window: LeaderWindow) async throws -> TenureReport? {
        var slots: [SlotReport] = []
        for slot in window.firstSlot..<window.endSlot {
            switch try await slotReport(slot, leader: window.identity) {
            case .produced(let r): slots.append(r)
            case .skipped: slots.append(SlotReport(slot: slot, produced: false))
            case .unavailable: return nil
            }
        }
        return TenureReport(identity: window.identity, firstSlot: window.firstSlot, slots: slots)
    }

    /// The validator's tip distribution accounts, found by vote account (offset 8) instead of deriving each epoch's PDA.
    public func tipDistributions(vote: String) async throws -> [TipDistribution] {
        struct Keyed: Decodable {
            struct Account: Decodable {
                let lamports: UInt64
                let data: [String]
            }
            let account: Account
        }
        let accounts: [Keyed] = try await rpc.call("getProgramAccounts", params: [
            .string(TipDistribution.program),
            ["encoding": "base64", "filters": [["memcmp": ["offset": 8, "bytes": .string(vote)]]]],
        ], optionsPosition: 1)
        return accounts.compactMap { a in
            guard let b64 = a.account.data.first, let data = Data(base64Encoded: b64) else { return nil }
            return TipDistribution.parse([UInt8](data), lamports: a.account.lamports)
        }.sorted { $0.epoch > $1.epoch }
    }

    public func epochProduction(identity: String, epoch: UInt64) async throws -> EpochProduction {
        let response = try await rpc.getBlockProduction(identity: try Address(identity))
        let record = response.value.byIdentity[identity]
        return EpochProduction(epoch: epoch, leaderSlots: record?.leaderSlots ?? 0, produced: record?.blocksProduced ?? 0)
    }
}

/// HTTP APIs outside the RPC: Jito's rewards and ibrl.wtf's block-building scores.
public enum ValidatorWeb {
    static func get<T: Decodable>(_ url: String, as type: T.Type = T.self) async throws -> T {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: u, timeoutInterval: 20)
        request.setValue("Sonata/1.0 (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Per-epoch MEV (and priority-fee sharing) for a vote account, newest first.
    public static func jitoRewards(vote: String) async throws -> [JitoEpochRewards] {
        try await get("https://kobe.mainnet.jito.network/api/v1/validators/\(vote)", as: [JitoEpochRewards].self)
            .sorted { $0.epoch > $1.epoch }
    }

    /// The validator's latest IBRL score.
    public static func ibrl(identity: String) async throws -> IBRLScore? {
        struct Response: Decodable {
            struct Payload: Decodable { let validator_score: Score? }
            struct Score: Decodable {
                let ibrl_score: Double
                let build_time_score: Double
                let vote_packing_score: Double
                let non_vote_packing_score: Double
                let blocks_produced: UInt64?
                let median_block_build_ms: Double?
                let epoch_trend: Double?
            }
            let data: Payload?
            let epoch: UInt64?
        }
        let r = try await get("https://explorer.bam.dev/api/v1/ibrl_validators/\(identity)", as: Response.self)
        guard let s = r.data?.validator_score, let epoch = r.epoch else { return nil }
        return IBRLScore(epoch: epoch, ibrl_score: s.ibrl_score, build_time_score: s.build_time_score,
                         vote_packing_score: s.vote_packing_score, non_vote_packing_score: s.non_vote_packing_score,
                         blocks_produced: s.blocks_produced, median_block_build_ms: s.median_block_build_ms, epoch_trend: s.epoch_trend)
    }
}
