import CoreGraphics
import Foundation

/// One of the four colours Stickies stores per note, as
/// `{Red, Green, Blue, Alpha}` reals in the 0…1 range.
public struct StickyColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(plist: PlistValue) throws {
        guard let dictionary = plist.dictionaryValue else {
            throw StickyWindowState.ParseError.wrongType(key: "colour", expected: "dictionary")
        }
        func component(_ key: String) throws -> Double {
            guard let value = dictionary[key]?.doubleValue else {
                throw StickyWindowState.ParseError.missingKey(key)
            }
            return value
        }
        self.init(
            red: try component("Red"),
            green: try component("Green"),
            blue: try component("Blue"),
            alpha: try component("Alpha")
        )
    }

    public var plist: PlistValue {
        .dictionary([
            "Red": .double(red),
            "Green": .double(green),
            "Blue": .double(blue),
            "Alpha": .double(alpha),
        ])
    }
}

/// The colours of a single note. Stickies derives the last three from the first
/// when it creates a note, but stores all four, so all four are replicated
/// rather than recomputed — a Mac on a different macOS release might shade them
/// differently, and the user's note should not change appearance because of it.
public struct StickyPalette: Hashable, Sendable {
    public var sticky: StickyColor
    public var spine: StickyColor?
    public var control: StickyColor?
    public var highlight: StickyColor?

    public init(
        sticky: StickyColor,
        spine: StickyColor? = nil,
        control: StickyColor? = nil,
        highlight: StickyColor? = nil
    ) {
        self.sticky = sticky
        self.spine = spine
        self.control = control
        self.highlight = highlight
    }
}

/// One entry of `.SavedStickiesState`: everything about a note that is not its
/// text.
///
/// Only `UUID`, `Frame`, and `StickyColor` are required. The rest are optional
/// because their absence has an unambiguous meaning — `ZOrder`, for instance,
/// is simply not written when a Mac has a single note — and because inventing a
/// default for a key a future macOS stops writing is the silent guess SPEC.md
/// F14 forbids. An absent optional is not written back, leaving Stickies to
/// supply its own default rather than having us assert one.
public struct StickyWindowState: Hashable, Sendable {
    public var id: StickyID
    public var frame: CGRect
    public var palette: StickyPalette
    public var expandedSize: CGSize?
    /// The y coordinate a collapsed note returns to when expanded
    /// (`setWindowFrame:expanded:expandFrameY:forUUID:`).
    public var expandFrameY: CGFloat?
    public var isFloating: Bool?
    public var isTranslucent: Bool?
    /// `NSTextCheckingTypes` bitmask; opaque to this tool, replicated verbatim.
    public var spellCheckingTypes: Int?
    /// Absent when the Mac has only one note.
    public var zOrder: Int?

    /// Keys this version does not understand, kept verbatim.
    ///
    /// `MultiScreenFrame` is the known example: the Stickies binary references
    /// it, but it has never been observed on a single-display Mac, so its value
    /// shape is unknown. Preserving it unparsed means a two-display Mac's
    /// per-screen positions survive a read/write cycle even though no code here
    /// can interpret them.
    public var unrecognized: [String: PlistValue]

    public init(
        id: StickyID,
        frame: CGRect,
        palette: StickyPalette,
        expandedSize: CGSize? = nil,
        expandFrameY: CGFloat? = nil,
        isFloating: Bool? = nil,
        isTranslucent: Bool? = nil,
        spellCheckingTypes: Int? = nil,
        zOrder: Int? = nil,
        unrecognized: [String: PlistValue] = [:]
    ) {
        self.id = id
        self.frame = frame
        self.palette = palette
        self.expandedSize = expandedSize
        self.expandFrameY = expandFrameY
        self.isFloating = isFloating
        self.isTranslucent = isTranslucent
        self.spellCheckingTypes = spellCheckingTypes
        self.zOrder = zOrder
        self.unrecognized = unrecognized
    }
}

extension StickyWindowState {
    enum Key {
        static let uuid = "UUID"
        static let frame = "Frame"
        static let expandedSize = "ExpandedSize"
        static let expandFrameY = "ExpandFrameY"
        static let floating = "Floating"
        static let translucent = "Translucent"
        static let spellCheckingTypes = "SpellCheckingTypes"
        static let zOrder = "ZOrder"
        static let stickyColor = "StickyColor"
        static let spineColor = "SpineColor"
        static let controlColor = "ControlColor"
        static let highlightColor = "HighlightColor"

