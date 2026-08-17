import CoreGraphics
import Foundation
import Testing

@testable import StickiesFormat

@Suite("GeometryString")
struct GeometryStringTests {
    @Test("Parses the frame strings Stickies actually writes")
    func parsesRealFrames() throws {
        // Both taken verbatim from a real .SavedStickiesState. The brace count
        // is what a first implementation got wrong, and only real input caught
        // it: a rect has three braces, not two.
        #expect(try GeometryString.rect("{{8, 1110}, {300, 200}}") == CGRect(x: 8, y: 1110, width: 300, height: 200))
        #expect(try GeometryString.rect("{{400, 700}, {360, 240}}") == CGRect(x: 400, y: 700, width: 360, height: 240))
    }

    @Test("Parses the size strings Stickies actually writes")
    func parsesRealSizes() throws {
        #expect(try GeometryString.size("{300, 200}") == CGSize(width: 300, height: 200))
        #expect(try GeometryString.size("{360, 240}") == CGSize(width: 360, height: 240))
    }

    @Test("Accepts negative and fractional coordinates")
    func parsesNegativeAndFractional() throws {
        // A note dragged onto a display left of the main one has a negative x.
        #expect(try GeometryString.rect("{{-1440, 12.5}, {300, 200}}")
            == CGRect(x: -1440, y: 12.5, width: 300, height: 200))
    }

    @Test("Rejects malformed input instead of yielding a zero rect", arguments: [
        "",
        "{}",
        "8, 1110, 300, 200",
        "{{8, 1110}, {300}}",
        "{{8, 1110}, {300, 200}",
        "{{8, 1110} {300, 200}}",
        "{{8, 1110}, {300, 200, 4}}",
        "{{eight, 1110}, {300, 200}}",
        "{{8, inf}, {300, 200}}",
    ])
    func rejectsMalformedRects(text: String) {
        // NSRectFromString would answer NSZeroRect here, which is
        // indistinguishable from a genuine zero rect.
        #expect(throws: GeometryString.ParseError.malformed(text)) {
            try GeometryString.rect(text)
        }
    }

    @Test("Rejects a rect passed where a size belongs, and vice versa")
    func rejectsMismatchedShapes() {
        #expect(throws: GeometryString.ParseError.self) {
            try GeometryString.size("{{8, 1110}, {300, 200}}")
        }
        #expect(throws: GeometryString.ParseError.self) {
            try GeometryString.rect("{300, 200}")
        }
    }

    @Test("Formats whole numbers without a decimal point, as Stickies does")
    func formatsLikeStickies() {
        #expect(GeometryString.string(from: CGRect(x: 8, y: 1110, width: 300, height: 200))
            == "{{8, 1110}, {300, 200}}")
        #expect(GeometryString.string(from: CGSize(width: 300, height: 200)) == "{300, 200}")
    }

    @Test("Round-trips every frame in the real state file")
    func roundTripsRealFrames() throws {
        for text in ["{{8, 1110}, {300, 200}}", "{{400, 700}, {360, 240}}", "{{-1440, 12.5}, {300, 200}}"] {
            #expect(GeometryString.string(from: try GeometryString.rect(text)) == text)
        }
    }
}
