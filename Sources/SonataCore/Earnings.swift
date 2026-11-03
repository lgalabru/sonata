import Foundation

/// What a validator made in one epoch, in lamports.
public struct EpochEarnings: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Trillium's per-epoch rewards (completed epochs).
        case trillium
        /// Summed by Sonata: block rewards from the validator's own blocks, MEV from its tip distribution account.
        case local
    }

    public let epoch: UInt64
    /// Block rewards kept by the validator: priority fees plus the unburned half of base fees
    /// (less any priority fees shared with stakers).
    public var blockRewards: UInt64
    /// The validator's MEV commission.
    public var mev: UInt64
    /// The validator's inflation commission (paid at the epoch's end).
    public var inflation: UInt64
    /// Vote transaction fees paid.
    public var voteCost: UInt64
    public var start: Date?
    public var end: Date?
    public var source: Source
    /// Block rewards partly extrapolated while Sonata is still reading the epoch's blocks.
    public var estimated: Bool
    /// Blocks produced, when known (Trillium).
    public var blocks: UInt64?

    public init(epoch: UInt64, blockRewards: UInt64 = 0, mev: UInt64 = 0, inflation: UInt64 = 0, voteCost: UInt64 = 0,
                start: Date? = nil, end: Date? = nil, source: Source, estimated: Bool = false) {
        self.epoch = epoch
        self.blockRewards = blockRewards
        self.mev = mev
        self.inflation = inflation
        self.voteCost = voteCost
        self.start = start
        self.end = end
        self.source = source
        self.estimated = estimated
    }

    /// Everything the validator earned, before vote costs.
    public var revenue: UInt64 { blockRewards + mev + inflation }
}

/// The time span the menu bar's earnings cover.
public enum EarningsPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case lastTenure, epoch, week, month, monthToDate

    public var id: Self { self }

    public var title: String {
        switch self {
        case .lastTenure: "Last tenure"
        case .epoch: "This epoch"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .monthToDate: "This month"
        }
    }

    /// Short form for tight spots.
    public var short: String {
        switch self {
        case .lastTenure: "tenure"
        case .epoch: "epoch"
        case .week: "7d"
        case .month: "30d"
        case .monthToDate: "MTD"
        }
    }

    /// Where a calendar period starts; nil for the tenure and epoch periods.
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        case .monthToDate: calendar.dateInterval(of: .month, for: now)?.start
        case .lastTenure, .epoch: nil
        }
    }

    public static let defaultsKey = "earningsPeriod"
}

/// A period's earnings, summed from epoch records.
public struct EarningsTotal: Sendable, Equatable {
    public var blockRewards: UInt64 = 0
    public var mev: UInt64 = 0
    public var inflation: UInt64 = 0
    public var voteCost: UInt64 = 0
    /// Some block rewards are extrapolated.
    public var estimated = false
    /// The records don't reach back to the period's start: this is when they begin.
    public var coveredFrom: Date?

    public init() {}

    public var revenue: UInt64 { blockRewards + mev + inflation }
    public var net: Int64 { Int64(revenue) - Int64(voteCost) }

    /// Sums `records` over [start, now], prorating epochs that straddle the start by time.
    /// The current epoch (no end) counts what it has earned so far.
    public static func sum(_ records: [EpochEarnings], from start: Date, now: Date) -> EarningsTotal {
        var t = EarningsTotal()
        var earliest: Date?
        for r in records {
            guard let s = r.start else { continue }
            let e = r.end ?? now
            guard e > start, s < now else { continue }
            let span = max(e.timeIntervalSince(s), 1)
            let overlap = min(e, now).timeIntervalSince(max(s, start))
            let f = min(max(overlap / span, 0), 1)
            func part(_ v: UInt64) -> UInt64 { UInt64((Double(v) * f).rounded()) }
            t.blockRewards += part(r.blockRewards)
            t.mev += part(r.mev)
            t.inflation += part(r.inflation)
            t.voteCost += part(r.voteCost)
            t.estimated = t.estimated || r.estimated
            earliest = min(earliest ?? s, s)
        }
        if let earliest, earliest > start.addingTimeInterval(3_600) { t.coveredFrom = earliest }
        if earliest == nil { t.coveredFrom = now }
        return t
    }

    public static func from(_ r: EpochEarnings) -> EarningsTotal {
        var t = EarningsTotal()
        t.blockRewards = r.blockRewards
        t.mev = r.mev
        t.inflation = r.inflation
        t.voteCost = r.voteCost
        t.estimated = r.estimated
        return t
    }
}

// MARK: Trillium

/// One epoch of a validator's rewards from Trillium (api.trillium.so, CC BY 4.0). Amounts in SOL.
struct TrilliumEpoch: Decodable {
    let epoch: UInt64
    let validator_priority_fees: Double?
    let validator_signature_fees: Double?
    let rewards: Double?
    let mev_to_validator: Double?
    let validator_inflation_reward: Double?
    let vote_cost: Double?
    let blocks_produced: UInt64?

    func earnings(start: Date?, end: Date?) -> EpochEarnings {
        func lamports(_ sol: Double?) -> UInt64 { UInt64(max(0, ((sol ?? 0) * lamportsPerSOL).rounded())) }
        let block = (validator_priority_fees != nil || validator_signature_fees != nil)
            ? lamports(validator_priority_fees) + lamports(validator_signature_fees) : lamports(rewards)
        var e = EpochEarnings(epoch: epoch, blockRewards: block, mev: lamports(mev_to_validator),
                              inflation: lamports(validator_inflation_reward), voteCost: lamports(vote_cost),
                              start: start, end: end, source: .trillium)
        e.blocks = blocks_produced
        return e
    }
}

struct TrilliumEpochData: Decodable {
    let epoch: UInt64
    let min_block_time: Int64?
    let max_block_time: Int64?
}

extension ValidatorWeb {
    /// The validator's last ten completed epochs.
    static func trilliumRewards(_ address: String) async throws -> [TrilliumEpoch] {
        try await get("https://api.trillium.so/validator_rewards/\(address)", as: [TrilliumEpoch].self)
    }

    /// When an epoch started and ended (first and last block times).
    static func trilliumEpochTimes(_ epoch: UInt64) async throws -> (start: Date, end: Date)? {
        let d = try await get("https://api.trillium.so/epoch_data/\(epoch)", as: TrilliumEpochData.self)
        guard let a = d.min_block_time, let b = d.max_block_time else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(a)), Date(timeIntervalSince1970: TimeInterval(b)))
    }
}