        /// Every key this version interprets. Anything else lands in
        /// ``StickyWindowState/unrecognized``.
        static let known: Set<String> = [
            uuid, frame, expandedSize, expandFrameY, floating, translucent,
            spellCheckingTypes, zOrder, stickyColor, spineColor, controlColor, highlightColor,
        ]
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notADictionary
        case missingKey(String)
        case wrongType(key: String, expected: String)
        case invalidIdentifier(String)
        case invalidGeometry(key: String, text: String)

        public var description: String {
            switch self {
            case .notADictionary: "state entry is not a dictionary"
            case .missingKey(let key): "state entry is missing \(key)"
            case .wrongType(let key, let expected): "state entry key \(key) is not a \(expected)"
            case .invalidIdentifier(let raw): "state entry has an unusable UUID: \(raw)"
            case .invalidGeometry(let key, let text): "state entry key \(key) is not geometry: \(text)"
            }
        }
    }

    public init(plist: PlistValue) throws {
        guard let entry = plist.dictionaryValue else { throw ParseError.notADictionary }

        guard let rawIdentifier = entry[Key.uuid]?.stringValue else {
            throw ParseError.missingKey(Key.uuid)
        }
        guard let id = StickyID(rawValue: rawIdentifier) else {
            throw ParseError.invalidIdentifier(rawIdentifier)
        }
        guard let frameText = entry[Key.frame]?.stringValue else {
            throw ParseError.missingKey(Key.frame)
        }
        guard let stickyColor = entry[Key.stickyColor] else {
            throw ParseError.missingKey(Key.stickyColor)
        }

        self.init(
            id: id,
            frame: try Self.rect(frameText, key: Key.frame),
            palette: StickyPalette(
                sticky: try StickyColor(plist: stickyColor),
                spine: try entry[Key.spineColor].map(StickyColor.init(plist:)),
                control: try entry[Key.controlColor].map(StickyColor.init(plist:)),
                highlight: try entry[Key.highlightColor].map(StickyColor.init(plist:))
            ),
            expandedSize: try entry[Key.expandedSize]
                .map { try Self.size($0, key: Key.expandedSize) },
            expandFrameY: entry[Key.expandFrameY]?.doubleValue.map { CGFloat($0) },
            isFloating: entry[Key.floating]?.boolValue,
            isTranslucent: entry[Key.translucent]?.boolValue,
            spellCheckingTypes: entry[Key.spellCheckingTypes]?.intValue,
            zOrder: entry[Key.zOrder]?.intValue,
            unrecognized: entry.filter { !Key.known.contains($0.key) }
        )
    }

    /// Unrecognised keys are laid down first so a key this version *does* know
    /// always wins, even if it also appeared unrecognised through some future
    /// spelling collision.
    public var plist: PlistValue {
        var entry = unrecognized
        entry[Key.uuid] = .string(id.rawValue)
        entry[Key.frame] = .string(GeometryString.string(from: frame))
        entry[Key.stickyColor] = palette.sticky.plist
        entry[Key.spineColor] = palette.spine?.plist
        entry[Key.controlColor] = palette.control?.plist
        entry[Key.highlightColor] = palette.highlight?.plist
        entry[Key.expandedSize] = expandedSize.map { .string(GeometryString.string(from: $0)) }
        entry[Key.expandFrameY] = expandFrameY.map { .number(Double($0)) }
        entry[Key.floating] = isFloating.map { .bool($0) }
        entry[Key.translucent] = isTranslucent.map { .bool($0) }
        entry[Key.spellCheckingTypes] = spellCheckingTypes.map { .integer($0) }
        entry[Key.zOrder] = zOrder.map { .integer($0) }
        return .dictionary(entry)
    }

    private static func rect(_ text: String, key: String) throws -> CGRect {
        do { return try GeometryString.rect(text) } catch {
            throw ParseError.invalidGeometry(key: key, text: text)
        }
    }

    private static func size(_ value: PlistValue, key: String) throws -> CGSize {
        guard let text = value.stringValue else {
            throw ParseError.wrongType(key: key, expected: "string")
        }
        do { return try GeometryString.size(text) } catch {
            throw ParseError.invalidGeometry(key: key, text: text)
        }
    }
}
