import Foundation
import Testing

@testable import SyncEngine

@Suite("VersionVector")
struct VersionVectorTests {
    private let mac = DeviceID(rawValue: "mac")
    private let laptop = DeviceID(rawValue: "laptop")

    @Test("An unknown device reads as zero rather than missing")
    func unknownDeviceIsZero() {
        #expect(VersionVector()[mac] == 0)
    }

    @Test("Incrementing counts changes by the device that made them")
    func incrementCounts() {
        var vector = VersionVector()
        vector.increment(mac)
        vector.increment(mac)
        vector.increment(laptop)

        #expect(vector[mac] == 2)
        #expect(vector[laptop] == 1)
    }

    @Test("A version that descends from another is recognised as such")
    func detectsDescent() {
        let earlier = VersionVector(counters: [mac: 1])
        var later = earlier
        later.increment(mac)

        #expect(later.ordering(against: earlier) == .descendant)
        #expect(earlier.ordering(against: later) == .ancestor)
        #expect(earlier.ordering(against: earlier) == .equal)
    }

    @Test("Edits on two Macs since they last spoke are concurrent, not ordered")
    func detectsConcurrency() {
        // The case that becomes a conflict copy: each side has a counter the
        // other does not, so neither can be discarded.
        let onMac = VersionVector(counters: [mac: 2, laptop: 1])
        let onLaptop = VersionVector(counters: [mac: 1, laptop: 2])

        #expect(onMac.ordering(against: onLaptop) == .concurrent)
        #expect(onLaptop.ordering(against: onMac) == .concurrent)
    }

    @Test("A device the other side has never heard of still orders correctly")
    func handlesDisjointDevices() {
        let onMac = VersionVector(counters: [mac: 1])
        let onLaptop = VersionVector(counters: [laptop: 1])

        #expect(onMac.ordering(against: onLaptop) == .concurrent)
    }

    @Test("Merging takes the pairwise maximum")
    func mergeTakesMaximums() {
        let onMac = VersionVector(counters: [mac: 3, laptop: 1])
        let onLaptop = VersionVector(counters: [mac: 1, laptop: 5])

        let merged = onMac.merged(with: onLaptop)

        #expect(merged[mac] == 3)
        #expect(merged[laptop] == 5)
        #expect(merged.ordering(against: onMac) == .descendant)
        #expect(merged.ordering(against: onLaptop) == .descendant)
    }
}
