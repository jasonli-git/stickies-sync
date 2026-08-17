import Foundation
import StickiesFormat

/// Writes note packages and the state file into a Stickies container.
///
/// Knows nothing about whether Stickies is running — that judgement belongs to
/// `ApplyCoordinator`, which must never call this while the application holds
/// the notes open. Every install goes through a scratch directory and an atomic
/// replace, so a note is never half-written even though the operation as a whole
/// is not atomic; the backup taken by the coordinator covers the rest.
public struct ContainerWriter {
    public enum WriteError: Error, CustomStringConvertible {
        case scratchUnavailable(String)
        case packageWriteFailed(id: StickyID, underlying: String)
        case stateWriteFailed(String)

        public var description: String {
            switch self {
            case .scratchUnavailable(let message):
                "could not prepare a scratch directory: \(message)"
            case .packageWriteFailed(let id, let message):
                "could not write note \(id): \(message)"
            case .stateWriteFailed(let message):
                "could not write the window-state file: \(message)"
            }
        }
    }

    private let directory: StickiesDirectory
    private let scratchRoot: URL
    private let fileManager: FileManager

    public init(directory: StickiesDirectory, scratchRoot: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.scratchRoot = scratchRoot
        self.fileManager = fileManager
    }

    public static func forHome(
        _ homeDirectory: URL = ContainerLocator.currentHomeDirectory,
        fileManager: FileManager = .default
    ) -> ContainerWriter {
        ContainerWriter(
            directory: ContainerLocator.stickiesDirectory(homeDirectory: homeDirectory),
            // Under Application Support rather than inside the container: a
            // scratch file that outlived a crash would otherwise sit in the
            // container forever, reported as an entry nothing recognises. It has
            // to be on the same volume for the atomic replace to work, and both
            // live under ~/Library.
            scratchRoot: ContainerLocator.applicationSupportDirectory(homeDirectory: homeDirectory)
                .appending(path: "Scratch", directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    /// Installs `notes`, deletes the packages named in `removing`, and merges
    /// both into `state`.
    ///
    /// A note in `notes` with no window state leaves whatever entry the
    /// container already had: the archive not carrying a position is not a
    /// statement that the note should lose the one it has.
    public func apply(
        notes: [StickyNote],
        removing: [StickyID],
        mergingInto state: SavedStickiesState
    ) throws {
        let scratch = try makeScratchDirectory()
        defer { try? fileManager.removeItem(at: scratch) }

        try fileManager.createDirectory(at: directory.root, withIntermediateDirectories: true)

        var merged = state
        for note in notes {
            try install(note, via: scratch)
            if let windowState = note.windowState {
                merged.upsert(windowState)
            }
        }

        for id in removing {
            try removePackage(id)
            merged.remove(id)
        }

        try writeState(merged, via: scratch)
    }

    private func install(_ note: StickyNote, via scratch: URL) throws {
        let staged = scratch.appending(path: note.id.packageFileName, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
            for (name, contents) in note.package.files {
                try contents.write(to: staged.appending(path: name, directoryHint: .notDirectory))
            }
            try replace(directory.packageURL(for: note.id), with: staged)
        } catch {
            throw WriteError.packageWriteFailed(id: note.id, underlying: error.localizedDescription)
        }
    }

    private func removePackage(_ id: StickyID) throws {
        let url = directory.packageURL(for: id)
        guard fileManager.fileExists(atPath: path(url)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw WriteError.packageWriteFailed(id: id, underlying: error.localizedDescription)
        }
    }

    private func writeState(_ state: SavedStickiesState, via scratch: URL) throws {
        do {
            let staged = scratch.appending(path: "SavedStickiesState", directoryHint: .notDirectory)
            try state.serialized().write(to: staged)
            try replace(directory.savedStateURL, with: staged)
        } catch {
            throw WriteError.stateWriteFailed(error.localizedDescription)
        }
    }

    /// `replaceItemAt` needs something to replace, so a first write is a move.
    /// Either way the destination goes from absent-or-old to new in one step.
    private func replace(_ destination: URL, with staged: URL) throws {
        if fileManager.fileExists(atPath: path(destination)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let scratch = scratchRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw WriteError.scratchUnavailable(error.localizedDescription)
        }
        return scratch
    }

    private func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
