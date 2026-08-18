import Foundation
import StickiesFormat

/// Moving records between Macs.
///
/// The seam named in ARCHITECTURE #6. Everything above it is transport-agnostic:
/// a Bonjour peer-to-peer or object-store backend replaces one conformance and
/// touches no note-handling code. The protocol is deliberately dumb — publish
/// what this Mac holds, list who else is out there, fetch one record — because
/// anything cleverer would push merge policy into the transport.
public protocol SyncTransport: Sendable {
    /// Replaces this device's published state. Implementations must write only
    /// within their own device's area.
    func publish(manifest: DeviceManifest, records: [SyncRecord]) throws

    /// Every other device's manifest. A manifest that cannot be read is skipped
    /// rather than failing the pass, so one corrupt peer cannot stop the rest.
    func peerManifests(excluding device: DeviceID) throws -> [DeviceManifest]

    /// Fetches one record. `nil` when the peer's manifest advertises a note whose
    /// record has not landed yet — normal on a folder the underlying syncer is
    /// still copying.
    func record(_ id: StickyID, from device: DeviceID) throws -> SyncRecord?
}

/// A shared directory in which no device ever writes outside its own subtree.
///
/// ```
/// <root>/devices/<device-id>/manifest.plist
/// <root>/devices/<device-id>/records/<sticky-id>.plist
/// ```
///
/// The write-disjoint layout is the whole point (#6). iCloud Drive, Syncthing and
/// Dropbox all handle two devices writing the same file badly — producing their
/// own conflict copies, silently, outside our control. If each device only ever
/// writes its own subtree, the underlying syncer never sees a write-write
/// conflict and every reconciliation happens where this project can reason about
/// it.
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

    private var devicesDirectory: URL {
        root.appending(path: "devices", directoryHint: .isDirectory)
    }

    private func directory(for device: DeviceID) -> URL {
        devicesDirectory.appending(path: device.rawValue, directoryHint: .isDirectory)
    }

    private func manifestURL(for device: DeviceID) -> URL {
        directory(for: device).appending(path: "manifest.plist", directoryHint: .notDirectory)
    }

    private func recordsDirectory(for device: DeviceID) -> URL {
        directory(for: device).appending(path: "records", directoryHint: .isDirectory)
    }

    private func recordURL(_ id: StickyID, from device: DeviceID) -> URL {
        recordsDirectory(for: device)
            .appending(path: "\(id.rawValue).plist", directoryHint: .notDirectory)
    }

    /// Records first, manifest last. A peer that reads mid-publish must never
    /// see a manifest advertising a record that has not landed — the other order
    /// would make `record(_:from:)` return nil for something the manifest
    /// promised, on every single pass.
    public func publish(manifest: DeviceManifest, records: [SyncRecord]) throws {
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
        for record in records {
            let url = recordURL(record.id, from: device)
            expected.insert(url.lastPathComponent)

            let data = try record.serialized()
            // Skipping an identical rewrite keeps the underlying file syncer
            // idle when nothing has actually changed. iCloud Drive and Syncthing
            // both re-transfer a file whose mtime moved, content or not.
            if let existing = try? Data(contentsOf: url), existing == data { continue }
            try data.write(to: url, options: .atomic)
        }

        // A record for a note this Mac no longer knows about is dead weight, and
        // on a synced folder it is dead weight every peer keeps a copy of.
        let present = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in present where !expected.contains(name) && !name.hasPrefix(".") {
            try? fileManager.removeItem(
                at: directory.appending(path: name, directoryHint: .notDirectory)
            )
        }

        // The manifest carries a publication time, so serializing it afresh
        // every pass would rewrite the file every pass — and a syncing service
        // re-uploads anything whose mtime moved. An agent polling every thirty
        // seconds would push thousands of identical manifests a day and wake
        // every other device for each one. Only what the manifest *says* is
        // worth republishing.
        let url = manifestURL(for: device)
        if let existing = try? DeviceManifest(data: try Data(contentsOf: url)),
           existing.entries == manifest.entries,
           existing.deviceName == manifest.deviceName
        {
            return
        }
        try manifest.serialized().write(to: url, options: .atomic)
    }

    public func peerManifests(excluding device: DeviceID) throws -> [DeviceManifest] {
        guard fileManager.fileExists(atPath: devicesDirectory.path(percentEncoded: false)) else {
            return []
        }
        let names = try fileManager.contentsOfDirectory(
            atPath: devicesDirectory.path(percentEncoded: false)
        )

        return names.sorted()
            .filter { !$0.hasPrefix(".") && $0 != device.rawValue }
            .compactMap { name in
                // A manifest mid-copy, or written by a newer StickiesSync, is
                // skipped rather than failing the pass: one unreadable peer must
                // not stop the others syncing.
                let url = manifestURL(for: DeviceID(rawValue: name))
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? DeviceManifest(data: data)
            }
    }

    public func record(_ id: StickyID, from device: DeviceID) throws -> SyncRecord? {
        let url = recordURL(id, from: device)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try SyncRecord(data: data)
    }
}
