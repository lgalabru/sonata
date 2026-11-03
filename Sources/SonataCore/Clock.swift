import Foundation

/// Extrapolates the cluster's slot between RPC polls (~400ms per slot) and
/// never runs backwards by small amounts, so animations stay smooth.
public struct SlotClock: Sendable, Equatable {
    public private(set) var anchorSlot: Double
    public private(set) var anchorTime: Date
    private var floorSlot: Double
    public var slotDuration: TimeInterval
    /// How far past the last observation we're willing to extrapolate.
    public var maxLead: Double = 25

    public init(slot: UInt64, at time: Date = Date(), slotDuration: TimeInterval = 0.4) {
        anchorSlot = Double(slot)
        anchorTime = time
        floorSlot = Double(slot)
        self.slotDuration = slotDuration
    }

    public func estimate(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(anchorTime))
        return max(floorSlot, anchorSlot + min(elapsed / slotDuration, maxLead))
    }

    public mutating func observe(slot: UInt64, at date: Date = Date()) {
        let predicted = estimate(at: date)
        let observed = Double(slot)
        // Slightly ahead of the RPC: hold position until it catches up.
        // Far ahead (stalled RPC, sleep/wake): accept the jump back.
        floorSlot = predicted > observed && predicted - observed < 8 ? predicted : observed
        anchorSlot = observed
        anchorTime = date
    }

    /// Whether the estimate has stopped advancing because polls are stale.
    public func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(anchorTime) / slotDuration >= maxLead
    }
}
