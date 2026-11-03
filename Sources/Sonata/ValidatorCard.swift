import SonataCore
import SwiftUI

/// The pinned validator: when it leads next, what its last tenure earned and
/// who got it, and how the epoch is going.
struct ValidatorCard: View {
    let model: SonataModel
    let watch: ValidatorWatch
    var p: Palette

    var body: some View {
        Card(p: p) {
            CardTitle(symbol: "pin", title: "Your validator", meta: watch.profile.map { shortKey($0.vote) } ?? "", p: p)
            if let profile = watch.profile {
                let pin = model.pin(profile.identity)
                HStack(spacing: 10) {
                    ValidatorAvatar(model: model, identity: profile.identity, size: 34)
                        .overlay {
                            RoundedRectangle(cornerRadius: 34 * 12 / 44, style: .continuous)
                                .strokeBorder(watch.currentWindow != nil ? p.accent : .clear, lineWidth: 1.5)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pin.displayName).font(.ui(14, .semibold)).foregroundStyle(p.l1).lineLimit(1).help(profile.identity)
                        NextTenureLine(model: model, watch: watch, p: p)
                    }
                    Spacer(minLength: 0)
                }
                if profile.delinquent {
                    Label("Delinquent: not voting", systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(11, .medium)).foregroundStyle(p.warn).padding(.top, 6)
                }
                Rectangle().fill(p.sep).frame(height: 0.5).padding(.vertical, 8)
                EarnedRow(model: model, watch: watch, p: p)
                Rectangle().fill(p.sep).frame(height: 0.5).padding(.vertical, 8)
                LastTenure(watch: watch, p: p)
                Rectangle().fill(p.sep).frame(height: 0.5).padding(.vertical, 8)
                EpochLines(watch: watch, profile: profile, epochsPerYear: model.epochsPerYear, p: p)
            } else if let error = watch.resolveError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.ui(11.5)).foregroundStyle(p.warn)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up \(shortKey(watch.address))…").font(.ui(11.5)).foregroundStyle(p.l2)
                }
            }
        }
    }
}

/// "Leading now · slot 2 of 4" or "Next tenure in 12m 04s · 23 left": reads the slot tick.
private struct NextTenureLine: View {
    let model: SonataModel
    let watch: ValidatorWatch
    var p: Palette

    var body: some View {
        let now = model.tickSlot ?? 0
        Group {
            if let w = watch.currentWindow {
                Text("Leading now · slot \(now - w.firstSlot + 1) of \(w.slotCount)").foregroundStyle(p.accent)
            } else if let next = watch.nextWindow {
                let seconds = Double(next.firstSlot > now ? next.firstSlot - now : 0) * model.slotDuration
                Text("Next tenure in ").foregroundStyle(p.l2)
                    + Text(timer(seconds)).foregroundStyle(p.accent2).fontWeight(.semibold)
                    + Text(watch.remainingThisEpoch > 1 ? " · \(watch.remainingThisEpoch) left this epoch" : "").foregroundStyle(p.l3)
            } else if watch.windows.isEmpty {
                Text("Not in the leader schedule").foregroundStyle(p.l3)
            } else {
                Text("No more tenures this epoch").foregroundStyle(p.l3)
            }
        }
        .font(.mono(11))
        .lineLimit(1)
        .contentTransition(.numericText(countsDown: true))
    }

}

/// What the validator made over the chosen period: the same period the menu bar shows.
private struct EarnedRow: View {
    let model: SonataModel
    let watch: ValidatorWatch
    var p: Palette
    @AppStorage(EarningsPeriod.defaultsKey) private var period: EarningsPeriod = .epoch

