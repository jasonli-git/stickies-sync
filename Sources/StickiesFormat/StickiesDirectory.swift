import Foundation

public enum StickiesFileNames {
    /// Extension of the RTFD package holding one note's text and attachments.
    public static let packageExtension = "rtfd"

    /// Sibling plist holding per-note window state, keyed by ``StickyID``.
    public static let savedStateFileName = ".SavedStickiesState"
}

/// Path arithmetic over a directory of Stickies notes.
///
/// Deliberately performs no I/O: tests point it at a fixture directory and
/// production points it at the real container, and neither case needs a
/// protocol to stand in for the filesystem. `ContainerLocator` in
/// `StickiesStore` supplies the real root.
public struct StickiesDirectory: Hashable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var savedStateURL: URL {
        root.appending(path: StickiesFileNames.savedStateFileName, directoryHint: .notDirectory)
    }

    public func packageURL(for id: StickyID) -> URL {
        root.appending(path: id.packageFileName, directoryHint: .isDirectory)
    }

    /// What a directory listing turned out to contain.
    ///
    /// `unrecognized` exists because an entry we cannot classify means our
    /// model of the format is incomplete. SPEC.md F14 requires surfacing that
    /// rather than quietly skipping it, so nothing here silently discards.
    public struct Contents: Equatable, Sendable {
        public var notes: [StickyID]
        public var hasSavedState: Bool
        public var unrecognized: [String]
    }

    /// Partitions directory entry names. `notes` and `unrecognized` come back
    /// sorted, so callers and tests see a stable order regardless of the order
    /// the filesystem enumerated them in.
    public func classify(entryNames: some Sequence<String>) -> Contents {
        var notes: [StickyID] = []
        var hasSavedState = false
        var unrecognized: [String] = []

        for name in entryNames {
            if name == StickiesFileNames.savedStateFileName {
                hasSavedState = true
            } else if let id = StickyID(packageFileName: name) {
                notes.append(id)
            } else {
                unrecognized.append(name)
            }
        }

        return Contents(notes: notes.sorted(), hasSavedState: hasSavedState, unrecognized: unrecognized.sorted())
    }
}
