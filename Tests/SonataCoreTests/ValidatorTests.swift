import Foundation
import Testing
@testable import SonataCore

@Suite struct ValidatorTests {
    static let leader = "LeaderIdentity1111111111111111111111111111"
    static let tip = "96gYZGLnJYVFmbjzopPSU6QiEV5fGqZNyN9nmNhvrZU5"

    /// A block with a vote, a tipped bundle transaction (2 signers) and a failed transaction.
    static let blockJSON = """
    {"blockTime": 1793676494,
     "rewards": [{"pubkey": "\(leader)", "lamports": 110000, "rewardType": "Fee"}],
     "transactions": [
       {"transaction": {"accountKeys": [{"pubkey": "voter", "signer": true}, {"pubkey": "Vote111111111111111111111111111111111111111", "signer": false}]},
        "meta": {"fee": 5000, "preBalances": [10, 1], "postBalances": [5, 1], "err": null}},
       {"transaction": {"accountKeys": [{"pubkey": "searcher", "signer": true}, {"pubkey": "cosigner", "signer": true}, {"pubkey": "\(tip)", "signer": false}]},
        "meta": {"fee": 110000, "preBalances": [5000000, 0, 100], "postBalances": [3890000, 0, 1000100], "err": null}},
       {"transaction": {"accountKeys": [{"pubkey": "bot", "signer": true}]},
        "meta": {"fee": 5000, "preBalances": [100000], "postBalances": [95000], "err": {"InstructionError": [0, "Custom"]}}}
     ]}
    """

    func report() throws -> TenureReport {
        let block = try JSONDecoder().decode(AccountsBlock.self, from: Data(Self.blockJSON.utf8))
        let produced = SlotReport(slot: 100, block: block, leader: Self.leader)
        return TenureReport(identity: Self.leader, firstSlot: 100,
                            slots: [produced, produced, produced, SlotReport(slot: 103, produced: false)])
    }

    @Test func slotMaths() throws {
        let block = try JSONDecoder().decode(AccountsBlock.self, from: Data(Self.blockJSON.utf8))
        let s = SlotReport(slot: 100, block: block, leader: Self.leader)
        #expect(s.transactions == 3)
        #expect(s.voteTransactions == 1)
        #expect(s.failedTransactions == 1)
        #expect(s.feesLamports == 120_000)
        #expect(s.baseFeesLamports == 20_000)  // 4 signatures
        #expect(s.priorityFeesLamports == 100_000)
        #expect(s.burnedLamports == 10_000)
        // The leader's reward is priority fees plus half the base fees.
        #expect(s.leaderRewardLamports == s.priorityFeesLamports + s.baseFeesLamports / 2)
        #expect(s.tipsLamports == 1_000_000)
    }

    @Test func tenureTotalsAndMissed() throws {
        let r = try report()
        #expect(r.produced == 3 && r.skipped == 1)
        #expect(r.tipsLamports == 3_000_000)
        #expect(r.leaderRewardLamports == 330_000)
        #expect(r.estimatedMissedLamports == 110_000 + 1_000_000)
    }

    @Test func splitWithMEVCommission() throws {
        let r = try report()
        let split = RewardSplit(r, mevCommissionBps: 700)
        // Tips 3,000,000: Jito 3% = 90,000; net 2,910,000; validator 7% = 203,700; stakers 2,706,300.
        #expect(split.jitoFeeLamports == 90_000)
        #expect(split.validatorLamports == 330_000 + 203_700)
        #expect(split.stakersLamports == 2_706_300)
        #expect(split.burnedLamports == 30_000)
        #expect(split.totalLamports == r.leaderRewardLamports + r.tipsLamports + r.burnedLamports)
    }

    @Test func splitSharingPriorityFees() throws {
        let r = try report()
        // Keeping 50% of priority fees: stakers get half of the 300,000 priority lamports.
        let split = RewardSplit(r, mevCommissionBps: 10_000, priorityFeeCommissionBps: 5_000)
        #expect(split.stakersLamports == 150_000)
        #expect(split.validatorLamports == 330_000 - 150_000 + 2_910_000)
    }

    @Test func tipDistributionLayout() {
        // discriminator, vote, authority, Some(merkle root), epoch 1075, 700 bps, expires, bump.
        var data = [UInt8](repeating: 0, count: 8 + 32 + 32)
        data.append(1)
        data += [UInt8](repeating: 7, count: 64)
        data += withUnsafeBytes(of: UInt64(1075).littleEndian, Array.init)
        data += withUnsafeBytes(of: UInt16(700).littleEndian, Array.init)
        data += withUnsafeBytes(of: UInt64(1085).littleEndian, Array.init)
        data.append(255)
        let rent = UInt64(data.count + 128) * 6_960
        let t = TipDistribution.parse(data, lamports: rent + 18_000_000_000)
        #expect(t == TipDistribution(epoch: 1075, commissionBps: 700, tipsLamports: 18_000_000_000))
    }

    @Test func windowsOfIdentity() {
        let schedule = LeaderSchedule(epoch: 1, firstSlot: 1_000, slotsInEpoch: 16,
                                      rpc: ["A": [0, 1, 2, 3, 12, 13, 14, 15], "B": Array(4..<12)] as [String: [UInt64]])
        #expect(schedule.windows(of: "A") == [LeaderWindow(identity: "A", firstSlot: 1_000, slotCount: 4),
                                              LeaderWindow(identity: "A", firstSlot: 1_012, slotCount: 4)])
        #expect(schedule.windows(of: "B") == [LeaderWindow(identity: "B", firstSlot: 1_004, slotCount: 8)])
        #expect(schedule.windows(of: "C").isEmpty)
    }

    @Test func stakerAPY() {
        let e = JitoEpochRewards(epoch: 1074, mev_commission_bps: 700, mev_rewards: 15_878_899_741,
                                 priority_fee_commission_bps: 0, priority_fee_rewards: 0)
        let apy = e.stakerAPY(stake: 17_034_353 * 1_000_000_000)
        #expect(apy > 0.0001 && apy < 0.01)
    }
}