    var body: some View {
        let total = watch.earnings(for: period)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("EARNED").font(.ui(9.5, .semibold)).tracking(1.1).foregroundStyle(p.l3)
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(EarningsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(period.title).font(.ui(11, .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .foregroundStyle(p.l2)
                Spacer(minLength: 4)
                if let total {
                    Text((total.estimated ? "≈ " : "") + sol(total.revenue) + " SOL")
                        .font(.mono(13, .semibold)).foregroundStyle(p.l1)
                        .contentTransition(.numericText())
                } else {
                    Text("—").font(.mono(13, .semibold)).foregroundStyle(p.l3)
                }
            }
            if let total {
                HStack(spacing: 9) {
                    part("Blocks", total.blockRewards)
                    part("MEV", total.mev)
                    if total.inflation > 0 { part("Inflation", total.inflation) }
                    Spacer(minLength: 0)
                    if total.voteCost > 0 {
                        Text("−\(sol(total.voteCost)) votes").foregroundStyle(p.l3).fixedSize()
                    }
                }
                .font(.mono(10.5)).lineLimit(1)
                .help("Revenue: block rewards you keep, your MEV commission and inflation commission. Vote costs are shown apart; net \(sol(UInt64(max(0, total.net)))) SOL.")
                if let from = total.coveredFrom, period != .lastTenure, period != .epoch {
                    Text("Covers since \(from.formatted(.dateTime.month(.abbreviated).day())); older epochs fill in as Sonata keeps running")
                        .font(.ui(10)).foregroundStyle(p.l3).lineLimit(2)
                }
            } else if period == .lastTenure {
                Text("After your next tenure").font(.ui(10.5)).foregroundStyle(p.l3)
            }
            if watch.backfill.total > 0, watch.backfill.done < watch.backfill.total, period != .lastTenure {
                HStack(spacing: 6) {
                    ProgressView(value: Double(watch.backfill.done), total: Double(watch.backfill.total))
                        .progressViewStyle(.linear).controlSize(.mini).tint(p.accent2)
                    Text("Reading this epoch's blocks · \(watch.backfill.done.formatted())/\(watch.backfill.total.formatted())")
                        .font(.ui(10)).foregroundStyle(p.l3).lineLimit(1).fixedSize()
                }
                .help("Each of your blocks is read once (its fee reward) and cached; until all are read, the epoch's block rewards are extrapolated.")
            }
        }
    }

    private func part(_ label: String, _ lamports: UInt64) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(p.l3)
            Text(sol(lamports)).foregroundStyle(p.l2)
        }
        .fixedSize()
    }
}

/// The last tenure: blocks, fees, tips, transactions, and the split.
private struct LastTenure: View {
    let watch: ValidatorWatch
    var p: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("LAST TENURE").font(.ui(9.5, .semibold)).tracking(1.1).foregroundStyle(p.l3)
                if let r = watch.lastReport {
                    SlotPips(report: r, p: p)
                    Spacer(minLength: 4)
                    if let end = r.endTime {
                        Text(end, format: .relative(presentation: .named)).font(.ui(10.5)).foregroundStyle(p.l3)
                    }
                } else {
                    Spacer(minLength: 4)
                    if watch.loadingReport { ProgressView().controlSize(.mini) }
                }
            }
            if let r = watch.lastReport, let split = watch.split {
                HStack(alignment: .top, spacing: 0) {
                    Stat(value: sol(r.leaderRewardLamports), label: "Block rewards", p: p)
                    Stat(value: sol(r.tipsLamports), label: "MEV tips", p: p)
                    Stat(value: r.nonVoteTransactions.formatted(), label: "User txs", p: p)
                }
                SplitBar(split: split, p: p)
                if r.skipped > 0 {
                    Label("\(r.skipped) skipped · ~\(sol(r.estimatedMissedLamports)) SOL missed", systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(10.5, .medium)).foregroundStyle(p.warn)
                }
            } else {
                Text(watch.lastWindow == nil ? "No tenure yet in the schedules held" : "Summing the blocks…")
                    .font(.ui(11)).foregroundStyle(p.l3)
            }
        }
    }
}

/// One pip per slot: produced or skipped.
private struct SlotPips: View {
    var report: TenureReport
    var p: Palette

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(report.slots, id: \.slot) { s in
                Circle().fill(s.produced ? p.accent : p.down).frame(width: 5, height: 5)
            }
        }
        .help("\(report.produced) of \(report.slots.count) blocks produced")
    }
}

private struct Stat: View {
    var value: String
    var label: String
    var p: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.mono(13, .semibold)).foregroundStyle(p.l1).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.ui(10)).foregroundStyle(p.l3).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Who got the tenure's revenue: the validator, its stakers, Jito, and the burn.
private struct SplitBar: View {
    var split: RewardSplit
    var p: Palette

