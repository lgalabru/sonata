import Foundation

/// Earnings over time for the pinned validator.
///
/// Caching (per RPC host, under ~/Library/Caches/sonata/<host>/):
/// - `earnings-<vote>.json`: every epoch record ever seen, kept forever. Trillium only serves the last
///   ten epochs, so longer periods fill in as Sonata keeps running.
/// - `blockrewards-<identity>-<epoch>.json`: the leader reward of each of the validator's slots in the
///   current and previous epoch. A block is read once; files older than three epochs are deleted.
/// - `epoch-times.json`: when each epoch started, kept forever.
extension ValidatorWatch {
    /// Seconds between block reads. Solana's public endpoints allow 6 getBlock calls per 10s (shared with
    /// tenure reports), so stay under that; other RPCs start faster and back off on 429s.
    static func blockInterval(_ endpoint: URL) -> Double {
        endpoint.host?.hasSuffix("solana.com") == true ? 1.8 : 0.25
    }

    var earningsFile: String { "earnings-\(profile?.vote.prefix(16) ?? "none").json" }
    func rewardsFile(_ epoch: UInt64) -> String { "blockrewards-\(profile?.identity.prefix(16) ?? "none")-\(epoch).json" }

    func loadEarnings(_ profile: ValidatorProfile) {
        if let saved: [EpochEarnings] = cache.read(earningsFile) {
            setEarnings(Dictionary(saved.map { ($0.epoch, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        if let times: [String: Date] = cache.read("epoch-times.json") {
            for (k, v) in times { if let e = UInt64(k) { epochStarts[e] = v } }
        }
    }

    func saveEarnings() {
        cache.write(earnings.values.sorted { $0.epoch < $1.epoch }, to: earningsFile)
    }

    func saveEpochTimes() {
        cache.write(Dictionary(uniqueKeysWithValues: epochStarts.map { (String($0.key), $0.value) }), to: "epoch-times.json")
    }

    // MARK: Refresh

    func refreshEarnings(_ rpc: RPCClient, profile: ValidatorProfile) async {
        guard let info = model.epoch else { return }
        let current = info.epoch

        // Completed epochs, from Trillium, every six hours (an epoch appears there some time after it ends).
        if due("trillium", every: 6 * 3_600) {
            if let rows = try? await ValidatorWeb.trilliumRewards(profile.vote) {
                var all = earnings
                for row in rows where row.epoch < current {
                    var start = all[row.epoch]?.start ?? epochStarts[row.epoch]
                    var end = all[row.epoch]?.end
                    if start == nil || end == nil, let t = try? await ValidatorWeb.trilliumEpochTimes(row.epoch) {
                        start = start ?? t.start
                        end = end ?? t.end
                        epochStarts[row.epoch] = start
                    }
                    all[row.epoch] = row.earnings(start: start, end: end)
                }
                setEarnings(all)
                saveEarnings()
                saveEpochTimes()
            } else {
                refreshed["trillium"] = Date().addingTimeInterval(-5.5 * 3_600)  // retry in 30 minutes
            }
        }

        // Epoch start times for the epochs Sonata sums itself.
        for (epoch, first) in [(current, info.firstSlot), (current - 1, info.firstSlot - info.slotsInEpoch)]
        where epochStarts[epoch] == nil && due("epoch-start-\(epoch)", every: 300) {
            if let t = await rpc.blockTime(near: first) {
                epochStarts[epoch] = t
                saveEpochTimes()
            }
        }

        // The previous epoch until Trillium has it: its schedule, and its inflation commission.
        if earnings[current - 1]?.source != .trillium {
            if model.book.schedules[current - 1] == nil, due("previous-schedule-earnings", every: 600) {
                await model.loadPreviousEpochSchedule()
            }
            if due("inflation-\(current - 1)", every: 1_800), let commission = try? await rpc.inflationCommission(vote: profile.vote, epoch: current - 1) {
                inflationSeen[current - 1] = commission
            }
        }

        updateLocal(current: current, info: info)
        startBackfill(rpc, profile: profile)
    }

    /// Rebuilds the records Sonata sums itself (current epoch, and the previous one until Trillium has it).
    func updateLocal(current: UInt64, info: EpochInfo) {
        var all = earnings
        let latestTrillium = all.values.filter { $0.source == .trillium }.max { $0.epoch < $1.epoch }
        for epoch in [current - 1, current] where all[epoch]?.source != .trillium {
            guard let schedule = model.book.schedules[epoch] else { continue }
            let mine = schedule.windows(of: profile?.identity ?? "")
            let now = model.tickSlot ?? info.absoluteSlot
            let due = mine.filter { $0.endSlot + 64 <= now }.flatMap { Array($0.firstSlot..<$0.endSlot) }
            if slotRewards[epoch] == nil { slotRewards[epoch] = loadRewards(epoch) }  // what earlier runs read
            let read = slotRewards[epoch] ?? [:]
            let produced = read.values.filter { $0 >= 0 }
            var block = UInt64(produced.reduce(0, +))
            let missing = due.filter { read[$0] == nil }.count
            // While blocks are still being read, extrapolate the rest from a typical block: the blocks read
            // so far without outliers (one whale's priority fee can be worth hundreds of blocks; it counts
            // once, in the sum above), blended with the last completed epoch's average (weight 200 blocks).
            if missing > 0 {
                let prior = latestTrillium.flatMap { r in r.blocks.flatMap { $0 > 0 ? Double(r.blockRewards) / Double($0) : nil } }
                let typical = Self.trimmed(produced)
                let weight = prior == nil ? 0.0 : 200
                let n = Double(typical.count)
                if n + weight > 0 {
                    let average = (Double(typical.reduce(0, +)) + (prior ?? 0) * weight) / (n + weight)
                    let skipRate = production.map { $0.skipRate } ?? 0.03
                    block += UInt64(average * Double(missing) * (1 - skipRate))
                }
            }
            var record = all[epoch] ?? EpochEarnings(epoch: epoch, source: .local)
            record.blockRewards = block
            record.estimated = missing > 0
            record.start = epochStarts[epoch]
            record.end = epoch < current ? epochStarts[epoch + 1] : nil
            // MEV: the tip distribution account's tips so far (current), or Jito's figure once the epoch's done.
            if epoch == current, let tda = tipDistribution, tda.epoch == epoch {
                let net = tda.tipsLamports - tda.tipsLamports * RewardSplit.jitoFeeBps / 10_000
                record.mev = net * UInt64(tda.commissionBps) / 10_000
            } else if let j = jito.first(where: { $0.epoch == epoch }) {
                let net = j.mev_rewards - j.mev_rewards * RewardSplit.jitoFeeBps / 10_000
                record.mev = net * UInt64(j.mev_commission_bps) / 10_000
            }
            if let inflation = inflationSeen[epoch] { record.inflation = inflation }
            // Vote costs: as the last epoch Trillium has, prorated over the time elapsed.
            if let cost = latestTrillium?.voteCost {
                let fraction = epoch < current ? 1 : min(Double(now - schedule.firstSlot) / Double(schedule.slotsInEpoch), 1)
                record.voteCost = UInt64(Double(cost) * fraction)
            }
            all[epoch] = record
            if epoch == current { setBackfill(done: due.count - missing, total: due.count) }
        }
        if all != earnings {
            setEarnings(all)
            saveEarnings()
        }
    }

    /// Reads, one at a time and paced, every block of ours not read yet (newest epoch first).
    func startBackfill(_ rpc: RPCClient, profile: ValidatorProfile) {
        guard backfillTask == nil, let info = model.epoch else { return }
        let current = info.epoch
        // Seed from the last tenure's report, which already summed those blocks.
        if let r = lastReport, let schedule = model.book.schedule(containing: r.firstSlot) {
            var map = slotRewards[schedule.epoch] ?? loadRewards(schedule.epoch)
            for s in r.slots where map[s.slot] == nil { map[s.slot] = s.produced ? Int64(s.leaderRewardLamports) : -1 }
            slotRewards[schedule.epoch] = map
        }
        backfillTask = Task { [weak self] in
            defer { self?.backfillTask = nil }
            for epoch in [current, current - 1] {
                guard let self, !Task.isCancelled else { return }
                if epoch < current, self.earnings[epoch]?.source == .trillium { continue }
                guard let schedule = self.model.book.schedules[epoch] else { continue }
                var map = self.slotRewards[epoch] ?? self.loadRewards(epoch)
                let now = self.model.tickSlot ?? info.absoluteSlot
                let todo = schedule.windows(of: profile.identity).filter { $0.endSlot + 64 <= now }
                    .flatMap { Array($0.firstSlot..<$0.endSlot) }.filter { map[$0] == nil }.reversed()
                var sinceSave = 0
                let floor = Self.blockInterval(rpc.endpoint)
                var delay = floor
                var queue = Array(todo)
                while let slot = queue.first {
                    guard !Task.isCancelled else { return }
                    // The last tenure's report goes first: it shares the getBlock budget.
                    if self.reportPending {
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    do {
                        if let reward = try await rpc.blockReward(slot, leader: profile.identity) { map[slot] = reward }
                        queue.removeFirst()
                        sinceSave += 1
                        delay = max(floor, delay * 0.9)
                    } catch where RPCClient.isRateLimited(error) {
                        // Public endpoints throttle getBlock: back off and retry the same block.
                        delay = min(max(delay * 2, 10), 60)  // the public RPC says retry after 10s
                        sonataLog("backfill rate limited, waiting \(delay)s")
                    } catch {
                        queue.removeFirst()  // try it again on the next pass
                        sonataLog("backfill \(slot): \(error)")
                    }
                    if sinceSave >= 20 {
                        self.slotRewards[epoch] = map
                        self.cache.write(Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) }), to: self.rewardsFile(epoch))
                        self.updateLocal(current: current, info: info)
                        sinceSave = 0
                    }
                    try? await Task.sleep(for: .seconds(delay))
                }
                self.slotRewards[epoch] = map
                self.cache.write(Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) }), to: self.rewardsFile(epoch))
                self.updateLocal(current: current, info: info)
            }
            self?.pruneRewardFiles(keepFrom: current - 2)
        }
    }

