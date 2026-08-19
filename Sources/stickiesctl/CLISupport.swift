import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import StickiesSyncKit
import SyncEngine

/// Shared by every command that reads a container, so `--home` means the same
/// thing everywhere and tests can point any command at a fixture.
struct ContainerOptions: ParsableArguments {
    @Option(
        name: .customLong("home"),
        help: ArgumentHelp(
            "Read a synthetic home directory instead of the real one.",
            valueName: "path"
        )
    )
    var homeDirectory: String?

    var home: URL {
        homeDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? ContainerLocator.currentHomeDirectory
    }

    /// The engine has no idea where a Mac keeps things, so the CLI is what joins
    /// `ContainerLocator`'s layout to `Replica.open`.
    var replicaURL: URL {
        ContainerLocator.applicationSupportDirectory(homeDirectory: home)
            .appending(path: "replica.sqlite3", directoryHint: .notDirectory)
    }

    func openReplica() throws -> Replica {
        try Replica.open(at: replicaURL)
    }

    var vaultURL: URL {
        ContainerLocator.applicationSupportDirectory(homeDirectory: home)
            .appending(path: "vault.plist", directoryHint: .notDirectory)
    }

    func vaultStore() -> FileVaultStore {
        FileVaultStore(url: vaultURL)
    }

    /// Nothing syncs without a vault, and the refusal names the way out.
    ///
    /// There is no unencrypted mode to fall back to (#57): a "just this once"
    /// flag is exactly the sort of thing that stays on, and every note in the
    /// folder would be readable by whoever holds the folder.
    func requireVault() throws -> Vault {
        guard let vault = try vaultStore().vault() else {
            throw ValidationError(
                """
                this Mac has no vault key, so it cannot sync.

                  On the first Mac:   stickiesctl vault init
                  On every other one: stickiesctl pair request
                """
            )
        }
        return vault
    }

    func configuredSyncFolder() throws -> URL {
        guard let folder = SyncConfiguration.load(home: home).syncFolder else {
            throw ValidationError(
                "no sync folder configured — run `stickiesctl sync --folder <path>` once to set one"
            )
        }
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            throw ValidationError(
                "the configured sync folder \(folder.path(percentEncoded: false)) does not exist"
            )
        }
        return folder
    }

    /// Reads the container and hands its notes to the replica. The one place the
    /// store and the engine meet.
    func reconcile(_ replica: Replica) throws -> (changes: [NoteChange], snapshot: StickiesSnapshot) {
        let snapshot = try StickiesReader.forHome(home).read()
        return (
            try replica.reconcile(
                with: snapshot.notes,
                presentButUnreadable: snapshot.unreadableNoteIDs
            ),
            snapshot
        )
    }
}

extension NoteChange {
    var glyph: String {
        switch kind {
        case .added: "+"
        case .edited: isGeometryOnly ? "~" : "*"
        case .deleted: "-"
        case .reappeared: "^"
        }
    }
}

extension ContainerOptions {
    /// Refuses to proceed when the container cannot be read.
    ///
    /// Exists because a sync daemon that reads nothing is worse than no daemon:
    /// it fails every thirty seconds into a log file nobody opens. Whether the
    /// container needs a Full Disk Access grant differs between Macs in a way
    /// this project cannot yet explain, so the check is made at the moment a
    /// person is watching rather than assumed away.
    func requireReadableContainer(_ action: String) throws {
        let report = ContainerProbe.forHome(home).run()
        guard report.access != .readable else { return }

        let failures = report.diagnostics()
            .filter { $0.status == .failure }
            .map { "  \($0.name): \($0.detail)" }
        throw ValidationError(
            "cannot \(action): this Mac's Stickies container is not readable.\n"
                + failures.joined(separator: "\n")
        )
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Left-aligned fixed-width columns sized to their contents.
enum Table {
    static func render(header: [String], rows: [[String]]) -> String {
        let widths = ([header] + rows).reduce(into: [Int](repeating: 0, count: header.count)) {
            widths, row in
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func line(_ row: [String]) -> String {
            row.enumerated()
                .map { index, cell in
                    index == row.count - 1
                        ? cell
                        : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }
                .joined(separator: "  ")
        }

        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }
}

extension StickyColor {
    /// Eight-bit hex, which is how a person recognises a sticky colour. The
    /// stored components are floats and are replicated as floats; this is for
    /// reading only.
    var hexDescription: String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

extension StickiesSnapshot {
    /// Everything the read could not account for, as lines for stderr. Empty
    /// when the container was fully understood.
    var problemLines: [String] {
        unreadableNotes.map { "unreadable note \($0.id): \($0.reason)" }
            + unreadableStateEntries.map { "unreadable state entry: \($0)" }
            + unrecognizedEntries.map { "unrecognised container entry: \($0)" }
            + notesWithoutState.map { "note \($0.id) has no window state: position and colour are unknown" }
    }
}
