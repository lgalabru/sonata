import Foundation
import Testing
@testable import SonataCore

@Suite struct ScheduleTests {
    // 16 slots: A A A A B B B B B B B B C C C C (B leads two windows back to back)
    let schedule = LeaderSchedule(epoch: 7, firstSlot: 1_000, slotsInEpoch: 16,
                                  rpc: ["A": [0, 1, 2, 3], "B": Array(4..<12), "C": [12, 13, 14, 15]] as [String: [UInt64]])

    @Test func leaderLookup() {
        #expect(schedule.leader(at: 1_000) == "A")
        #expect(schedule.leader(at: 1_005) == "B")
        #expect(schedule.leader(at: 1_015) == "C")
        #expect(schedule.leader(at: 999) == nil)
        #expect(schedule.leader(at: 1_016) == nil)
        #expect(schedule.identities.first == "B")  // most slots first
    }

    @Test func sharesSumToOne() {
        let shares = schedule.shares()
        #expect(shares["B"] == 0.5)
        #expect(abs(shares.values.reduce(0, +) - 1) < 1e-9)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(schedule)
        #expect(try JSONDecoder().decode(LeaderSchedule.self, from: data) == schedule)
    }

    @Test func windowsMergeConsecutiveSlots() {
        let book = ScheduleBook([schedule])
        let windows = book.windows(from: 1_002, count: 5)
        #expect(windows.map(\.identity) == ["A", "B", "C"])
        #expect(windows[0] == LeaderWindow(identity: "A", firstSlot: 1_000, slotCount: 4))
        #expect(windows[1] == LeaderWindow(identity: "B", firstSlot: 1_004, slotCount: 8))
        #expect(book.previousWindows(before: 1_013, count: 5).map(\.identity) == ["B", "A"])
    }

    @Test func windowsCrossEpochBoundary() {
        let next = LeaderSchedule(epoch: 8, firstSlot: 1_016, slotsInEpoch: 4, rpc: ["D": [0, 1, 2, 3]] as [String: [UInt64]])
        let book = ScheduleBook([schedule, next])
        #expect(book.windows(from: 1_014, count: 2).map(\.identity) == ["C", "D"])
    }
}

@Suite struct ClockTests {
    @Test func extrapolatesAndStaysMonotonic() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = SlotClock(slot: 100, at: t0)
        #expect(clock.estimate(at: t0.addingTimeInterval(2)) == 105)
        // RPC reports a slightly older slot: hold position instead of jumping back.
        clock.observe(slot: 103, at: t0.addingTimeInterval(2))
        #expect(clock.estimate(at: t0.addingTimeInterval(2)) == 105)
        #expect(clock.estimate(at: t0.addingTimeInterval(3.2)) == 106)
        // Capped when polls stop.
        #expect(clock.estimate(at: t0.addingTimeInterval(1_000)) == 103 + 25)
    }
}

@Suite struct MapTests {
    @Test func landMaskKnowsContinents() {
        #expect(LandMask.shared.isValid)
        #expect(LandMask.shared.isLand(lat: 50.1, lon: 8.7))      // Frankfurt
        #expect(LandMask.shared.isLand(lat: 39.0, lon: -77.5))    // Ashburn
        #expect(!LandMask.shared.isLand(lat: 30, lon: -40))       // mid-Atlantic
    }

    @Test func projectionFoldsOceans() {
        // Tokyo, Frankfurt, New York, Los Angeles: the Pacific (102°) and the Atlantic (83°) get folded.
        let places = [(lat: 35.7, lon: 139.7), (lat: 50.1, lon: 8.7), (lat: 40.7, lon: -74.0), (lat: 34.0, lon: -118.2)]
        let size = CGSize(width: 330, height: 172)
        let p = FoldedProjection.framing(places, size: size)
        for place in places {
            let pt = p.project(lat: place.lat, lon: place.lon)
            #expect(pt.x >= 0 && pt.x <= size.width && pt.y >= 0 && pt.y <= size.height)
            // Columns and rows invert back to the place.
            let lon = try! #require(p.longitude(atX: pt.x)), lat = try! #require(p.latitude(atY: pt.y))
            #expect(abs(lat - place.lat) < 1e-6)
            #expect(abs(((lon - place.lon + 540).truncatingRemainder(dividingBy: 360)) - 180) < 1e-6)
        }
        #expect(!p.folds.isEmpty)
        // The widest empty arc (Frankfurt → Tokyo, 131°) is left off the map, so it runs
        // Tokyo, Los Angeles, New York, Frankfurt.
        let xs = places.map { p.project(lat: $0.lat, lon: $0.lon).x }
        #expect(xs[0] < xs[3] && xs[3] < xs[2] && xs[2] < xs[1])
        // Seams are blank.
        for seam in p.seams { #expect(p.longitude(atX: seam.x) == nil) }
    }

    @Test func worldWithoutPlaces() {
        let p = FoldedProjection.framing([], size: CGSize(width: 360, height: 134))
        #expect(p.folds.isEmpty)
        #expect(p.span == 360)
    }

    @Test func gossipHost() {
        #expect(ClusterNode(pubkey: "x", gossip: "1.2.3.4:8001", version: nil).ip == "1.2.3.4")
        #expect(ClusterNode(pubkey: "x", gossip: "[2001:db8::1]:8001", version: nil).ip == "2001:db8::1")
    }

    @Test func flag() {
        #expect(GeoPoint(lat: 0, lon: 0, countryCode: "DE").flag == "🇩🇪")
    }
}