    var body: some View {
        let parts: [(String, UInt64, Color)] = [
            ("You", split.validatorLamports, p.accent),
            ("Stakers", split.stakersLamports, p.accent2),
            ("Jito", split.jitoFeeLamports, p.l3),
            ("Burned", split.burnedLamports, p.warn.opacity(0.8)),
        ]
        let total = Double(max(split.totalLamports, 1))
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                        Capsule().fill(part.2).frame(width: max(2, (g.size.width - 6) * Double(part.1) / total))
                    }
                }
            }
            .frame(height: 5)
            HStack(spacing: 0) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.2).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(sol(part.1)).foregroundStyle(part.0 == "You" || part.0 == "Stakers" ? p.l1 : p.l2).fontWeight(.medium)
                            Text(part.0).font(.ui(9.5)).foregroundStyle(p.l3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .help("Block rewards stay with your identity\(split.stakersLamports > 0 ? " (minus any priority fees you share)" : ""). Tips: Jito takes 3%, your MEV commission comes to you, the rest goes to stakers. Half of every base fee is burned.")
            .font(.mono(10.5)).lineLimit(1)
        }
    }
}

/// The epoch so far, and the slower numbers: Jito's last epoch and IBRL.
private struct EpochLines: View {
    let watch: ValidatorWatch
    let profile: ValidatorProfile
    var epochsPerYear: Double
    var p: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let prod = watch.production, prod.leaderSlots > 0 {
                    Text("\(prod.produced.formatted())/\(prod.leaderSlots.formatted()) blocks · \(prod.skipRate.formatted(.percent.precision(.fractionLength(1)))) skip")
                        .foregroundStyle(prod.skipRate > 0.05 ? p.warn : p.l2)
                } else {
                    Text("No blocks yet this epoch").foregroundStyle(p.l3)
                }
                Spacer(minLength: 6)
                if let tda = watch.tipDistribution {
                    Text("Epoch MEV \(sol(tda.tipsLamports, digits: 2)) SOL").foregroundStyle(p.l1).fontWeight(.medium)
                        .help("Tips collected this epoch in the tip distribution account, before Jito's fee and your \(Double(tda.commissionBps) / 100, specifier: "%.0f")% commission")
                }
            }
            HStack {
                if let last = watch.jito.first(where: { $0.mev_rewards > 0 }) {
                    Text("Stakers' MEV APY \(last.stakerAPY(stake: profile.activatedStake, epochsPerYear: epochsPerYear).formatted(.percent.precision(.fractionLength(2))))")
                        .foregroundStyle(p.l2)
                        .help("Epoch \(last.epoch): \(sol(last.mev_rewards, digits: 2)) SOL of MEV, \(last.mev_commission_bps / 100)% commission, annualized over \(profile.activatedStake / UInt64(lamportsPerSOL)) SOL staked")
                }
                Spacer(minLength: 6)
                if let ibrl = watch.ibrl {
                    Text("IBRL \(ibrl.ibrl_score, specifier: "%.1f")").foregroundStyle(p.l1).fontWeight(.medium)
                        + Text(" · e\(ibrl.epoch)").foregroundStyle(p.l3)
                }
            }
            .help(watch.ibrl.map { "Block building (ibrl.wtf, epoch \($0.epoch)): build time \(Int($0.build_time_score)), vote packing \(Int($0.vote_packing_score)), non-vote packing \(Int($0.non_vote_packing_score))" } ?? "")
            Text("\(profile.commission)% commission · \(watch.tipDistribution.map { "\($0.commissionBps / 100)%" } ?? "–") on MEV · \((Double(profile.activatedStake) / lamportsPerSOL).formatted(.number.notation(.compactName).precision(.significantDigits(3)))) SOL staked")
                .foregroundStyle(p.l3)
        }
        .font(.mono(10.5)).lineLimit(1)
    }
}

/// Lamports as SOL: four decimals below 1, two above.
func sol(_ lamports: UInt64, digits: Int? = nil) -> String {
    let v = Double(lamports) / lamportsPerSOL
    let d = digits ?? (v >= 1 ? 2 : 4)
    return v.formatted(.number.precision(.fractionLength(d)))
}

/// A countdown as a timer reads: mm:ss under an hour, hh:mm:ss from an hour.
func timer(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded()))
    let h = t / 3_600, m = t % 3_600 / 60, s = t % 60
    return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
