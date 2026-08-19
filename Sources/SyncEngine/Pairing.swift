import CryptoKit
import Foundation
import StickiesFormat

/// Getting the vault key onto a second Mac without putting it in the folder in
/// the clear.
///
/// The new Mac publishes a public key; the Mac that already has the vault wraps
/// the key to it and publishes the result. What makes that safe is not the
/// cryptography — it is the person. Anything with write access to the folder can
/// substitute its own public key in the request and be handed the vault, so the
/// approving Mac refuses unless whoever is typing repeats the code shown on the
/// requesting Mac's screen. That one string carries the trust the folder cannot.
///
/// The reverse direction is deliberately not verified. An attacker who replaces
/// the *grant* cannot produce the vault key, so the new Mac ends up unable to
/// open anything, which is a denial of service rather than a compromise —
/// provided it is loud, which is why `vault status` counts what it can open.
public enum Pairing {
    static let currentFormatVersion = 1
    static let info = "StickiesSync pairing v1"

    public enum PairingError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case unsupportedFormatVersion(found: Int, supported: Int)
        case codeMismatch(shown: String, typed: String)
        case cannotUnwrap

        public var description: String {
            switch self {
            case .malformed(let detail):
                "pairing file is malformed: \(detail)"
            case .unsupportedFormatVersion(let found, let supported):
                "pairing file format version \(found) is newer than the supported version \(supported)"
            case .codeMismatch(let shown, let typed):
                "the code in the folder is \(shown), not \(typed) — "
                    + "someone else may have published this request; refusing to grant the vault"
            case .cannotUnwrap:
                "the grant could not be opened with this Mac's identity key — "
                    + "it was written for a different Mac, or altered in the folder"
            }
        }
    }

    // MARK: - The code

    /// Twelve characters in three groups, over the requesting device and its
    /// public key.
    ///
    /// Sixty bits, not the thirty-two a shorter code would give: the attack this
    /// defends against is grinding a keypair whose code matches the one the user
    /// is about to read out, and forty bits of that is hours of GPU time rather
    /// than never. Twelve characters is still one glance and one paste.
    ///
    /// The alphabet omits `0`, `1`, `I` and `O`, which are the characters people
    /// mistype when copying between two screens.
    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    public static func code(for device: DeviceID, publicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(info.utf8))
        hasher.update(data: Data(device.rawValue.utf8))
        hasher.update(data: publicKey)
        let digest = Array(hasher.finalize())

        var characters: [Character] = []
        for index in 0..<12 {
            let bit = index * 5
            let window = (Int(digest[bit / 8]) << 8) | Int(digest[bit / 8 + 1])
            characters.append(alphabet[(window >> (11 - bit % 8)) & 0x1F])
        }

        return stride(from: 0, to: 12, by: 4)
            .map { String(characters[$0..<$0 + 4]) }
            .joined(separator: "-")
    }

    /// Dashes, case and surrounding space are all noise when someone is copying
    /// a code between two machines.
    public static func codesMatch(_ one: String, _ other: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.uppercased().filter { alphabet.contains($0) }
        }
        return !normalized(one).isEmpty && normalized(one) == normalized(other)
    }

    // MARK: - Granting

    /// Wraps the vault key so that only the holder of `request.publicKey` can
    /// read it.
    public static func grant(
        _ vault: Vault,
        to request: PairingRequest,
        from device: DeviceID,
        named deviceName: String,
        using identity: Curve25519.KeyAgreement.PrivateKey
    ) throws -> PairingGrant {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)
        let wrapping = try wrappingKey(
            identity.sharedSecretFromKeyAgreement(with: peer),
            granter: identity.publicKey.rawRepresentation,
            requester: request.publicKey
        )

        let sealed = try AES.GCM.seal(
            vault.rawKey.withUnsafeBytes { Data($0) },
            using: wrapping,
            authenticating: context(requester: request.device, granter: device, keyID: vault.keyID)
        )
        guard let combined = sealed.combined else {
            throw PairingError.malformed("sealed box has no combined representation")
        }

        return PairingGrant(
            device: device,
            deviceName: deviceName,
            publicKey: identity.publicKey.rawRepresentation,
            keyID: vault.keyID,
            sealed: combined
        )
    }

    /// Unwraps a grant into the vault it carries.
    public static func accept(
        _ grant: PairingGrant,
        as device: DeviceID,
        using identity: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Vault {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: grant.publicKey)
        let wrapping = try wrappingKey(
            identity.sharedSecretFromKeyAgreement(with: peer),
            granter: grant.publicKey,
            requester: identity.publicKey.rawRepresentation
        )

        let raw: Data
        do {
            raw = try AES.GCM.open(
                try AES.GCM.SealedBox(combined: grant.sealed),
                using: wrapping,
                authenticating: context(requester: device, granter: grant.device, keyID: grant.keyID)
            )
        } catch {
            throw PairingError.cannotUnwrap
        }
        guard raw.count == 32 else {
            throw PairingError.malformed("the wrapped vault key is \(raw.count) bytes, not 32")
        }
        return Vault(key: SymmetricKey(data: raw))
    }

    /// Both public keys go into the salt, so the wrapping key is bound to the
    /// exact pair of Macs rather than to the shared secret alone.
    private static func wrappingKey(
        _ shared: SharedSecret,
        granter: Data,
        requester: Data
    ) throws -> SymmetricKey {
        var hasher = SHA256()
        hasher.update(data: granter)
        hasher.update(data: requester)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(hasher.finalize()),
            sharedInfo: Data(info.utf8),
            outputByteCount: 32
        )
    }

    private static func context(requester: DeviceID, granter: DeviceID, keyID: String) -> Data {
        PlistValue.dictionary([
            "FormatVersion": .integer(currentFormatVersion),
            "Requester": .string(requester.rawValue),
            "Granter": .string(granter.rawValue),
            "KeyID": .string(keyID),
        ]).canonicalBytes
    }
}

