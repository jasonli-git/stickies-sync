import CryptoKit
import Foundation
import StickiesFormat

/// The key every Mac in one person's set shares, and the sealing built on it.
///
/// One symmetric key rather than sealing each record to each device's public
/// key: with N Macs the latter means N wrapped copies of every record and a
/// re-publish of everything whenever a Mac joins, and it buys revocation that is
/// worth nothing here — a Mac that leaves already holds every note in plaintext
/// on its own disk. Per-record keys wrapped per device is the seam if notes are
/// ever shared between *people*, which SPEC.md lists as a non-goal.
///
/// Confidentiality and authenticity come from the same place. An outsider cannot
/// read a record, and equally cannot produce one: sealed bytes that were not
/// written under this key fail to open, so a `devices/` subtree published by
/// something that does not hold the key is refused rather than applied. Records
/// are not separately signed, because every holder of the key is the same
/// person's hardware; Ed25519 per record is the seam the day that stops being
/// true.
public struct Vault: Sendable {
    /// Everything derived from the vault key is derived through HKDF with a
    /// distinct `info`, so no two purposes ever share key material.
    private enum Purpose: String {
        case record = "StickiesSync record v1"
        case manifest = "StickiesSync manifest v1"
        case name = "StickiesSync record name v1"
        case nonce = "StickiesSync nonce v1"
    }

    public enum VaultError: Error, Equatable, CustomStringConvertible {
        case sealedUnderADifferentKey(found: String, held: String)
        case unsupportedFormatVersion(found: Int, supported: Int)
        case notSealed
        case malformed(String)
        case cannotOpen

        public var description: String {
            switch self {
            case .sealedUnderADifferentKey(let found, let held):
                "sealed under vault \(found), but this Mac holds vault \(held)"
            case .unsupportedFormatVersion(let found, let supported):
                "sealed with format version \(found), newer than the supported version \(supported)"
            case .notSealed:
                "this is not sealed data — it looks like a record from before encryption"
            case .malformed(let detail):
                "sealed data is malformed: \(detail)"
            case .cannotOpen:
                "sealed data could not be opened: it was altered, or sealed under a different key"
            }
        }
    }

    static let currentFormatVersion = 2

    private enum Key {
        static let formatVersion = "FormatVersion"
        static let keyID = "KeyID"
        static let sealed = "Sealed"
    }

    private let key: SymmetricKey

    /// Names the vault without revealing it — the first eight bytes of the key's
    /// SHA-256. Published in the clear on every sealed file so a Mac holding the
    /// wrong key can say exactly that instead of reporting corruption.
    public let keyID: String

    public init(key: SymmetricKey) {
        self.key = key
        self.keyID = Self.identifier(of: key)
    }

    public static func generate() -> Vault {
        Vault(key: SymmetricKey(size: .bits256))
    }

    /// The raw key, for wrapping to a peer during pairing and for nothing else.
    var rawKey: SymmetricKey { key }

