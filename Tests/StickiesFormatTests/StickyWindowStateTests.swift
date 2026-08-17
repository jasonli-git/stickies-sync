import CoreGraphics
import Foundation
import Testing

@testable import StickiesFormat

@Suite("StickyWindowState")
struct StickyWindowStateTests {
    private let yellow = StickyColor(red: 1, green: 0.96, blue: 0.61)

    private func entry(_ overrides: [String: PlistValue] = [:]) -> PlistValue {
        var dictionary: [String: PlistValue] = [
            "UUID": .string("17"),
            "Frame": .string("{{0, 0}, {300, 200}}"),
            "StickyColor": yellow.plist,
        ]
        for (key, value) in overrides { dictionary[key] = value }
        return .dictionary(dictionary)
    }

    @Test("The three required keys are the three a note cannot be replicated without", arguments: [
        "UUID", "Frame", "StickyColor",
    ])
    func requiresTheEssentialKeys(missing: String) throws {
        var dictionary = try #require(entry().dictionaryValue)
        dictionary[missing] = nil

        #expect(throws: StickyWindowState.ParseError.missingKey(missing)) {
            try StickyWindowState(plist: .dictionary(dictionary))
        }
    }

    @Test("Everything else is optional and absent means absent, not zero")
    func optionalKeysStayNil() throws {
        let state = try StickyWindowState(plist: entry())

        #expect(state.expandedSize == nil)
        #expect(state.expandFrameY == nil)
        #expect(state.isFloating == nil)
        #expect(state.isTranslucent == nil)
        #expect(state.spellCheckingTypes == nil)
        #expect(state.zOrder == nil)
        #expect(state.palette.spine == nil)
    }

    @Test("An absent optional is not written back, leaving Stickies its own default")
    func absentOptionalsAreNotWritten() throws {
        let written = try #require(try StickyWindowState(plist: entry()).plist.dictionaryValue)

        #expect(written.keys.sorted() == ["Frame", "StickyColor", "UUID"])
    }

    @Test("A key this version does not know survives a read and a write")
    func preservesUnrecognizedKeys() throws {
        // MultiScreenFrame is the real case: referenced by the Stickies binary,
        // never observed on a single-display Mac, so its shape is unknown.
        let state = try StickyWindowState(plist: entry([
            "MultiScreenFrame": .dictionary(["Display1": .string("{{0, 0}, {300, 200}}")]),
        ]))

        #expect(state.unrecognized.keys.sorted() == ["MultiScreenFrame"])

        let written = try #require(state.plist.dictionaryValue)
        #expect(written["MultiScreenFrame"]?.dictionaryValue?["Display1"]
            == .string("{{0, 0}, {300, 200}}"))
    }

    @Test("A known key is never shadowed by an unrecognised one")
    func knownKeysWinOverUnrecognized() throws {
        var state = try StickyWindowState(plist: entry())
        state.unrecognized["Frame"] = .string("{{9, 9}, {9, 9}}")

        #expect(state.plist.dictionaryValue?["Frame"] == .string("{{0, 0}, {300, 200}}"))
    }

    @Test("A frame that is not geometry is refused rather than read as zero")
    func refusesMalformedGeometry() {
        #expect(throws: StickyWindowState.ParseError.invalidGeometry(key: "Frame", text: "somewhere")) {
            try StickyWindowState(plist: entry(["Frame": .string("somewhere")]))
        }
        #expect(throws: StickyWindowState.ParseError.invalidGeometry(key: "ExpandedSize", text: "big")) {
            try StickyWindowState(plist: entry(["ExpandedSize": .string("big")]))
        }
    }

    @Test("An identifier that could escape the container is refused")
    func refusesUnusableIdentifiers() {
        #expect(throws: StickyWindowState.ParseError.invalidIdentifier("../escape")) {
            try StickyWindowState(plist: entry(["UUID": .string("../escape")]))
        }
    }

    @Test("A colour missing a channel is refused")
    func refusesIncompleteColours() {
        #expect(throws: StickyWindowState.ParseError.missingKey("Alpha")) {
            try StickyWindowState(plist: entry([
                "StickyColor": .dictionary(["Red": .double(1), "Green": .double(1), "Blue": .double(1)]),
            ]))
        }
    }

    @Test("A fully populated entry round-trips through the plist form")
    func roundTripsAFullEntry() throws {
        let original = try StickyWindowState(plist: entry([
            "ExpandedSize": .string("{300, 200}"),
            "ExpandFrameY": .integer(0),
            "Floating": .bool(true),
            "Translucent": .bool(false),
            "SpellCheckingTypes": .integer(9191),
            "ZOrder": .integer(2),
            "SpineColor": yellow.plist,
            "ControlColor": yellow.plist,
            "HighlightColor": yellow.plist,
            "MultiScreenFrame": .array([.string("{{0, 0}, {1, 1}}")]),
        ]))

        #expect(try StickyWindowState(plist: original.plist) == original)
    }
}
