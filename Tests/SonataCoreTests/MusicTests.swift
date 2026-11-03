import Foundation
import Testing
@testable import SonataCore

@Suite struct MusicTests {
    @Test func preludeShape() {
        let song = BachPreludeInC.song
        #expect(BachPreludeInC.chords.count == 32)
        #expect(song.steps.count == 32 * 16 + 4 + 12)
        // Bar one: C E G C E, then G C E, twice.
        #expect(song.steps.prefix(8).map { $0.first?.pitch } == [60, 64, 67, 72, 76, 67, 72, 76])
        #expect(song.steps.allSatisfy { $0.allSatisfy { (36...84).contains($0.pitch) && $0.length >= 1 } })
    }

    @Test func leaderChangesMarkTheBeat() {
        // A A A A B B B B B B B B C C C C: B leads two windows back to back, one note.
        let schedule = LeaderSchedule(epoch: 7, firstSlot: 1_000, slotsInEpoch: 16,
                                      rpc: ["A": [0, 1, 2, 3], "B": Array(4..<12), "C": [12, 13, 14, 15]] as [String: [UInt64]])
        let changes = schedule.leaderChanges()
        #expect(changes == [1_000, 1_004, 1_012])
        #expect(SongPosition.at(1_002, epoch: 7, changes: changes)?.change == 0)
        #expect(SongPosition.at(1_011, epoch: 7, changes: changes)?.change == 1)
        #expect(SongPosition.at(1_015, epoch: 7, changes: changes)?.change == 2)
        #expect(SongPosition.at(999, epoch: 7, changes: changes) == nil)
    }

    @Test func everyInstallAgrees() {
        // The position is a pure function of the schedule and the slot.
        let changes = Array(stride(from: UInt64(5_000), to: 5_000 + 4 * 2_000, by: 4))
        let a = SongPosition.at(5_000 + 4 * 1_234 + 2, epoch: 1_075, changes: changes)
        let b = SongPosition.at(5_000 + 4 * 1_234 + 3, epoch: 1_075, changes: changes)
        #expect(a == b)
        #expect(a?.step == 1_234 % BachPreludeInC.song.steps.count)
        #expect(Playlist.song(for: 1_075) == Playlist.song(for: 1_076))  // one song for now
    }
}