/// A Mac asking to be let in. Published unencrypted, necessarily — it holds no
/// secret, and the Mac writing it has no key to seal it with yet.
public struct PairingRequest: Hashable, Sendable {
    public let device: DeviceID
    public let deviceName: String
    public let publicKey: Data
    public let requestedAt: Date

    public init(device: DeviceID, deviceName: String, publicKey: Data, requestedAt: Date) {
        self.device = device
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.requestedAt = requestedAt
    }

    /// What the user reads off this Mac's screen and types on the other one.
    public var code: String { Pairing.code(for: device, publicKey: publicKey) }
}

/// The vault key, wrapped so that only the requesting Mac can open it.
public struct PairingGrant: Hashable, Sendable {
    public let device: DeviceID
    public let deviceName: String
    public let publicKey: Data
    public let keyID: String
    public let sealed: Data

    public init(device: DeviceID, deviceName: String, publicKey: Data, keyID: String, sealed: Data) {
        self.device = device
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.keyID = keyID
        self.sealed = sealed
    }
}

// MARK: - Serialization

extension PairingRequest {
    public var plist: PlistValue {
        .dictionary([
            "FormatVersion": .integer(Pairing.currentFormatVersion),
            "Device": .string(device.rawValue),
            "DeviceName": .string(deviceName),
            "PublicKey": .data(publicKey),
            "RequestedAt": .date(requestedAt),
        ])
    }

    public init(data: Data) throws {
        let entry = try Pairing.dictionary(from: data)
        guard let device = entry["Device"]?.stringValue else {
            throw Pairing.PairingError.malformed("missing Device")
        }
        guard case .data(let publicKey)? = entry["PublicKey"], publicKey.count == 32 else {
            throw Pairing.PairingError.malformed("missing or unusable PublicKey")
        }
        self.init(
            device: DeviceID(rawValue: device),
            deviceName: entry["DeviceName"]?.stringValue ?? device,
            publicKey: publicKey,
            requestedAt: entry["RequestedAt"].flatMap { if case .date(let d) = $0 { d } else { nil } }
                ?? Date(timeIntervalSince1970: 0)
        )
    }

    public func serialized() throws -> Data { try Pairing.serialize(plist) }
}

extension PairingGrant {
    public var plist: PlistValue {
        .dictionary([
            "FormatVersion": .integer(Pairing.currentFormatVersion),
            "Device": .string(device.rawValue),
            "DeviceName": .string(deviceName),
            "PublicKey": .data(publicKey),
            "KeyID": .string(keyID),
            "Sealed": .data(sealed),
        ])
    }

