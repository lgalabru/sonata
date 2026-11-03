import Foundation

public let lamportsPerSOL = 1_000_000_000.0

/// The validator the user pinned, resolved from either its identity or its vote account.
public struct ValidatorProfile: Codable, Sendable, Equatable {
    public let identity: String
    public let vote: String
    /// Inflation commission, percent.
    public let commission: UInt8
    public let activatedStake: UInt64
    public let delinquent: Bool

    public init(identity: String, vote: String, commission: UInt8, activatedStake: UInt64, delinquent: Bool) {
        self.identity = identity
        self.vote = vote
        self.commission = commission
        self.activatedStake = activatedStake
        self.delinquent = delinquent
    }
}

// MARK: Tenure reports

/// What one leader slot produced, from `getBlock` (transactionDetails: accounts, rewards).
public struct SlotReport: Codable, Sendable, Equatable {
    public let slot: UInt64
    public let produced: Bool
    public var transactions = 0
    public var voteTransactions = 0
    public var failedTransactions = 0
    /// Every fee paid in the block.
    public var feesLamports: UInt64 = 0
    /// The 5,000-lamport-per-signature part of those fees; half of it is burned.
    public var baseFeesLamports: UInt64 = 0
    /// What the runtime paid the leader (rewardType "Fee"): priority fees plus half the base fees.
    public var leaderRewardLamports: UInt64 = 0
    /// Tips landed on Jito's tip accounts in this block.
    public var tipsLamports: UInt64 = 0
    public var blockTime: Int64?

    public init(slot: UInt64, produced: Bool) {
        self.slot = slot
        self.produced = produced
    }

    public var priorityFeesLamports: UInt64 { feesLamports > baseFeesLamports ? feesLamports - baseFeesLamports : 0 }
    public var burnedLamports: UInt64 { baseFeesLamports / 2 }
}

/// A leader window's blocks, summed.
public struct TenureReport: Codable, Sendable, Equatable {
    public let identity: String
    public let firstSlot: UInt64
    public let slots: [SlotReport]
    public let fetchedAt: Date

    public init(identity: String, firstSlot: UInt64, slots: [SlotReport], fetchedAt: Date = Date()) {
        self.identity = identity
        self.firstSlot = firstSlot
        self.slots = slots
        self.fetchedAt = fetchedAt
    }

    public var produced: Int { slots.filter(\.produced).count }
    public var skipped: Int { slots.count - produced }
    public var transactions: Int { slots.reduce(0) { $0 + $1.transactions } }
    public var voteTransactions: Int { slots.reduce(0) { $0 + $1.voteTransactions } }
    public var nonVoteTransactions: Int { transactions - voteTransactions }
    public var feesLamports: UInt64 { slots.reduce(0) { $0 + $1.feesLamports } }
    public var priorityFeesLamports: UInt64 { slots.reduce(0) { $0 + $1.priorityFeesLamports } }
    public var baseFeesLamports: UInt64 { slots.reduce(0) { $0 + $1.baseFeesLamports } }
    public var burnedLamports: UInt64 { slots.reduce(0) { $0 + $1.burnedLamports } }
    public var leaderRewardLamports: UInt64 { slots.reduce(0) { $0 + $1.leaderRewardLamports } }
    public var tipsLamports: UInt64 { slots.reduce(0) { $0 + $1.tipsLamports } }
    public var endTime: Date? { slots.compactMap(\.blockTime).max().map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// What the skipped slots likely cost: the average produced slot's fees and tips, per skip.
    public var estimatedMissedLamports: UInt64 {
        guard produced > 0, skipped > 0 else { return 0 }
        return (leaderRewardLamports + tipsLamports) / UInt64(produced) * UInt64(skipped)
    }
}

/// Jito's tip accounts (tip-payment program PDAs): tips are SOL transfers into these.
public let jitoTipAccounts: Set<String> = [
    "96gYZGLnJYVFmbjzopPSU6QiEV5fGqZNyN9nmNhvrZU5", "HFqU5x63VTqvQss8hp11i4wVV8bD44PvwucfZ2bU7gRe",
    "Cw8CFyM9FkoMi7K7Crf6HNQqf4uEMzpKw6QNghXLvLkY", "ADaUMid9yfUytqMBgopwjb2DTLSokTSzL1zt6iGPaS49",
    "DfXygSm4jCyNCybVYYK6DwvWqjKee8pbDmJGcLWNDXjh", "ADuUkR4vqLUMWXxW9gh6D6L8pMSawimctcNZ5pGwDcEt",
    "DttWaMuVvTiduZRnguLF7jNxTgiMBZ1hyAumKUiL2KRL", "3AVi9Tg9Uo68tJfuvoKvqKNWKkC5wPdSSdeBnizKZ6jT",
]

let voteProgram = "Vote111111111111111111111111111111111111111"
public let lamportsPerSignature: UInt64 = 5_000

/// `getBlock` with transactionDetails "accounts": just enough to do the maths.
struct AccountsBlock: Decodable {
    let blockTime: Int64?
    let rewards: [Reward]?
    let transactions: [Tx]?

