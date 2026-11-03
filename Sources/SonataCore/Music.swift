import Foundation

/// A piece played one step per leader change: every install that sees the same schedule plays
/// the same step at the same moment, since the step is derived from the schedule itself.
public struct Song: Sendable, Equatable, Identifiable {
    /// A note struck at a step, ringing for `length` steps (MIDI note number, velocity 1…127).
    public struct Note: Sendable, Equatable {
        public let pitch: UInt8
        public let length: Int
        public let velocity: UInt8

        public init(_ pitch: UInt8, length: Int = 1, velocity: UInt8 = 64) {
            self.pitch = pitch
            self.length = length
            self.velocity = velocity
        }
    }

    public let id: String
    public let title: String
    public let composer: String
    /// One entry per leader change; an empty step is a rest.
    public let steps: [[Note]]

    public init(id: String, title: String, composer: String, steps: [[Note]]) {
        self.id = id
        self.title = title
        self.composer = composer
        self.steps = steps
    }
}

/// The songs, one per epoch in turn.
public enum Playlist {
    public static let songs: [Song] = [BachPreludeInC.song]

    /// The song for an epoch: the playlist in order, round and round.
    public static func song(for epoch: UInt64) -> Song { songs[Int(epoch % UInt64(songs.count))] }
}

/// J. S. Bach, Prelude in C major, BWV 846 (Well-Tempered Clavier, Book I), public domain.
/// Each bar is one chord broken into sixteen notes: the two lowest ring through the half bar,
/// the three highest are arpeggiated twice — one note per leader change.
public enum BachPreludeInC {
    /// MIDI numbers, low to high, for bars 1–32 (the regular part of the piece).
    static let chords: [[UInt8]] = [
        [60, 64, 67, 72, 76], [60, 62, 69, 74, 77], [59, 62, 67, 74, 77], [60, 64, 67, 72, 76],
        [60, 64, 69, 76, 81], [60, 62, 66, 69, 74], [59, 62, 67, 74, 79], [59, 60, 64, 67, 72],
        [57, 60, 64, 67, 72], [50, 57, 62, 66, 72], [55, 59, 62, 67, 71], [55, 58, 64, 67, 73],
        [53, 57, 62, 69, 74], [53, 56, 62, 65, 71], [52, 55, 60, 67, 72], [52, 53, 57, 60, 65],
        [50, 53, 57, 60, 65], [43, 50, 55, 59, 65], [48, 52, 55, 60, 64], [48, 55, 58, 60, 64],
        [41, 53, 57, 60, 64], [42, 48, 57, 60, 63], [44, 53, 59, 60, 62], [43, 53, 55, 59, 62],
        [43, 52, 55, 60, 64], [43, 50, 55, 60, 65], [43, 50, 55, 59, 65], [43, 51, 57, 60, 66],
        [43, 52, 55, 60, 67], [43, 50, 55, 60, 65], [43, 50, 55, 59, 65], [36, 48, 55, 58, 64],
    ]

    /// Half a bar: the bass and tenor struck and held, then the upper three notes twice.
    static func halfBar(_ c: [UInt8]) -> [[Song.Note]] {
        [[.init(c[0], length: 8, velocity: 82)], [.init(c[1], length: 7, velocity: 76)],
         [.init(c[2], velocity: 84)], [.init(c[3], velocity: 86)], [.init(c[4], velocity: 92)],
         [.init(c[2], velocity: 78)], [.init(c[3], velocity: 80)], [.init(c[4], velocity: 86)]]
    }

    public static let song: Song = {
        var steps = chords.flatMap { halfBar($0) + halfBar($0) }
        // The close: the C major chord, then silence before the piece starts over.
        steps.append([.init(36, length: 16, velocity: 84), .init(48, length: 16, velocity: 78)])
        steps.append([.init(64, length: 15, velocity: 80)])
        steps.append([.init(67, length: 14, velocity: 84)])
        steps.append([.init(72, length: 13, velocity: 92)])
        steps += Array(repeating: [], count: 12)
        return Song(id: "bach-bwv846", title: "Prelude in C major, BWV 846", composer: "J. S. Bach", steps: steps)
    }()
}

extension LeaderSchedule {
    /// The slots where the leader changes, from the epoch's first slot: the song's beat.
    public func leaderChanges() -> [UInt64] {
        var out: [UInt64] = []
        out.reserveCapacity(slots.count / 4 + 1)
        var previous: UInt16?
        for (i, s) in slots.enumerated() where s != previous {
            out.append(firstSlot + UInt64(i))
            previous = s
        }
        return out
    }
}

/// Which step of which song plays at a slot: the same answer on every install.
public struct SongPosition: Sendable, Equatable {
    public let epoch: UInt64
    public let song: Song
    /// Leader changes since the epoch began, counting the first leader as 0.
    public let change: Int
    public var step: Int { change % song.steps.count }

    /// `changes` are an epoch's leader-change slots (`leaderChanges()`), ascending.
    public static func at(_ slot: UInt64, epoch: UInt64, changes: [UInt64]) -> SongPosition? {
        guard let first = changes.first, slot >= first else { return nil }
        // The last change at or before `slot`.
        var lo = 0, hi = changes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if changes[mid] <= slot { lo = mid } else { hi = mid - 1 }
        }
        return SongPosition(epoch: epoch, song: Playlist.song(for: epoch), change: lo)
    }
}
