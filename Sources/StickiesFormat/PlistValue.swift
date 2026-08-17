import Foundation

/// A property-list value with a type the compiler can see.
///
/// `.SavedStickiesState` entries have to be carried around, compared, and
/// written back, and `[String: Any]` supports none of those: it is neither
/// `Sendable` nor `Equatable`, and every read of it is an unchecked cast. The
/// cost of this enum is one conversion at each filesystem boundary; the benefit
/// is that everything above the boundary is ordinary typed Swift.
///
/// It also makes verbatim preservation possible. A key that a future macOS adds
/// to a state entry survives a read/write cycle as a `PlistValue` even though
/// no code here understands it — see `StickyWindowState.unrecognized`.
public enum PlistValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public enum ConversionError: Error, Equatable, CustomStringConvertible {
        case unsupportedType(String)

        public var description: String {
            switch self {
            case .unsupportedType(let name): "unsupported property-list type \(name)"
            }
        }
    }

    /// Wraps the `Any` a `PropertyListSerialization` call hands back.
    ///
    /// Booleans are checked before numbers because `CFBoolean` bridges to
    /// `NSNumber`; testing for `Int` first would turn every `true` into `1` and
    /// lose the distinction on write-back.
    public init(propertyList object: Any) throws {
        switch object {
        case let value as String:
            self = .string(value)
        case let value as Data:
            self = .data(value)
        case let value as Date:
            self = .date(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .double(value.doubleValue)
            } else {
                self = .integer(value.intValue)
            }
        case let value as [Any]:
            self = .array(try value.map(PlistValue.init(propertyList:)))
        case let value as [String: Any]:
            self = .dictionary(try value.mapValues(PlistValue.init(propertyList:)))
        default:
            throw ConversionError.unsupportedType(String(describing: type(of: object)))
        }
    }

    /// The `Any` form `PropertyListSerialization` expects back.
    public var propertyList: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .integer(let value): value
        case .double(let value): value
        case .date(let value): value
        case .data(let value): value
        case .array(let values): values.map(\.propertyList)
        case .dictionary(let values): values.mapValues(\.propertyList)
        }
    }
}

extension PlistValue {
    /// Uses the integer representation for whole values, matching how Stickies
    /// writes numbers, so a state file this tool rewrites stays diffable
    /// against one it did not.
    public static func number(_ value: Double) -> PlistValue {
        guard value == value.rounded(), let whole = Int(exactly: value.rounded()) else {
            return .double(value)
        }
        return .integer(whole)
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// Accepts either integer or real, because a property list that has been
    /// through an XML round trip can present a whole number as either.
    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .double(let value): Int(exactly: value.rounded())
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    public var dictionaryValue: [String: PlistValue]? {
        if case .dictionary(let value) = self { value } else { nil }
    }

    public var arrayValue: [PlistValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}