    struct Reward: Decodable {
        let pubkey: String
        let lamports: Int64
        let rewardType: String?
    }

    struct Tx: Decodable {
        let transaction: Inner
        let meta: Meta?
    }

    struct Inner: Decodable { let accountKeys: [Key] }

    struct Key: Decodable {
        let pubkey: String
        let signer: Bool?
    }

    struct Meta: Decodable {
        let fee: UInt64
        let preBalances: [UInt64]
        let postBalances: [UInt64]
        let err: AnyJSON?
    }
}

/// Accepts any JSON value; used where only presence matters.
struct AnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), c.decodeNil() { throw DecodingError.valueNotFound(AnyJSON.self, .init(codingPath: [], debugDescription: "null")) }
    }
}

extension SlotReport {
    init(slot: UInt64, block: AccountsBlock, leader: String) {
        self.init(slot: slot, produced: true)
        blockTime = block.blockTime
        leaderRewardLamports = UInt64(max(0, block.rewards?.filter { $0.rewardType == "Fee" && $0.pubkey == leader }
            .reduce(0) { $0 + $1.lamports } ?? 0))
        for tx in block.transactions ?? [] {
            transactions += 1
            let keys = tx.transaction.accountKeys
            if keys.contains(where: { $0.pubkey == voteProgram }) { voteTransactions += 1 }
            guard let meta = tx.meta else { continue }
            if meta.err != nil { failedTransactions += 1 }
            feesLamports += meta.fee
            baseFeesLamports += UInt64(max(1, keys.filter { $0.signer == true }.count)) * lamportsPerSignature
            for (i, key) in keys.enumerated() where jitoTipAccounts.contains(key.pubkey) {
                guard i < meta.preBalances.count, i < meta.postBalances.count, meta.postBalances[i] > meta.preBalances[i] else { continue }
                tipsLamports += meta.postBalances[i] - meta.preBalances[i]
            }
        }
        baseFeesLamports = min(baseFeesLamports, feesLamports)
    }
}

// MARK: Who gets what

/// How a tenure's revenue is divided between the validator, its stakers, Jito and the burn.
///
/// - Block rewards (priority fees + half the base fees) go to the identity account. When the
///   validator shares priority fees through Jito's priority-fee distribution, stakers get the
///   part above its priority-fee commission.
/// - Tips go to the epoch's tip distribution account; Jito takes its protocol fee, the validator
///   its MEV commission, and stakers claim the rest.
public struct RewardSplit: Sendable, Equatable {
    /// Jito's protocol fee on tips (tip router, JIP-24): 3%.
    public static let jitoFeeBps: UInt64 = 300

    public var validatorLamports: UInt64 = 0
    /// The validator's part of block rewards, and of tips; together `validatorLamports`.
    public var validatorBlockLamports: UInt64 = 0
    public var validatorMEVLamports: UInt64 = 0
    public var stakersLamports: UInt64 = 0
    public var jitoFeeLamports: UInt64 = 0
    public var burnedLamports: UInt64 = 0

    public init(_ r: TenureReport, mevCommissionBps: UInt16?, priorityFeeCommissionBps: UInt16? = nil) {
        burnedLamports = r.burnedLamports
        // Block rewards.
        var block = r.leaderRewardLamports
        if let pf = priorityFeeCommissionBps, pf < 10_000 {
            let shared = r.priorityFeesLamports * UInt64(10_000 - pf) / 10_000
            stakersLamports += min(shared, block)
            block -= min(shared, block)
        }
        validatorLamports += block
        validatorBlockLamports = block
        // Tips. Without a tip distribution account the tips still exist, but nobody's set up to share them.
        let tips = r.tipsLamports
        jitoFeeLamports = tips * Self.jitoFeeBps / 10_000
        let net = tips - jitoFeeLamports
        let commission = UInt64(min(mevCommissionBps ?? 10_000, 10_000))
        let toValidator = net * commission / 10_000
        validatorLamports += toValidator
        validatorMEVLamports = toValidator
        stakersLamports += net - toValidator
    }

