import Foundation
import StickiesFormat

/// Everything one read of a container found, including what it could not make
/// sense of. Nothing here is discarded silently — the awkward cases each have a
/// field, because a note this tool cannot read is a note it must not later
/// pretend to have synced.
public struct StickiesSnapshot: Hashable, Sendable {
    public struct UnreadableNote: Hashable, Sendable {
        public let id: StickyID
        public let reason: String
    }

    /// Notes with a readable package, sorted by identifier.
    public var notes: [StickyNote]
    /// Window state for identifiers with no package on disk.
    public var stateWithoutPackage: [StickyWindowState]
    /// Packages that exist but could not be read or did not validate.
    public var unreadableNotes: [UnreadableNote]
    /// Directory entries that are neither a note package nor the state file.
    public var unrecognizedEntries: [String]
    /// The state document as read, entry order and unparseable entries intact.
    /// The writer merges against this rather than re-reading the file, so what
    /// was validated is what gets written back.
    public var savedState: SavedStickiesState

    /// Reasons individual `.SavedStickiesState` entries could not be parsed.
    public var unreadableStateEntries: [String] { savedState.unreadableReasons }

    /// True when the whole container was understood — the precondition
    /// SPEC.md F14 requires before anything is written anywhere.
    public var isFullyUnderstood: Bool {
        unreadableNotes.isEmpty && unreadableStateEntries.isEmpty && unrecognizedEntries.isEmpty
    }

    /// True when some note or state entry could not be read at all — data a
    /// sync would silently drop, and so a reason to fail a command rather than
    /// merely warn. An entry that is only *unrecognised* does not count.
    public var hasUnreadableData: Bool {
        !unreadableNotes.isEmpty || !unreadableStateEntries.isEmpty
    }

    /// Notes whose package was read but which have no window state, so position
    /// and colour cannot be replicated for them.
    public var notesWithoutState: [StickyNote] {
        notes.filter { $0.windowState == nil }
    }

    /// Packages that are on disk but were not read, as identifiers.
    ///
    /// Every caller that reconciles has to hand these to the replica: they are
    /// missing from `notes`, and a note missing from `notes` is otherwise taken
    /// for a deleted one and published as a tombstone.
    public var unreadableNoteIDs: Set<StickyID> {
        Set(unreadableNotes.map(\.id))
    }
}

/// Reads a Stickies container into a `StickiesSnapshot`. Read-only: nothing in
/// this type writes.
public struct StickiesReader {
    /// Finder metadata, machine-local by definition and never part of an RTFD
    /// document. Excluded so it is not replicated to other Macs; every other
    /// file in a package is carried verbatim.
    private static let excludedPackageEntries: Set<String> = [".DS_Store"]

    private let directory: StickiesDirectory
    private let fileManager: FileManager

    public init(directory: StickiesDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public static func forHome(
        _ homeDirectory: URL = ContainerLocator.currentHomeDirectory,
        fileManager: FileManager = .default
    ) -> StickiesReader {
        StickiesReader(
            directory: ContainerLocator.stickiesDirectory(homeDirectory: homeDirectory),
            fileManager: fileManager
        )
    }

    /// Throws only when the container or the state file cannot be read *as a
    /// whole* — a failure the caller cannot work around. Per-note failures are
    /// collected into the snapshot instead, so one broken note does not hide the
    /// other forty.
    public func read() throws -> StickiesSnapshot {
        let contents = directory.classify(
            entryNames: try fileManager.contentsOfDirectory(atPath: path(directory.root))
        )
        let state = try readState(expected: contents.hasSavedState)

        var notes: [StickyNote] = []
        var unreadable: [StickiesSnapshot.UnreadableNote] = []

        for id in contents.notes {
            do {
                notes.append(
                    StickyNote(id: id, package: try readPackage(id), windowState: state[id])
                )
            } catch {
                unreadable.append(.init(id: id, reason: String(describing: error)))
            }
        }

        let present = Set(contents.notes)
        return StickiesSnapshot(
            notes: notes,
            stateWithoutPackage: state.notes.filter { !present.contains($0.id) },
            unreadableNotes: unreadable,
            unrecognizedEntries: contents.unrecognized,
            savedState: state
        )
    }

    /// A container with no state file is a normal empty container, not an error:
    /// Stickies only writes the file once it has a note.
    private func readState(expected: Bool) throws -> SavedStickiesState {
        guard expected else { return SavedStickiesState() }
        return try SavedStickiesState(data: try Data(contentsOf: directory.savedStateURL))
    }

    private func readPackage(_ id: StickyID) throws -> NotePackage {
        let packageURL = directory.packageURL(for: id)
        var files: [String: Data] = [:]

        for name in try fileManager.contentsOfDirectory(atPath: path(packageURL)) {
            guard !Self.excludedPackageEntries.contains(name) else { continue }

            let entryURL = packageURL.appending(path: name, directoryHint: .notDirectory)
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: path(entryURL), isDirectory: &isDirectory)

            // A nested entry is flagged by giving NotePackage a name it rejects,
            // keeping the structural rule in one place.
            files[isDirectory.boolValue ? "\(name)/" : name] =
                isDirectory.boolValue ? Data() : try Data(contentsOf: entryURL)
        }

        return try NotePackage(files: files)
    }

    private func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