    static func identifier(of key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func subkey(_ purpose: Purpose) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            info: Data(purpose.rawValue.utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Naming

    /// The filename a note's record is published under.
    ///
    /// Derived rather than random, because a peer has to arrive at the same name
    /// to fetch the record: both Macs compute `HMAC(name key, identifier)` and
    /// get the same string without ever exchanging it. It also keeps the note
    /// identifiers themselves out of the folder listing.
    public func name(of id: StickyID) -> RecordName {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(id.rawValue.utf8),
            using: subkey(.name)
        )
        return RecordName(derived: mac.prefix(16).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Sealing

    public func seal(record: SyncRecord, publishedBy device: DeviceID) throws -> Data {
        try seal(
            try record.serialized(),
            purpose: .record,
            context: context(device: device, name: name(of: record.id).rawValue)
        )
    }

    public func open(record data: Data, publishedBy device: DeviceID, named name: RecordName) throws -> SyncRecord {
        try SyncRecord(
            data: try open(data, purpose: .record, context: context(device: device, name: name.rawValue))
        )
    }

    public func seal(manifest: DeviceManifest, publishedBy device: DeviceID) throws -> Data {
        try seal(
            try manifest.serialized(),
            purpose: .manifest,
            context: context(device: device, name: "manifest")
        )
    }

    public func open(manifest data: Data, publishedBy device: DeviceID) throws -> DeviceManifest {
        try DeviceManifest(
            data: try open(data, purpose: .manifest, context: context(device: device, name: "manifest"))
        )
    }

    /// What the ciphertext is bound to: the format, the vault, the Mac that
    /// published it, and the name it was published under.
    ///
    /// Without this an attacker who can read nothing can still *move* sealed
    /// files around — a record dropped into another Mac's subtree, or renamed
    /// onto a different note's filename, would open and be believed. Bound, it
    /// fails to open the moment it is anywhere other than where it was written.
    private func context(device: DeviceID, name: String) -> Data {
        PlistValue.dictionary([
            Key.formatVersion: .integer(Self.currentFormatVersion),
            Key.keyID: .string(keyID),
            "Device": .string(device.rawValue),
            "Name": .string(name),
        ]).canonicalBytes
    }

    private func seal(_ plaintext: Data, purpose: Purpose, context: Data) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext,
            using: subkey(purpose),
            nonce: try nonce(for: plaintext, context: context),
            authenticating: context
        )
        guard let combined = box.combined else {
            throw VaultError.malformed("sealed box has no combined representation")
        }

        return try PropertyListSerialization.data(
            fromPropertyList: PlistValue.dictionary([
                Key.formatVersion: .integer(Self.currentFormatVersion),
                Key.keyID: .string(keyID),
                Key.sealed: .data(combined),
            ]).propertyList,
            format: .xml,
            options: 0
        )
    }

    private func open(_ data: Data, purpose: Purpose, context: Data) throws -> Data {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = try? PlistValue(propertyList: object),
              let entry = plist.dictionaryValue
        else {
            throw VaultError.malformed("not a property list")
        }

        guard let formatVersion = entry[Key.formatVersion]?.intValue else {
            throw VaultError.malformed("missing \(Key.formatVersion)")
        }
        // A plaintext record from before encryption parses as a property list and
        // has a format version of its own, so it has to be told apart by shape
        // and named for what it is. Believing one would leave the hole this
        // milestone exists to close propped open by backward compatibility.
        guard entry[Key.sealed] != nil else { throw VaultError.notSealed }
        guard formatVersion <= Self.currentFormatVersion else {
            throw VaultError.unsupportedFormatVersion(
                found: formatVersion,
                supported: Self.currentFormatVersion
            )
        }
        guard let found = entry[Key.keyID]?.stringValue else {
            throw VaultError.malformed("missing \(Key.keyID)")
        }
        guard found == keyID else {
            throw VaultError.sealedUnderADifferentKey(found: found, held: keyID)
        }
        guard case .data(let combined)? = entry[Key.sealed] else {
            throw VaultError.malformed("\(Key.sealed) is not data")
        }

        do {
            return try AES.GCM.open(
                try AES.GCM.SealedBox(combined: combined),
                using: subkey(purpose),
                authenticating: context
            )
        } catch {
            throw VaultError.cannotOpen
        }
    }

    /// A nonce derived from what is being sealed, not a random one.
    ///
    /// This is load-bearing for reasons that have nothing to do with secrecy.
    /// Decisions #48 and #49 were measured against a real iCloud folder: an
    /// unchanged note must re-publish to *byte-identical* bytes, or the file
    /// syncer re-uploads it and wakes every other Mac. A random nonce produces
    /// fresh ciphertext on every pass, so an agent polling every thirty seconds
    /// would push the entire folder daily and undo both decisions silently.
    ///
    /// Deriving the nonce from the plaintext (the synthetic-IV construction)
    /// keeps identical inputs sealing identically while giving distinct inputs
    /// distinct nonces, which is the property AES-GCM actually requires. The
    /// context bytes are length-prefixed and so self-delimiting, so no two
    /// different (context, plaintext) pairs can run together into the same input.
    ///
    /// What it concedes: an observer can see that a record did not change. The
    /// modification time already told them that.
    private func nonce(for plaintext: Data, context: Data) throws -> AES.GCM.Nonce {
        let mac = HMAC<SHA256>.authenticationCode(for: context + plaintext, using: subkey(.nonce))
        return try AES.GCM.Nonce(data: Data(mac.prefix(12)))
    }
}

/// The name a sealed record is published under.
///
/// A distinct type because the string becomes a filename on every transport that
/// stores files. Names are always derived locally by `Vault.name(of:)` and are
/// therefore always hexadecimal, but a transport must not have to take that on
/// trust — `StickyID` validates against path escapes for the same reason (#2).
public struct RecordName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    init(derived: String) {
        self.rawValue = derived
    }

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              !rawValue.contains("/"),
              !rawValue.contains(":"),
              rawValue != ".",
              rawValue != ".."
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