    public init(data: Data) throws {
        let entry = try Pairing.dictionary(from: data)
        guard let device = entry["Device"]?.stringValue else {
            throw Pairing.PairingError.malformed("missing Device")
        }
        guard case .data(let publicKey)? = entry["PublicKey"], publicKey.count == 32 else {
            throw Pairing.PairingError.malformed("missing or unusable PublicKey")
        }
        guard case .data(let sealed)? = entry["Sealed"] else {
            throw Pairing.PairingError.malformed("missing Sealed")
        }
        self.init(
            device: DeviceID(rawValue: device),
            deviceName: entry["DeviceName"]?.stringValue ?? device,
            publicKey: publicKey,
            keyID: entry["KeyID"]?.stringValue ?? "",
            sealed: sealed
        )
    }

    public func serialized() throws -> Data { try Pairing.serialize(plist) }
}

extension Pairing {
    fileprivate static func dictionary(from data: Data) throws -> [String: PlistValue] {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = try? PlistValue(propertyList: object),
              let entry = plist.dictionaryValue
        else {
            throw PairingError.malformed("not a property list")
        }
        guard let version = entry["FormatVersion"]?.intValue else {
            throw PairingError.malformed("missing FormatVersion")
        }
        guard version <= currentFormatVersion else {
            throw PairingError.unsupportedFormatVersion(found: version, supported: currentFormatVersion)
        }
        return entry
    }

    fileprivate static func serialize(_ plist: PlistValue) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist.propertyList, format: .xml, options: 0)
    }
}

// MARK: - Carrying pairing over a transport

/// Pairing is transport-shaped, not folder-shaped: over a folder it is files
/// left for each other, and over a future LAN transport it would be a live
/// exchange. Its own protocol, so `SyncTransport` stays a dumb blob mover and a
/// transport that pairs differently is not forced through this shape.
public protocol PairingTransport: Sendable {
    func publish(request: PairingRequest) throws
    func pendingRequests() throws -> [PairingRequest]
    func publish(grant: PairingGrant, answering device: DeviceID) throws
    func grants(for device: DeviceID) throws -> [PairingGrant]
    /// Removes a device's whole pairing area, once it no longer needs one.
    func forgetPairing(of device: DeviceID) throws
}

/// ```
/// <root>/pairing/<requesting-device>/request.plist
/// <root>/pairing/<requesting-device>/grants/<granting-device>.plist
/// ```
///
/// Still write-disjoint in the way that matters: no two Macs ever write the same
/// file, which is the only thing iCloud Drive and Syncthing cannot handle. The
/// requesting Mac owns the directory named after it and is the one that clears it
/// up; a grant inside it is written once by the approver and never modified.
extension FolderTransport: PairingTransport {
    private var pairingDirectory: URL {
        devicesDirectory
            .deletingLastPathComponent()
            .appending(path: "pairing", directoryHint: .isDirectory)
    }

    private func pairingDirectory(of device: DeviceID) -> URL {
        pairingDirectory.appending(path: device.rawValue, directoryHint: .isDirectory)
    }

    public func publish(request: PairingRequest) throws {
        let directory = pairingDirectory(of: request.device)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try request.serialized().write(
            to: directory.appending(path: "request.plist", directoryHint: .notDirectory),
            options: .atomic
        )
    }

    public func pendingRequests() throws -> [PairingRequest] {
        let path = pairingDirectory.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }

        return names.sorted().compactMap { name in
            let url = pairingDirectory(of: DeviceID(rawValue: name))
                .appending(path: "request.plist", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PairingRequest(data: data)
        }
    }

    public func publish(grant: PairingGrant, answering device: DeviceID) throws {
        let directory = pairingDirectory(of: device)
            .appending(path: "grants", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try grant.serialized().write(
            to: directory.appending(path: "\(grant.device.rawValue).plist", directoryHint: .notDirectory),
            options: .atomic
        )
    }

    public func grants(for device: DeviceID) throws -> [PairingGrant] {
        let directory = pairingDirectory(of: device)
            .appending(path: "grants", directoryHint: .isDirectory)
        let path = directory.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }

        return names.sorted().compactMap { name in
            guard let data = try? Data(
                contentsOf: directory.appending(path: name, directoryHint: .notDirectory)
            ) else { return nil }
            return try? PairingGrant(data: data)
        }
    }

    public func forgetPairing(of device: DeviceID) throws {
        try? FileManager.default.removeItem(at: pairingDirectory(of: device))
    }
}
