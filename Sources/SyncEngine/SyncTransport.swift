import Foundation
import StickiesFormat

/// One Mac's published manifest, as bytes, with the Mac that published it.
public struct PublishedManifest: Hashable, Sendable {
    public let device: DeviceID
    public let bytes: Data

    public init(device: DeviceID, bytes: Data) {
        self.device = device
        self.bytes = bytes
    }
}

/// Moving opaque blobs between Macs.
///
/// The seam named in ARCHITECTURE #6, and since #55 it carries *bytes* rather
/// than notes — which is what SPEC.md principle 5 says a transport is: "any
/// medium that can carry opaque files between two Macs". A transport cannot
/// read what it moves, so it cannot be trusted with anything, and encryption
/// composes with every future one for free rather than being reimplemented in
/// each. `SealedChannel` is the only thing above it that turns blobs back into
/// notes.
///
/// The protocol is deliberately dumb — publish what this Mac holds, list who
/// else is out there, fetch one blob — because anything cleverer would push
/// merge policy into the transport.
public protocol SyncTransport: Sendable {
    /// Replaces this device's published state. Implementations must write only
    /// within their own device's area.
    func publish(manifest: Data, records: [RecordName: Data]) throws

    /// Every other device's manifest. One that cannot be read is skipped rather
    /// than failing the pass, so a single corrupt peer cannot stop the rest.
    func peerManifests(excluding device: DeviceID) throws -> [PublishedManifest]

    /// Fetches one blob. `nil` when the peer's manifest advertises a record that
    /// has not landed yet — normal on a folder the underlying syncer is still
    /// copying.
    func record(_ name: RecordName, from device: DeviceID) throws -> Data?
}

/// A shared directory in which no device ever writes outside its own subtree.
///
/// ```
/// <root>/devices/<device-id>/manifest.plist
/// <root>/devices/<device-id>/records/<name>.rec
/// ```
///
/// The write-disjoint layout is the whole point (#6). iCloud Drive, Syncthing and
/// Dropbox all handle two devices writing the same file badly — producing their
/// own conflict copies, silently, outside our control. If each device only ever
/// writes its own subtree, the underlying syncer never sees a write-write
/// conflict and every reconciliation happens where this project can reason about
/// it.
///
/// Record names are opaque (`Vault.name(of:)`), so the folder does not list the
/// user's note identifiers either.
public struct FolderTransport: SyncTransport {
    public enum TransportError: Error, CustomStringConvertible {
        case rootUnavailable(path: String, underlying: String)

        public var description: String {
            switch self {
            case .rootUnavailable(let path, let underlying):
                "cannot use \(path) as a sync folder: \(underlying)"
            }
        }
    }

    static let recordExtension = "rec"
    static let manifestName = "manifest.plist"

    private let root: URL
    private let device: DeviceID

    public init(root: URL, device: DeviceID) {
        self.root = root
        self.device = device
    }

    /// `FileManager.default` rather than an injected one: the transport has to
    /// be `Sendable` to cross a queue, `FileManager` is not, and no test has
    /// ever needed to substitute it — these tests use a real temporary folder,
    /// which is the thing being tested anyway.
    private var fileManager: FileManager { .default }

    var devicesDirectory: URL {
        root.appending(path: "devices", directoryHint: .isDirectory)
    }

    private func directory(for device: DeviceID) -> URL {
        devicesDirectory.appending(path: device.rawValue, directoryHint: .isDirectory)
    }

    private func manifestURL(for device: DeviceID) -> URL {
        directory(for: device).appending(path: Self.manifestName, directoryHint: .notDirectory)
    }

    private func recordsDirectory(for device: DeviceID) -> URL {
        directory(for: device).appending(path: "records", directoryHint: .isDirectory)
    }

    private func recordURL(_ name: RecordName, from device: DeviceID) -> URL {
        recordsDirectory(for: device)
            .appending(path: "\(name.rawValue).\(Self.recordExtension)", directoryHint: .notDirectory)
    }

    /// Records first, manifest last. A peer that reads mid-publish must never
    /// see a manifest advertising a record that has not landed — the other order
    /// would make `record(_:from:)` return nil for something the manifest
    /// promised, on every single pass.
    public func publish(manifest: Data, records: [RecordName: Data]) throws {
        let directory = recordsDirectory(for: device)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw TransportError.rootUnavailable(
                path: root.path(percentEncoded: false),
                underlying: error.localizedDescription
            )
        }

        var expected: Set<String> = []
        for (name, data) in records {
            let url = recordURL(name, from: device)
            expected.insert(url.lastPathComponent)

            // Skipping an identical rewrite keeps the underlying file syncer
            // idle when nothing has actually changed. iCloud Drive and Syncthing
            // both re-transfer a file whose mtime moved, content or not. Sealing
            // is deterministic precisely so that this comparison still works
            // (#56).
            if let existing = try? Data(contentsOf: url), existing == data { continue }
            try data.write(to: url, options: .atomic)
        }

        // A record for a note this Mac no longer knows about is dead weight, and
        // on a synced folder it is dead weight every peer keeps a copy of. This
        // is also what clears out the plaintext records written before
        // encryption: every name changed, so none of them is expected any more.
        let present = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in present where !expected.contains(name) && !name.hasPrefix(".") {
            try? fileManager.removeItem(
                at: directory.appending(path: name, directoryHint: .notDirectory)
            )
        }

        // Byte-identical manifests are not rewritten, for the same reason: an
        // agent polling every thirty seconds would otherwise push thousands of
        // identical files a day and wake every other device for each one (#49).
        let url = manifestURL(for: device)
        if let existing = try? Data(contentsOf: url), existing == manifest { return }
        try manifest.write(to: url, options: .atomic)
    }

    public func peerManifests(excluding device: DeviceID) throws -> [PublishedManifest] {
        guard fileManager.fileExists(atPath: devicesDirectory.path(percentEncoded: false)) else {
            return []
        }
        let names = try fileManager.contentsOfDirectory(
            atPath: devicesDirectory.path(percentEncoded: false)
        )

        return names.sorted()
            .filter { !$0.hasPrefix(".") && $0 != device.rawValue }
            .compactMap { name in
                // A manifest mid-copy is skipped rather than failing the pass:
                // one unreadable peer must not stop the others syncing. Whether
                // its *contents* make sense is the channel's business, not the
                // transport's.
                let peer = DeviceID(rawValue: name)
                guard let data = try? Data(contentsOf: manifestURL(for: peer)) else { return nil }
                return PublishedManifest(device: peer, bytes: data)
            }
    }

    public func record(_ name: RecordName, from device: DeviceID) throws -> Data? {
        try? Data(contentsOf: recordURL(name, from: device))
    }
}
