import Foundation

/// One epoch's leader schedule, stored compactly: one identity index per slot.
public struct LeaderSchedule: Sendable, Equatable {
    public let epoch: UInt64
    public let firstSlot: UInt64
    public let slotsInEpoch: UInt64
    /// Distinct leader identities, sorted by number of slots (descending).
    public let identities: [String]
    /// `slots[i]` indexes `identities` for slot `firstSlot + i`.
    public let slots: [UInt16]

    public static let unassigned = UInt16.max

    public init(epoch: UInt64, firstSlot: UInt64, slotsInEpoch: UInt64, identities: [String], slots: [UInt16]) {
        self.epoch = epoch
        self.firstSlot = firstSlot
        self.slotsInEpoch = slotsInEpoch
        self.identities = identities
        self.slots = slots
    }

    /// Builds a schedule from the `getLeaderSchedule` response shape.
    public init<I: BinaryInteger>(epoch: UInt64, firstSlot: UInt64, slotsInEpoch: UInt64, rpc: [String: [I]]) {
        let ordered = rpc.sorted { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key
        }
        var slots = [UInt16](repeating: Self.unassigned, count: Int(slotsInEpoch))
        for (index, entry) in ordered.enumerated() where index < Int(Self.unassigned) {
            for slotIndex in entry.value where slotIndex >= 0 && slotIndex < slots.count {
                slots[Int(slotIndex)] = UInt16(index)
            }
        }
        self.init(epoch: epoch, firstSlot: firstSlot, slotsInEpoch: slotsInEpoch,
                  identities: ordered.map(\.key), slots: slots)
    }

    public var lastSlot: UInt64 { firstSlot + slotsInEpoch - 1 }

    public func contains(_ slot: UInt64) -> Bool { slot >= firstSlot && slot <= lastSlot }

    public func leader(at slot: UInt64) -> String? {
        guard contains(slot) else { return nil }
        let index = slots[Int(slot - firstSlot)]
        return index == Self.unassigned ? nil : identities[Int(index)]
    }

    /// Share of the epoch's slots each identity leads (a proxy for stake).
    public func shares() -> [String: Double] {
        var counts = [Int](repeating: 0, count: identities.count)
        for index in slots where index != Self.unassigned { counts[Int(index)] += 1 }
        var out: [String: Double] = [:]
        for (i, id) in identities.enumerated() { out[id] = Double(counts[i]) / Double(max(slotsInEpoch, 1)) }
        return out
    }
}

extension LeaderSchedule: Codable {
    enum CodingKeys: String, CodingKey { case epoch, firstSlot, slotsInEpoch, identities, slots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let data = try c.decode(Data.self, forKey: .slots)
        let slots = data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        let slotsInEpoch = try c.decode(UInt64.self, forKey: .slotsInEpoch)
        guard slots.count == Int(slotsInEpoch) else {
            throw DecodingError.dataCorruptedError(forKey: .slots, in: c, debugDescription: "slot count mismatch")
        }
        self.init(epoch: try c.decode(UInt64.self, forKey: .epoch),
                  firstSlot: try c.decode(UInt64.self, forKey: .firstSlot),
                  slotsInEpoch: slotsInEpoch,
                  identities: try c.decode([String].self, forKey: .identities),
                  slots: slots)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(firstSlot, forKey: .firstSlot)
        try c.encode(slotsInEpoch, forKey: .slotsInEpoch)
        try c.encode(identities, forKey: .identities)
        var data = Data(capacity: slots.count * 2)
        for slot in slots { withUnsafeBytes(of: slot.littleEndian) { data.append(contentsOf: $0) } }
        try c.encode(data, forKey: .slots)
    }
}

/// A run of consecutive slots led by the same validator.
public struct LeaderWindow: Sendable, Equatable, Identifiable {
    public let identity: String
    public let firstSlot: UInt64
    public let slotCount: UInt64
    public var id: UInt64 { firstSlot }
    public var endSlot: UInt64 { firstSlot + slotCount }  // exclusive

    public init(identity: String, firstSlot: UInt64, slotCount: UInt64) {
        self.identity = identity
        self.firstSlot = firstSlot
        self.slotCount = slotCount
    }
}

/// Looks up leaders across adjacent epochs (current and the prefetched next one).
public struct ScheduleBook: Sendable {
    public var schedules: [UInt64: LeaderSchedule] = [:]

    public init(_ schedules: [LeaderSchedule] = []) {
        for s in schedules { self.schedules[s.epoch] = s }
    }

    public func schedule(containing slot: UInt64) -> LeaderSchedule? {
        schedules.values.first { $0.contains(slot) }
    }

    public func leader(at slot: UInt64) -> String? { schedule(containing: slot)?.leader(at: slot) }

    /// The window containing `slot`, then the following ones, merging consecutive slots of one leader.
    public func windows(from slot: UInt64, count: Int, maxScan: UInt64 = 4_000) -> [LeaderWindow] {
        guard count > 0, let id = leader(at: slot) else { return [] }
        var start = slot
        while start > 0, slot - start < 64, leader(at: start - 1) == id { start -= 1 }
        var out: [LeaderWindow] = []
        var current = id, runStart = start, cursor = start
        while out.count < count, cursor - start < maxScan {
            cursor += 1
            let next = leader(at: cursor)
            if next != current {
                out.append(LeaderWindow(identity: current, firstSlot: runStart, slotCount: cursor - runStart))
                guard let next else { break }
                current = next
                runStart = cursor
            }
        }
        return out
    }

    /// Windows ending before `slot`, most recent first.
    public func previousWindows(before slot: UInt64, count: Int) -> [LeaderWindow] {
        guard count > 0, slot > 0 else { return [] }
        var out: [LeaderWindow] = []
        var cursor = slot
        if let id = leader(at: slot) {  // skip back to the start of the current window
            while cursor > 0, slot - cursor < 64, leader(at: cursor - 1) == id { cursor -= 1 }
        }
        while out.count < count, cursor > 0 {
            guard let id = leader(at: cursor - 1) else { break }
            let end = cursor
            while cursor > 0, end - cursor < 64, leader(at: cursor - 1) == id { cursor -= 1 }
            out.append(LeaderWindow(identity: id, firstSlot: cursor, slotCount: end - cursor))
        }
        return out
    }
}
