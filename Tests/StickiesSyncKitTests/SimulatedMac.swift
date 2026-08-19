import CoreGraphics
import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine

@testable import StickiesSyncKit

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// Stickies is never launched in these tests, so run state is always "closed"
/// and the apply path takes its no-quit branch.
struct ClosedStickies: StickiesProcessControlling {
    func runState() -> StickiesRunState { .notRunning }
    func quit(within timeout: TimeInterval) -> Bool { true }
    func launch() throws {}
}

/// A clock the test advances by hand. The conflict tiebreak reads timestamps, so
/// the winner has to be something a test can choose rather than something that
/// depends on how fast the machine ran.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_770_000_000)) {
        self.current = start
    }

    func now() -> Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval = 60) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func set(_ date: Date) {
        lock.withLock { current = date }
    }
}

/// One Mac: its own home directory, its own Stickies container, its own replica,
/// pointed at a sync folder it shares with the others.
///
/// Two of these plus one shared folder is the whole of Milestone 4's behaviour,
/// and the only way to test convergence without two computers.
final class SimulatedMac {
    let name: String
    let home: URL
    let clock: TestClock
    let replica: Replica
    let service: SyncService
    let transport: FolderTransport
    let vault: Vault

    private let fileManager = FileManager.default

    init(
        name: String,
        root: URL,
        syncFolder: URL,
        vault: Vault,
        clock: TestClock = TestClock()
    ) throws {
        self.name = name
        self.home = root.appending(path: name, directoryHint: .isDirectory)
        self.clock = clock

        try fileManager.createDirectory(
            at: ContainerLocator.stickiesDirectory(homeDirectory: home).root,
            withIntermediateDirectories: true
        )

        self.replica = try Replica.open(
            at: ContainerLocator.applicationSupportDirectory(homeDirectory: home)
                .appending(path: "replica.sqlite3", directoryHint: .notDirectory),
            deviceName: name,
            now: clock.now
        )
        self.transport = FolderTransport(root: syncFolder, device: replica.deviceID)
        self.vault = vault
        self.service = SyncService(
            home: home,
            replica: replica,
            channel: SealedChannel(transport: transport, vault: vault, device: replica.deviceID),
            reader: StickiesReader.forHome(home),
            coordinator: ApplyCoordinator.forHome(home, processControl: ClosedStickies()),
            now: clock.now
        )
    }

    /// Two Macs and the folder between them, both holding the same vault —
    /// which is what a completed pairing leaves behind. `Pairing` itself is
    /// exercised separately, in `PairingTests`.
    static func pair(
        _ body: (SimulatedMac, SimulatedMac, URL) throws -> Void
    ) throws {
        try pair(vaults: { let shared = Vault.generate(); return (shared, shared) }, body)
    }

    /// The same, with the two Macs' vaults chosen by the caller — for the case
    /// where they do *not* match.
    static func pair(
        vaults: () -> (Vault, Vault),
        _ body: (SimulatedMac, SimulatedMac, URL) throws -> Void
    ) throws {
        let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "StickiesSyncPair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appending(path: "SharedFolder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let (vaultA, vaultB) = vaults()
        try body(
            try SimulatedMac(name: "mac-a", root: root, syncFolder: folder, vault: vaultA),
            try SimulatedMac(name: "mac-b", root: root, syncFolder: folder, vault: vaultB),
            folder
        )
    }

    // MARK: - Acting as the user

    /// Writes a note straight into the container, which is what the user typing
    /// in Stickies amounts to as far as this project can see.
    func writeNote(
        _ raw: String,
        text: String,
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
        color: StickyColor = StickyColor(red: 1, green: 0.96, blue: 0.61)
    ) throws {
        guard let id = StickyID(rawValue: raw) else {
            throw FixtureError(description: "\(raw) is not a usable sticky identifier")
        }
        let note = StickyNote(
            id: id,
            package: try NotePackage(files: [NotePackage.richTextEntryName: Self.richText(text)]),
            windowState: StickyWindowState(id: id, frame: frame, palette: StickyPalette(sticky: color))
        )
        try ContainerWriter.forHome(home).apply(
            notes: [note],
            removing: [],
            mergingInto: try StickiesReader.forHome(home).read().savedState
        )
    }

    /// Leaves the note on disk but makes this Mac unable to read it.
    ///
    /// A nested directory inside the package is the deterministic stand-in for
    /// what happened in the field, where the read failed with a transient
    /// `EINTR`: either way the package exists and `StickiesReader` cannot turn it
    /// into a note. What is being tested is the reaction, which is identical.
    func makeNoteUnreadable(_ raw: String) throws {
        guard let id = StickyID(rawValue: raw) else {
            throw FixtureError(description: "\(raw) is not a usable sticky identifier")
        }
        try fileManager.createDirectory(
            at: ContainerLocator.stickiesDirectory(homeDirectory: home)
                .packageURL(for: id)
                .appending(path: "Attachments", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func deleteNote(_ raw: String) throws {
        guard let id = StickyID(rawValue: raw) else {
            throw FixtureError(description: "\(raw) is not a usable sticky identifier")
        }
        try ContainerWriter.forHome(home).apply(
            notes: [],
            removing: [id],
            mergingInto: try StickiesReader.forHome(home).read().savedState
        )
    }

    // MARK: - Observing

    func notes() throws -> [StickyNote] {
        try StickiesReader.forHome(home).read().notes
    }

    func text(of raw: String) throws -> String? {
        try notes().first { $0.id.rawValue == raw }?.package.plainText
    }

    func texts() throws -> [String] {
        try notes().compactMap(\.package.plainText).sorted()
    }

    @discardableResult
    func sync() throws -> SyncOutcome {
        try service.syncOnce()
    }

    static func richText(_ body: String) -> Data {
        Data(
            """
            {\\rtf1\\ansi\\ansicpg1252\\cocoartf2870
            {\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}
            \\pard\\tx560\\pardeftab560\\partightenfactor0
            \\f0\\fs28 \\cf0 \(body)}
            """.utf8
        )
    }
}