    /// Block rewards without outliers: those over 10× the median.
    static func trimmed(_ values: [Int64]) -> [Int64] {
        guard values.count > 2 else { return values }
        let median = values.sorted()[values.count / 2]
        return values.filter { $0 <= max(median, 1) * 10 }
    }

    func loadRewards(_ epoch: UInt64) -> [UInt64: Int64] {
        guard let saved: [String: Int64] = cache.read(rewardsFile(epoch)) else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in UInt64(k).map { ($0, v) } })
    }

    func pruneRewardFiles(keepFrom epoch: UInt64) {
        for name in cache.files(prefix: "blockrewards-") {
            if let e = UInt64(name.split(separator: "-").last?.dropLast(5) ?? ""), e < epoch { cache.remove(name) }
        }
    }

    // MARK: Totals

    /// What the validator made over `period`; nil when there's nothing to show yet.
    public func earnings(for period: EarningsPeriod, now: Date = Date()) -> EarningsTotal? {
        switch period {
        case .lastTenure:
            guard let split else { return nil }
            var t = EarningsTotal()
            t.blockRewards = split.validatorBlockLamports
            t.mev = split.validatorMEVLamports
            return t
        case .epoch:
            guard let e = model.epoch?.epoch, let r = earnings[e] else { return nil }
            return .from(r)
        case .week, .month, .monthToDate:
            guard let start = period.start(now: now), !earnings.isEmpty else { return nil }
            return .sum(Array(earnings.values), from: start, now: now)
        }
    }
}

extension RPCClient {
    /// The vote account's inflation reward for `epoch`, which is its commission.
    func inflationCommission(vote: String, epoch: UInt64) async throws -> UInt64? {
        struct Reward: Decodable { let amount: UInt64 }
        let rewards: [Reward?] = try await rpc.call("getInflationReward", params: [.array([.string(vote)]), ["epoch": .int(epoch)]])
        return rewards.first??.amount
    }
}

/// Logs when launched with SONATA_DEBUG set.
func sonataLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["SONATA_DEBUG"] != nil { NSLog("sonata %@", message()) }
}
