import CoreGraphics
import Foundation
import StickiesFormat
import Testing

@testable import StickiesStore

/// The property Milestone 2 exists to establish: a container can be exported,
/// destroyed, and put back exactly as it was. Everything downstream — conflict
/// copies, version history, restoring a deleted note — assumes this holds.
@Suite("Export, wipe, import")
struct RoundTripTests {
    @Test("A container survives export, wipe, and import byte for byte")
    func roundTripsAWholeContainer() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("A0000000-0000-0000-0000-000000000000")
            try home.addNote(
                "B0000000-0000-0000-0000-000000000000",
                attachments: ["photo.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])]
            )
            try home.addNote("17")  // legacy decimal name
            try home.writeSavedState(notes: [
                try makeWindowState("A0000000-0000-0000-0000-000000000000", zOrder: 1),
                try makeWindowState(
                    "B0000000-0000-0000-0000-000000000000",
                    frame: CGRect(x: -1440, y: 12.5, width: 360, height: 240),
                    isFloating: true,
                    zOrder: 2
                ),
                try makeWindowState("17", zOrder: 3),
            ])

            let before = try home.reader().read()
            let archive = try NoteArchive(notes: before.notes).serialized()
            let packagesBefore = try home.containerContents()
                .filter { $0.key.contains(".rtfd") }

            try home.wipeContainer()
            #expect(try home.reader().read().notes.isEmpty)

            _ = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: try NoteArchive(data: archive).notes))

            let after = try home.reader().read()
            #expect(after.notes == before.notes)
            #expect(after.isFullyUnderstood)

            // Package bytes compared on disk as well as through the model, since
            // the model could in principle agree while the files differed.
            #expect(try home.containerContents().filter { $0.key.contains(".rtfd") } == packagesBefore)

            // And exporting again produces the identical archive.
            #expect(try NoteArchive(notes: after.notes).serialized() == archive)
        }
    }

    @Test("An imported container is one Stickies' own state parser would accept")
    func rewritesStateInTheOriginalShape() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.writeSavedState(notes: [try makeWindowState("17", isFloating: true, zOrder: 4)])

            let before = try home.reader().read()
            try home.wipeContainer()
            _ = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: before.notes))

            // Re-read the written file the way Stickies would: a plist array of
            // dictionaries, each carrying its own UUID.
            let data = try Data(contentsOf: home.stickiesDirectory.savedStateURL)
            let root = try PropertyListSerialization.propertyList(from: data, format: nil)
            let entries = try #require(root as? [[String: Any]])

            #expect(entries.count == 1)
            #expect(entries[0]["UUID"] as? String == "17")
            #expect(entries[0]["Frame"] as? String == "{{10, 20}, {300, 200}}")
            #expect(entries[0]["Floating"] as? Bool == true)
            #expect(entries[0]["ZOrder"] as? Int == 4)
        }
    }

    @Test("A state entry this version cannot parse survives an import untouched")
    func preservesUnparseableStateEntriesThroughAWrite() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            // The second entry is a shape this version does not understand — a
            // stand-in for whatever a future macOS starts writing.
            try home.writeSavedState(propertyList: [
                try makeWindowState("17").plist.propertyList,
                ["UUID": "99", "SomethingNewInMacOS27": 42],
            ] as [Any])

            _ = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [try #require(try home.reader().read().notes.first)]))

            let data = try Data(contentsOf: home.stickiesDirectory.savedStateURL)
            let entries = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
            )
            let survivor = try #require(entries.first { $0["UUID"] as? String == "99" })

            #expect(survivor["SomethingNewInMacOS27"] as? Int == 42)
            #expect(entries.count == 2)
        }
    }

    @Test("Replacing a container drops the notes the archive does not carry")
    func replaceRemovesAbsentNotes() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addNote("18")
            try home.writeSavedState(notes: [try makeWindowState("17"), try makeWindowState("18")])

            let kept = try #require(try home.reader().read().notes.first { $0.id.rawValue == "17" })
            let dropped = try #require(StickyID(rawValue: "18"))

            _ = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [kept], removing: [dropped]))

            let after = try home.reader().read()
            #expect(after.notes.map(\.id.rawValue) == ["17"])
            #expect(after.savedState.notes.map(\.id.rawValue) == ["17"])
            #expect(after.isFullyUnderstood)
        }
    }
}
