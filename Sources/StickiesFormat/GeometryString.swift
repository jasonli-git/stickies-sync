import CoreGraphics
import Foundation

/// Reads and writes the geometry strings Stickies stores in
/// `.SavedStickiesState`: `"{{8, 1110}, {300, 200}}"` for a frame and
/// `"{300, 200}"` for a size.
///
/// Foundation's `NSRectFromString` would do this in one call, but it answers
/// malformed input with `NSZeroRect` — indistinguishable from a genuine zero
/// rect, and exactly the silent guess SPEC.md F14 rules out. This parser is
/// strict: anything it does not understand is an error the caller must handle.
public enum GeometryString {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)

        public var description: String {
            switch self {
            case .malformed(let text): "not a geometry string: \(text)"
            }
        }
    }

    /// Punctuation-only skeletons of the two shapes, with `#` standing in for a
    /// number. Comparing against these rejects a string whose punctuation is
    /// merely *plausible* — `"{{8, 1110} {300, 200}}"`, missing the comma
    /// between the groups, has the right brace count and the right number count
    /// and is still not a rect.
    private static let sizeSkeleton = "{#,#}"
    private static let rectSkeleton = "{{#,#},{#,#}}"

    public static func size(_ text: String) throws -> CGSize {
        let numbers = try scalars(in: text, matching: sizeSkeleton)
        return CGSize(width: numbers[0], height: numbers[1])
    }

    public static func rect(_ text: String) throws -> CGRect {
        let numbers = try scalars(in: text, matching: rectSkeleton)
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    public static func string(from size: CGSize) -> String {
        "{\(number(size.width)), \(number(size.height))}"
    }

    public static func string(from rect: CGRect) -> String {
        "{{\(number(rect.origin.x)), \(number(rect.origin.y))}, "
            + "{\(number(rect.width)), \(number(rect.height))}}"
    }

    /// Whole numbers are written without a decimal point, matching what Stickies
    /// itself writes, so a state file this tool rewrites stays diffable against
    /// one it did not.
    private static func number(_ value: CGFloat) -> String {
        let rounded = value.rounded()
        return value == rounded && abs(value) < 1e15
            ? String(Int(rounded))
            : String(describing: value)
    }

    /// Walks the string once, collecting numeric runs and building the
    /// punctuation skeleton as it goes, then insists the skeleton is exactly the
    /// expected one. Whitespace is ignored because Stickies writes `", "` and
    /// nothing hinges on it.
    private static func scalars(in text: String, matching skeleton: String) throws -> [CGFloat] {
        var shape = ""
        var fields: [String] = []
        var current = ""

        func closeField() {
            guard !current.isEmpty else { return }
            shape.append("#")
            fields.append(current)
            current = ""
        }

        for character in text where !character.isWhitespace {
            if character == "{" || character == "}" || character == "," {
                closeField()
                shape.append(character)
            } else {
                current.append(character)
            }
        }
        closeField()

        guard shape == skeleton else { throw ParseError.malformed(text) }

        return try fields.map { field in
            guard let value = Double(field), value.isFinite else {
                throw ParseError.malformed(text)
            }
            return CGFloat(value)
        }
    }
}
