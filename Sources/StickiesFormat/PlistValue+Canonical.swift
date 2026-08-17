import Foundation

extension PlistValue {
    /// A deterministic byte encoding, for hashing.
    ///
    /// Neither of the obvious alternatives works. Swift's `Hashable` is seeded
    /// per process, so a hash computed today does not match the same value
    /// hashed tomorrow. A serialized property list is not canonical either:
    /// dictionary key order depends on the hash table's layout, so the same
    /// window state can serialize two ways.
    ///
    /// This encoding sorts dictionary keys and length-prefixes every string and
    /// blob, so no two distinct values can produce the same bytes by running
    /// together at a boundary.
    public var canonicalBytes: Data {
        var bytes = Data()
        appendCanonicalBytes(to: &bytes)
        return bytes
    }

    private func appendCanonicalBytes(to bytes: inout Data) {
        switch self {
        case .string(let value):
            bytes.append(tag: "s", payload: Data(value.utf8))
        case .bool(let value):
            bytes.append(tag: "b", payload: Data([value ? 1 : 0]))
        case .integer(let value):
            bytes.append(tag: "i", payload: Data(String(value).utf8))
        case .double(let value):
            // A fixed-notation description, so 1.0 and 1 do not collide but the
            // same double always prints the same way.
            bytes.append(tag: "d", payload: Data(String(format: "%.17g", value).utf8))
        case .date(let value):
            bytes.append(tag: "t", payload: Data(String(format: "%.6f", value.timeIntervalSince1970).utf8))
        case .data(let value):
            bytes.append(tag: "x", payload: value)
        case .array(let values):
            bytes.append(tag: "a", payload: Data(String(values.count).utf8))
            for value in values {
                value.appendCanonicalBytes(to: &bytes)
            }
        case .dictionary(let values):
            bytes.append(tag: "m", payload: Data(String(values.count).utf8))
            for key in values.keys.sorted() {
                bytes.append(tag: "k", payload: Data(key.utf8))
                values[key]?.appendCanonicalBytes(to: &bytes)
            }
        }
    }
}

extension Data {
    /// `<tag><length as decimal>:<payload>` — the length prefix is what stops
    /// `["ab", "c"]` and `["a", "bc"]` from encoding identically.
    fileprivate mutating func append(tag: Character, payload: Data) {
        append(contentsOf: Array(String(tag).utf8))
        append(contentsOf: Array(String(payload.count).utf8))
        append(UInt8(ascii: ":"))
        append(payload)
    }
}