    public var totalLamports: UInt64 { validatorLamports + stakersLamports + jitoFeeLamports + burnedLamports }
}

// MARK: Epoch-level data

/// The validator's tip distribution account for an epoch (Jito tip-distribution program).
public struct TipDistribution: Codable, Sendable, Equatable {
    public let epoch: UInt64
    public let commissionBps: UInt16
    /// Tips collected so far, net of the account's rent.
    public let tipsLamports: UInt64

    public static let program = "4R3gSG8BpU4t19KYj8CfnbtRpnT8gtk4dvTHxVRwc2r7"

    /// Layout (Anchor): discriminator 8, validator_vote_account 32, merkle_root_upload_authority 32,
    /// merkle_root Option<{root 32, max_total_claim u64, max_num_nodes u64, total_funds_claimed u64,
    /// num_nodes_claimed u64}>, epoch_created_at u64, validator_commission_bps u16, expires_at u64, bump u8.
    public static func parse(_ data: [UInt8], lamports: UInt64) -> TipDistribution? {
        var o = 8 + 32 + 32
        guard data.count > o else { return nil }
        let tag = data[o]
        o += 1
        if tag == 1 { o += 64 }
        guard data.count >= o + 10 else { return nil }
        func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(data[at + $1]) << (8 * UInt64($1)) } }
        let epoch = u64(o)
        let bps = UInt16(data[o + 8]) | UInt16(data[o + 9]) << 8
        let rent = UInt64(data.count + 128) * 6_960
        return TipDistribution(epoch: epoch, commissionBps: bps, tipsLamports: lamports > rent ? lamports - rent : 0)
    }
}

/// One epoch of a validator's Jito rewards (kobe.mainnet.jito.network).
public struct JitoEpochRewards: Codable, Sendable, Equatable {
    public let epoch: UInt64
    public let mev_commission_bps: UInt16
    public let mev_rewards: UInt64
    public let priority_fee_commission_bps: UInt16?
    public let priority_fee_rewards: UInt64?

    /// MEV that reached stakers that epoch.
    public var stakersLamports: UInt64 {
        let net = mev_rewards - mev_rewards * RewardSplit.jitoFeeBps / 10_000
        return net - net * UInt64(min(mev_commission_bps, 10_000)) / 10_000
    }

    /// Stakers' MEV yield annualized from this one epoch, for `stake` lamports.
    public func stakerAPY(stake: UInt64, epochsPerYear: Double = 182.6) -> Double {
        guard stake > 0 else { return 0 }
        return pow(1 + Double(stakersLamports) / Double(stake), epochsPerYear) - 1
    }
}

/// IBRL's block-building score (ibrl.wtf, via explorer.bam.dev). Its data trails the chain by days.
public struct IBRLScore: Codable, Sendable, Equatable {
    public let epoch: UInt64
    public let ibrl_score: Double
    public let build_time_score: Double
    public let vote_packing_score: Double
    public let non_vote_packing_score: Double
    public let blocks_produced: UInt64?
    public let median_block_build_ms: Double?
    public let epoch_trend: Double?
}

/// Leader slots and blocks produced so far this epoch.
public struct EpochProduction: Codable, Sendable, Equatable {
    public let epoch: UInt64
    public let leaderSlots: UInt64
    public let produced: UInt64
    public var skipRate: Double { leaderSlots == 0 ? 0 : 1 - Double(produced) / Double(leaderSlots) }
}

extension LeaderSchedule {
    /// Every window this identity leads, in order.
    public func windows(of identity: String) -> [LeaderWindow] {
        guard let index = identities.firstIndex(of: identity).map(UInt16.init) else { return [] }
        var out: [LeaderWindow] = []
        var start: Int?
        for (i, s) in slots.enumerated() {
            if s == index {
                if start == nil { start = i }
            } else if let st = start {
                out.append(LeaderWindow(identity: identity, firstSlot: firstSlot + UInt64(st), slotCount: UInt64(i - st)))
                start = nil
            }
        }
        if let st = start {
            out.append(LeaderWindow(identity: identity, firstSlot: firstSlot + UInt64(st), slotCount: UInt64(slots.count - st)))
        }
        return out
    }
}
