import Foundation
import StickiesFormat
import Testing

@testable import SyncEngine

@Suite("MergeDecision and records")
struct MergeDecisionTests {
    private let macA = DeviceID(rawValue: "AAAA-device")
    private let macB = DeviceID(rawValue: "BBBB-device")
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func record(
        _ raw: String = "17",
        origin: DeviceID,
        version: [DeviceID: Int],
        text: String = "Note",
        isDeletion: Bool = false,
        at offset: TimeInterval = 0
    ) throws -> SyncRecord {
        SyncRecord(
            id: try stickyID(raw),
            origin: origin,
            version: VersionVector(counters: version),
            isDeletion: isDeletion,
            note: isDeletion ? nil : try note(raw, text: text),
            recordedAt: epoch.addingTimeInterval(offset)
        )
    }

    // MARK: - Ordering

    @Test("A note never seen before is adopted whole")
    func adoptsAnUnknownNote() throws {
        let remote = try record(origin: macA, version: [macA: 1])
        let resolution = try #require(MergeDecision.resolve(local: nil, remote: remote))

        #expect(resolution.adopt == remote)
        #expect(resolution.version == remote.version)
        #expect(resolution.conflictCopy == nil)
    }

    @Test("A version already held, or already superseded here, does nothing")
    func ignoresOldNews() throws {
        let local = try record(origin: macA, version: [macA: 2])

        #expect(MergeDecision.resolve(local: local, remote: local) == nil)
        #expect(MergeDecision.resolve(
            local: local,
            remote: try record(origin: macA, version: [macA: 1])
        ) == nil)
    }

    @Test("A version that descends the local one is adopted")
    func adoptsADescendant() throws {
        let resolution = try #require(
            MergeDecision.resolve(
                local: try record(origin: macA, version: [macA: 1]),
                remote: try record(origin: macB, version: [macA: 1, macB: 1], text: "Newer")
            )
        )
        #expect(resolution.adopt?.note?.package.plainTextForTesting?.contains("Newer") == true)
        #expect(resolution.conflictCopy == nil)
    }

    // MARK: - Conflicts

    @Test("Concurrent edits produce a copy, and the surviving note takes the merged vector")
    func concurrentEditsConflict() throws {
        let local = try record(origin: macA, version: [macA: 2], text: "From A", at: 10)
        let remote = try record(origin: macB, version: [macA: 1, macB: 1], text: "From B", at: 20)

        let resolution = try #require(MergeDecision.resolve(local: local, remote: remote))

        // The merged vector is what stops the pair rediscovering this conflict
        // on every subsequent pass.
        #expect(resolution.version == VersionVector(counters: [macA: 2, macB: 1]))
        #expect(resolution.conflictCopy != nil)
    }

    @Test("Both Macs pick the same winner and name the copy the same thing")
    func resolutionIsSymmetric() throws {
        let fromA = try record(origin: macA, version: [macA: 2], text: "From A", at: 10)
        let fromB = try record(origin: macB, version: [macA: 1, macB: 1], text: "From B", at: 20)

        // Mac A sees B as remote; Mac B sees A as remote. Same inputs, mirrored.
        let onA = try #require(MergeDecision.resolve(local: fromA, remote: fromB))
        let onB = try #require(MergeDecision.resolve(local: fromB, remote: fromA))

        #expect(onA.version == onB.version)
        #expect(onA.conflictCopy?.id == onB.conflictCopy?.id)
        #expect(onA.conflictCopy?.note?.package.files == onB.conflictCopy?.note?.package.files)

        // B's edit is later, so B keeps the identifier on both Macs: A adopts,
        // B keeps what it has.
        #expect(onA.adopt?.origin == macB)
        #expect(onB.adopt == nil)
    }

    @Test("Identical timestamps are broken by device, not left to chance")
    func tiebreakIsDeterministic() throws {
        let fromA = try record(origin: macA, version: [macA: 2], text: "From A", at: 10)
        let fromB = try record(origin: macB, version: [macA: 1, macB: 1], text: "From B", at: 10)

        let onA = try #require(MergeDecision.resolve(local: fromA, remote: fromB))
        let onB = try #require(MergeDecision.resolve(local: fromB, remote: fromA))

        // "BBBB-device" sorts after "AAAA-device", so B wins on both Macs.
        #expect(onA.adopt?.origin == macB)
        #expect(onB.adopt == nil)
        #expect(onA.conflictCopy?.id == onB.conflictCopy?.id)
    }

    @Test("The conflict copy carries the loser's vector, not a new one")
    func copyCarriesTheLosersVector() throws {
        let fromA = try record(origin: macA, version: [macA: 2], text: "From A", at: 10)
        let fromB = try record(origin: macB, version: [macA: 1, macB: 1], text: "From B", at: 20)

        let copy = try #require(MergeDecision.resolve(local: fromA, remote: fromB)?.conflictCopy)

        // A fresh vector on each Mac would make the two copies concurrent, and
        // they would conflict with each other forever.
        #expect(copy.version == fromA.version)
        #expect(copy.origin == macA)
    }

    @Test("The copy is marked by colour and offset, leaving the text untouched")
    func copyIsMarkedWithoutTouchingContent() throws {
        let fromA = try record(origin: macA, version: [macA: 2], text: "From A", at: 10)
        let fromB = try record(origin: macB, version: [macA: 1, macB: 1], text: "From B", at: 20)

        let copy = try #require(MergeDecision.resolve(local: fromA, remote: fromB)?.conflictCopy)

        #expect(copy.note?.package.files == fromA.note?.package.files)
        #expect(copy.note?.windowState?.palette.sticky == MergeDecision.conflictCopyColor)
        #expect(copy.note?.windowState?.id == copy.id)
        #expect(copy.note?.id == copy.id)
    }

    @Test("An edit beats a deletion, in either direction, with no copy")
    func editBeatsDelete() throws {
        let edit = try record(origin: macA, version: [macA: 2], text: "Keep me", at: 10)
        let deletion = try record(origin: macB, version: [macA: 1, macB: 1], isDeletion: true, at: 20)

        let localEdits = try #require(MergeDecision.resolve(local: edit, remote: deletion))
        #expect(localEdits.adopt == nil)
        #expect(localEdits.conflictCopy == nil)

        let remoteEdits = try #require(MergeDecision.resolve(local: deletion, remote: edit))
        #expect(remoteEdits.adopt?.isDeletion == false)
        #expect(remoteEdits.conflictCopy == nil)
    }

    // MARK: - Wire format

    @Test("A record round-trips through its serialized form")
    func recordRoundTrips() throws {
        let original = try record(origin: macA, version: [macA: 2, macB: 1], text: "Travelling")

        #expect(try SyncRecord(data: try original.serialized()) == original)
    }

    @Test("A deletion round-trips with no content")
    func deletionRoundTrips() throws {
        let original = try record(origin: macA, version: [macA: 3], isDeletion: true)
        let restored = try SyncRecord(data: try original.serialized())

        #expect(restored == original)
        #expect(restored.note == nil)
    }

    @Test("A record from a newer StickiesSync is refused rather than half-read")
    func refusesNewerRecords() throws {
        var plist = try #require(try record(origin: macA, version: [macA: 1]).plist.dictionaryValue)
        plist[SyncRecord.Key.formatVersion] = .integer(SyncRecord.currentFormatVersion + 1)

        #expect(throws: SyncRecord.RecordError.self) {
            try SyncRecord(plist: .dictionary(plist))
        }
    }

    @Test("A record whose deletion flag disagrees with its content is refused")
    func refusesInconsistentRecords() throws {
        var plist = try #require(try record(origin: macA, version: [macA: 1]).plist.dictionaryValue)
        plist[SyncRecord.Key.isDeletion] = .bool(true)

        // Content plus a deletion flag means one of the two is a lie, and
        // guessing which would either resurrect a note or destroy one.
        #expect(throws: SyncRecord.RecordError.self) {
            try SyncRecord(plist: .dictionary(plist))
        }
    }

    @Test("A manifest round-trips, entries sorted so an unchanged republish is identical")
    func manifestRoundTrips() throws {
        let manifest = DeviceManifest(
            device: macA,
            deviceName: "mac-a",
            entries: [
                .init(id: try stickyID("18"), version: VersionVector(counters: [macA: 1]), isDeletion: true),
                .init(id: try stickyID("17"), version: VersionVector(counters: [macA: 2]), isDeletion: false),
            ]
        )

        let data = try manifest.serialized()
        let restored = try DeviceManifest(data: data)

        #expect(restored.entries.map(\.id.rawValue) == ["17", "18"])
        #expect(restored[try stickyID("18")]?.isDeletion == true)
        // Byte-identical on republish, so the file syncer has nothing to carry.
        #expect(try restored.serialized() == data)
    }
}
