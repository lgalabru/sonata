import Foundation
import Testing
@testable import SonataCore

@Suite struct EarningsTests {
    let day = 86_400.0
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Back-to-back one-day epochs ending now; the newest still running.
    func records(_ count: Int) -> [EpochEarnings] {
        (0..<count).map { i in
            let start = now.addingTimeInterval(-Double(count - i) * day)
            let running = i == count - 1
            return EpochEarnings(epoch: UInt64(100 + i), blockRewards: 1_000, mev: 100, inflation: 10, voteCost: 5,
                                 start: start, end: running ? nil : start.addingTimeInterval(day), source: .trillium)
        }
    }

    @Test func weekSumsSevenWholeEpochs() {
        let t = EarningsTotal.sum(records(10), from: now.addingTimeInterval(-7 * day), now: now)
        #expect(t.blockRewards == 7_000)
        #expect(t.mev == 700)
        #expect(t.inflation == 70)
        #expect(t.revenue == 7_770)
        #expect(t.net == 7_770 - 35)
        #expect(t.coveredFrom == nil)
    }

    @Test func straddlingEpochIsProrated() {
        // 2.5 days back: two whole epochs and half of the one before.
        let t = EarningsTotal.sum(records(10), from: now.addingTimeInterval(-2.5 * day), now: now)
        #expect(t.blockRewards == 2_500)
    }

    @Test func runningEpochCountsWhatItHasSoFar() {
        var r = records(3)
        // Started 6 hours ago and has earned 400 so far: all of it is in a 12-hour window.
        r[2] = EpochEarnings(epoch: 102, blockRewards: 400, start: now.addingTimeInterval(-6 * 3_600), source: .local, estimated: true)
        let t = EarningsTotal.sum(r, from: now.addingTimeInterval(-12 * 3_600), now: now)
        #expect(t.blockRewards == 400)  // the epoch before ended a day ago, outside the window
        #expect(t.estimated)
    }

    @Test func shortHistoryReportsCoverage() {
        let t = EarningsTotal.sum(records(3), from: now.addingTimeInterval(-30 * day), now: now)
        #expect(t.blockRewards == 3_000)
        #expect(t.coveredFrom == now.addingTimeInterval(-3 * day))
    }

    @Test func monthToDateStartsOnTheFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = try #require(EarningsPeriod.monthToDate.start(now: now, calendar: calendar))
        #expect(calendar.component(.day, from: start) == 1)
        #expect(calendar.component(.hour, from: start) == 0)
        #expect(start <= now)
    }

    @Test func trilliumRowToLamports() throws {
        let json = #"{"epoch": 1074, "validator_priority_fees": 48.37, "validator_signature_fees": 3.44749, "rewards": 51.81749, "mev_to_validator": 0.3005, "validator_inflation_reward": 0.0, "vote_cost": 0.8}"#
        let row = try JSONDecoder().decode(TrilliumEpoch.self, from: Data(json.utf8))
        let e = row.earnings(start: nil, end: nil)
        #expect(e.blockRewards == 51_817_490_000)
        #expect(e.mev == 300_500_000)
        #expect(e.voteCost == 800_000_000)
        #expect(e.revenue == 52_117_990_000)
    }
}

@Suite @MainActor struct EstimatorTests {
    @Test func outliersAreNotExtrapolated() {
        let blocks: [Int64] = [5_000_000, 10_000_000, 6_000_000, 4_061_336_471, 7_000_000]
        let typical = ValidatorWatch.trimmed(blocks)
        #expect(typical.count == 4)
        #expect(!typical.contains(4_061_336_471))
    }
}
