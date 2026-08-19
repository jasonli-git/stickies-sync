import CoreGraphics
import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine
import Testing

@testable import StickiesSyncKit

/// Two Macs, one shared folder, no direct contact. Everything here is a claim
/// about what the pair ends up agreeing on.
@Suite("Two Macs over a shared folder")
struct ConvergenceTests {
    /// Sync both Macs until neither has anything left to do. A single pass each
    /// is rarely enough: A publishes, B adopts and republishes, A adopts B's
    /// view of the merge.
    private func settle(_ a: SimulatedMac, _ b: SimulatedMac, rounds: Int = 4) throws {
        for _ in 0..<rounds {
            _ = try a.sync()
            _ = try b.sync()
        }
    }

    @Test("A note written on one Mac arrives on the other")
    func propagatesANewNote() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Buy milk")

            _ = try a.sync()
            let outcome = try b.sync()

            #expect(outcome.adopted.map(\.rawValue) == ["A0000000-0000-0000-0000-000000000001"])
            #expect(try b.text(of: "A0000000-0000-0000-0000-000000000001")?.contains("Buy milk") == true)
        }
    }

    @Test("The arriving note is byte-identical to the original")
    func propagatesExactly() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Exact",
                frame: CGRect(x: 400, y: 700, width: 360, height: 240),
                color: StickyColor(red: 0.6784, green: 0.8471, blue: 1)
            )
            try settle(a, b)

            let original = try #require(try a.notes().first)
            let arrived = try #require(try b.notes().first)

            #expect(arrived.package.files == original.package.files)
            #expect(arrived.windowState?.frame == CGRect(x: 400, y: 700, width: 360, height: 240))
            #expect(arrived.windowState?.palette.sticky == original.windowState?.palette.sticky)
        }
    }

    @Test("An edit on one Mac replaces the note on the other")
    func propagatesAnEdit() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "First")
            try settle(a, b)

            a.clock.advance()
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Second")
            try settle(a, b)

            #expect(try b.text(of: "A0000000-0000-0000-0000-000000000001")?.contains("Second") == true)
            #expect(try b.notes().count == 1)
        }
    }

    @Test("A deletion on one Mac removes the note on the other")
    func propagatesADeletion() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Temporary")
            try settle(a, b)
            #expect(try b.notes().count == 1)

            a.clock.advance()
            try a.deleteNote("A0000000-0000-0000-0000-000000000001")
            try settle(a, b)

            #expect(try a.notes().isEmpty)
            #expect(try b.notes().isEmpty)
            // The tombstone is retained on both, so the note stays recoverable
            // on the Mac that never deleted it.
            #expect(try b.replica.recoverableDeletedNotes().count == 1)
        }
    }

    @Test("A note this Mac cannot read is not deleted on the other one")
    func doesNotPropagateAFailedRead() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Still here")
            try settle(a, b)
            #expect(try b.notes().count == 1)

            // Observed on the live agent, 2026-08-19: one pass could not read a
            // package (`EINTR`), reported it deleted, published the tombstone,
            // and the note vanished on the other Mac until the next pass read it
            // again. A note that cannot be read is not a note that is gone.
            a.clock.advance()
            try a.makeNoteUnreadable("A0000000-0000-0000-0000-000000000001")
            let outcome = try a.sync()
            try settle(a, b)

            #expect(outcome.localChanges.isEmpty)
            #expect(outcome.warnings.contains { $0.contains("cannot read note") })
            #expect(try b.notes().count == 1)
            #expect(try b.text(of: "A0000000-0000-0000-0000-000000000001")?.contains("Still here") == true)
            #expect(try b.replica.recoverableDeletedNotes().isEmpty)
        }
    }

    @Test("An unreadable note does not stop a real deletion travelling")
    func stillPropagatesRealDeletionsAroundAnUnreadableNote() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Unreadable soon")
            try a.writeNote("A0000000-0000-0000-0000-000000000002", text: "Genuinely deleted")
            try settle(a, b)
            #expect(try b.notes().count == 2)

            // The narrow rule, per #16 and #24: one unreadable note costs that
            // note, never the pass.
            a.clock.advance()
            try a.makeNoteUnreadable("A0000000-0000-0000-0000-000000000001")
            try a.deleteNote("A0000000-0000-0000-0000-000000000002")
            try settle(a, b)

            #expect(try b.notes().map(\.id.rawValue) == ["A0000000-0000-0000-0000-000000000001"])
        }
    }

    @Test("Nothing happens on a pass with no changes")
    func quiescesWhenNothingChanges() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Settled")
            try settle(a, b)

            // The property that makes a background agent tolerable: a steady
            // state costs nothing and, in particular, never touches Stickies.
            #expect(try a.sync().didAnything == false)
            #expect(try b.sync().didAnything == false)
        }
    }

    @Test("Notes made on both Macs at once all survive")
    func mergesIndependentNotes() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "From A")
            try b.writeNote("B0000000-0000-0000-0000-000000000002", text: "From B")

            try settle(a, b)

            #expect(try a.texts().count == 2)
            #expect(try b.texts().count == 2)
            #expect(try a.texts() == b.texts())
        }
    }

    // MARK: - Conflicts

    @Test("The same note edited on both Macs keeps both versions")
    func conflictKeepsBothVersions() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Shared")
            try settle(a, b)

            // Both edit before either syncs: neither version descends the other.
            a.clock.advance(60)
            b.clock.advance(120)
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Edited on A")
            try b.writeNote("A0000000-0000-0000-0000-000000000001", text: "Edited on B")

            try settle(a, b)

            // Two notes on each Mac: the winner under the original identifier,
            // and the loser as a conflict copy.
            #expect(try a.notes().count == 2)
            #expect(try b.notes().count == 2)

            let onA = try a.texts()
            #expect(onA.contains { $0.contains("Edited on A") })
            #expect(onA.contains { $0.contains("Edited on B") })
        }
    }

    @Test("Both Macs derive the same conflict copy, so the pair converges")
    func conflictConvergesToTheSameState() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Shared")
            try settle(a, b)

            a.clock.advance(60)
            b.clock.advance(120)
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Edited on A")
            try b.writeNote("A0000000-0000-0000-0000-000000000001", text: "Edited on B")

            try settle(a, b, rounds: 6)

            // The claim the whole design rests on: two Macs that never spoke to
            // each other reached identical state. If the conflict copy's
            // identifier were derived from anything local — a fresh UUID, the
            // device doing the resolving — each Mac would make its own copy and
            // this would be four notes, then eight.
            let notesA = try a.notes().sorted { $0.id < $1.id }
            let notesB = try b.notes().sorted { $0.id < $1.id }

            #expect(notesA.map(\.id) == notesB.map(\.id))
            #expect(notesA.map(\.package.files) == notesB.map(\.package.files))
            #expect(notesA.count == 2)
        }
    }

    @Test("The later edit keeps the original identifier")
    func laterEditKeepsTheIdentifier() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Shared")
            try settle(a, b)

            a.clock.advance(60)
            b.clock.advance(600)  // B's edit is unambiguously later
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Earlier, from A")
            try b.writeNote("A0000000-0000-0000-0000-000000000001", text: "Later, from B")

            try settle(a, b, rounds: 6)

            let original = try #require(
                try a.notes().first { $0.id.rawValue == "A0000000-0000-0000-0000-000000000001" }
            )
            #expect(original.package.plainText?.contains("Later, from B") == true)
        }
    }

    @Test("A conflict copy is marked so it can be told apart on sight")
    func conflictCopyIsMarked() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Shared")
            try settle(a, b)

            a.clock.advance(60)
            b.clock.advance(120)
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Edited on A")
            try b.writeNote("A0000000-0000-0000-0000-000000000001", text: "Edited on B")
            try settle(a, b, rounds: 6)

            let copy = try #require(
                try a.notes().first { $0.id.rawValue != "A0000000-0000-0000-0000-000000000001" }
            )
            // Marked by appearance, never by editing the text — re-serializing
            // rich text would produce different bytes on each Mac and the copies
            // would then conflict with each other.
            #expect(copy.windowState?.palette.sticky == MergeDecision.conflictCopyColor)
            #expect(copy.package.plainText?.contains("Edited on") == true)
        }
    }

    @Test("Editing a note on one Mac while deleting it on the other keeps the edit")
    func editBeatsDelete() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Contested")
            try settle(a, b)

            a.clock.advance(60)
            b.clock.advance(60)
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Still wanted")
            try b.deleteNote("A0000000-0000-0000-0000-000000000001")

            try settle(a, b, rounds: 6)

            // SPEC.md's first principle: never lose a note. A tombstone has
            // nothing to preserve, so the edit wins outright and no copy is made.
            #expect(try a.notes().count == 1)
            #expect(try b.notes().count == 1)
            #expect(try b.text(of: "A0000000-0000-0000-0000-000000000001")?.contains("Still wanted") == true)
        }
    }

    // MARK: - Geometry stays where it belongs

    @Test("Moving a note on one Mac does not move it on the other")
    func geometryDoesNotTravel() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Placed",
                frame: CGRect(x: 100, y: 100, width: 300, height: 200)
            )
            try settle(a, b)

            // Exactly what Stickies does by itself on a smaller display: the
            // frame is rewritten to fit, with no user action at all.
            a.clock.advance()
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Placed",
                frame: CGRect(x: 8, y: 749, width: 300, height: 200)
            )
            try settle(a, b)

            let movedOnA = try a.notes().first?.windowState?.frame.origin.y
            let untouchedOnB = try b.notes().first?.windowState?.frame.origin.y
            #expect(movedOnA == 749)
            #expect(untouchedOnB == 100)
        }
    }

    @Test("A move produces no sync traffic at all")
    func aMoveIsNotPublished() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Placed")
            try settle(a, b)

            a.clock.advance()
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Placed",
                frame: CGRect(x: 900, y: 40, width: 300, height: 200)
            )

            let onA = try a.sync()
            #expect(onA.localChanges.allSatisfy { $0.isGeometryOnly })

            // The other Mac has nothing to do — which is the whole point. With
            // geometry inside the synced digest, opening Stickies on a laptop
            // rearranged the desktop Mac's notes.
            #expect(try b.sync().didAnything == false)
        }
    }

    @Test("A move writes nothing to the shared folder, not even a timestamp")
    func aMoveTouchesNoFiles() throws {
        try SimulatedMac.pair { a, b, folder in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Placed")
            try settle(a, b)

            let before = try Self.fileContents(of: folder)
            a.clock.advance()
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Placed",
                frame: CGRect(x: 900, y: 40, width: 300, height: 200)
            )
            _ = try a.sync()

            // Not merely "no note changes": no bytes at all. A syncing service
            // re-uploads anything whose mtime moved, and an agent polling every
            // thirty seconds would otherwise push thousands of near-identical
            // files a day and wake every other device for each one.
            #expect(try Self.fileContents(of: folder) == before)
        }
    }

    @Test("A move does not change which Mac would win a later conflict")
    func aMoveDoesNotShiftTheTiebreak() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Placed")
            try settle(a, b)

            let id = try #require(StickyID(rawValue: "A0000000-0000-0000-0000-000000000001"))
            let before = try #require(try a.replica.knownNote(id)).updatedAt

            a.clock.advance(3600)
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Placed",
                frame: CGRect(x: 900, y: 40, width: 300, height: 200)
            )
            _ = try a.sync()

            // The recorded time is the last-writer-wins tiebreak. Letting a
            // window move advance it would mean dragging a note decides a future
            // conflict over its *text*.
            #expect(try a.replica.knownNote(id)?.updatedAt == before)
        }
    }

    private static func fileContents(of folder: URL) throws -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return [:] }
        var files: [String: Data] = [:]
        for case let url as URL in walker where url.pathExtension == "plist" {
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }

    @Test("An edit from the other Mac arrives without dragging its window position along")
    func adoptingAnEditKeepsLocalPlacement() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "First",
                frame: CGRect(x: 100, y: 100, width: 300, height: 200)
            )
            try settle(a, b)

            // B keeps its own layout, then A edits the words.
            b.clock.advance()
            try b.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "First",
                frame: CGRect(x: 700, y: 300, width: 300, height: 200)
            )
            try settle(a, b)

            a.clock.advance(600)
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Second",
                frame: CGRect(x: 100, y: 100, width: 300, height: 200)
            )
            try settle(a, b)

            let onB = try #require(try b.notes().first)
            #expect(onB.package.plainText?.contains("Second") == true)
            #expect(onB.windowState?.frame.origin == CGPoint(x: 700, y: 300))
        }
    }

    @Test("A note seen for the first time is placed where the sender had it")
    func newNotesAreSeededWithTheSendersPlacement() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Arriving",
                frame: CGRect(x: 640, y: 480, width: 360, height: 240)
            )
            try settle(a, b)

            // There is no local placement to preserve yet, so the sender's is
            // better than whatever corner Stickies would choose.
            let seeded = try b.notes().first?.windowState?.frame
            #expect(seeded == CGRect(x: 640, y: 480, width: 360, height: 240))
        }
    }

    @Test("Recolouring still travels, because a colour belongs to the note")
    func appearanceStillSyncs() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "Colourful")
            try settle(a, b)

            a.clock.advance()
            try a.writeNote(
                "A0000000-0000-0000-0000-000000000001",
                text: "Colourful",
                color: StickyColor(red: 0.68, green: 0.85, blue: 1)
            )
            try settle(a, b)

            let arrived = try b.notes().first?.windowState?.palette.sticky
            #expect(arrived == StickyColor(red: 0.68, green: 0.85, blue: 1))
        }
    }

    // MARK: - Relaying

    @Test("A note relayed onward keeps the Mac it came from as its origin")
    func relayingPreservesOrigin() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "From A")
            try settle(a, b)

            let id = try #require(StickyID(rawValue: "A0000000-0000-0000-0000-000000000001"))
            let onB = try #require(try b.replica.knownNote(id))

            // If B re-attributed the note to itself, its counter would climb on
            // every pass and A would keep seeing "new" versions of its own note.
            #expect(onB.origin == a.replica.deviceID)
            #expect(onB.version[a.replica.deviceID] == 1)
            #expect(onB.version[b.replica.deviceID] == 0)
        }
    }

    @Test("Adopting a note does not make the adopting Mac claim the change")
    func adoptionDoesNotBumpTheLocalCounter() throws {
        try SimulatedMac.pair { a, b, _ in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "From A")
            try settle(a, b)

            // The Milestone 3 limitation this milestone exists to fix: a scan
            // after adopting must see nothing, or the two Macs bounce the same
            // note back and forth forever.
            #expect(try b.replica.reconcile(with: try b.notes()).isEmpty)
            #expect(try b.sync().didAnything == false)
        }
    }

    @Test("Each Mac writes only inside its own area of the shared folder")
    func writesAreDisjoint() throws {
        try SimulatedMac.pair { a, b, folder in
            try a.writeNote("A0000000-0000-0000-0000-000000000001", text: "From A")
            try b.writeNote("B0000000-0000-0000-0000-000000000002", text: "From B")
            try settle(a, b)

            // The property that keeps iCloud Drive and Syncthing from inventing
            // their own conflict copies underneath us.
            let devices = folder.appending(path: "devices", directoryHint: .isDirectory)
            let names = try FileManager.default.contentsOfDirectory(atPath: devices.path(percentEncoded: false))
            #expect(Set(names) == [a.replica.deviceID.rawValue, b.replica.deviceID.rawValue])
        }
    }
}
