import CoreGraphics
import Foundation
import Testing

@testable import StickiesFormat

@Suite("SavedStickiesState")
struct SavedStickiesStateTests {
    private func realState() throws -> SavedStickiesState {
        try SavedStickiesState(data: try Fixtures.data(Fixtures.twoNoteState))
    }

    @Test("Reads both notes out of a real state file")
    func readsTheGoldenFile() throws {
        let state = try realState()

        #expect(state.entries.count == 2)
        #expect(state.notes.count == 2)
        #expect(state.unreadableReasons.isEmpty)
        #expect(state.notes.map(\.id.rawValue) == [
            "B349659A-E901-435C-B205-838B553807F4",
            "726F24D8-73B2-4771-A8A2-A9E9063B037E",
        ])
    }

    @Test("Reads every field of the note Stickies created itself")
    func readsTheStickiesAuthoredNote() throws {
        let id = try #require(StickyID(rawValue: "B349659A-E901-435C-B205-838B553807F4"))
        let note = try #require(try realState()[id])

        #expect(note.frame == CGRect(x: 8, y: 1110, width: 300, height: 200))
        #expect(note.expandedSize == CGSize(width: 300, height: 200))
        #expect(note.expandFrameY == 0)
        #expect(note.isFloating == false)
        #expect(note.isTranslucent == false)
        #expect(note.spellCheckingTypes == 9191)
        #expect(note.zOrder == 1)
        #expect(note.palette.sticky.red == 0.996078431372549)
        #expect(note.palette.sticky.green == 0.9568627450980393)
        #expect(note.palette.sticky.blue == 0.611764705882353)
        #expect(note.palette.sticky.alpha == 1)
        #expect(note.palette.spine != nil)
        #expect(note.palette.control != nil)
        #expect(note.palette.highlight != nil)
        #expect(note.unrecognized.isEmpty)
    }

    @Test("Reads the floating, translucent note")
    func readsTheFloatingNote() throws {
        let id = try #require(StickyID(rawValue: "726F24D8-73B2-4771-A8A2-A9E9063B037E"))
        let note = try #require(try realState()[id])

        #expect(note.frame == CGRect(x: 400, y: 700, width: 360, height: 240))
        #expect(note.isFloating == true)
        #expect(note.isTranslucent == true)
        #expect(note.zOrder == 2)
    }

    @Test("Re-serializing a real state file reproduces the same values")
    func roundTripsTheGoldenFile() throws {
        let original = try realState()
        let reparsed = try SavedStickiesState(data: try original.serialized())

        // Value equality rather than byte equality: Stickies writes its keys in
        // a different order than PropertyListSerialization does, and key order
        // in a plist dictionary carries no meaning.
        #expect(reparsed == original)
    }

    @Test("An entry this version cannot parse costs that entry, not the file")
    func keepsUnreadableEntriesWithoutLosingTheRest() throws {
        let plist: [Any] = [
            ["UUID": "17", "Frame": "{{0, 0}, {300, 200}}",
             "StickyColor": ["Red": 1.0, "Green": 1.0, "Blue": 0.5, "Alpha": 1.0]],
            ["UUID": "18"],  // no Frame, no colour
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let state = try SavedStickiesState(data: data)

        #expect(state.notes.map(\.id.rawValue) == ["17"])
        #expect(state.entries.count == 2)
        #expect(state.unreadableReasons.count == 1)
    }

    @Test("An unreadable entry is written back untouched")
    func preservesUnreadableEntriesOnWrite() throws {
        let plist: [Any] = [["UUID": "18", "SomethingNew": 42]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let rewritten = try SavedStickiesState(data: try SavedStickiesState(data: data).serialized())
        guard case .unreadable(let value, _) = try #require(rewritten.entries.first) else {
            Issue.record("expected the entry to still be unreadable")
            return
        }

        #expect(value.dictionaryValue?["SomethingNew"] == .integer(42))
    }

    @Test("A state file whose root is not an array is refused")
    func refusesAnUnexpectedRoot() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Frame": "{{0, 0}, {1, 1}}"],
            format: .xml,
            options: 0
        )
        #expect(throws: SavedStickiesState.DecodingFailure.self) {
            try SavedStickiesState(data: data)
        }
    }

    @Test("Bytes that are not a property list are refused")
    func refusesGarbage() {
        #expect(throws: SavedStickiesState.DecodingFailure.self) {
            try SavedStickiesState(data: Data("not a property list".utf8))
        }
    }
}
