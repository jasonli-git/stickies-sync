import Foundation
import StickiesFormat

/// Observable facts about one Mac's Stickies data. Facts only — the
/// interpretation of whether each one is good or bad lives in
/// `ContainerReport.diagnostics()`, so a future menu-bar app and the CLI agree
/// on what a healthy Mac looks like.
public struct ContainerReport: Equatable, Sendable {
    public enum Access: Equatable, Sendable {
        case readable
        case missing
        case notADirectory
        /// Almost always TCC: reading another application's container requires
        /// Full Disk Access, which this process has not been granted.
        case permissionDenied(String)
        case failed(String)
    }

    /// How far `.SavedStickiesState` could be understood. Doctor only checks
    /// the file's outermost shape; parsing the per-note entries is Milestone 1.
    public enum SavedState: Equatable, Sendable {
        case missing
        case parsed(topLevelEntryCount: Int)
        /// Readable and valid plist, but not the array of per-note dictionaries
        /// the format is supposed to be — a signal the format has changed.
        case unexpectedRoot(String)
        case unreadable(String)
    }

    public let directory: URL
    public let access: Access
    public let notes: [StickyID]
    public let unrecognizedEntries: [String]
    public let savedState: SavedState
    public let legacyDatabasePresent: Bool
    public let applicationSupportDirectory: URL
    public let applicationSupportWritable: Bool
    public let runState: StickiesRunState

    public init(
        directory: URL,
        access: Access,
        notes: [StickyID],
        unrecognizedEntries: [String],
        savedState: SavedState,
        legacyDatabasePresent: Bool,
        applicationSupportDirectory: URL,
        applicationSupportWritable: Bool,
        runState: StickiesRunState
    ) {
        self.directory = directory
        self.access = access
        self.notes = notes
        self.unrecognizedEntries = unrecognizedEntries
        self.savedState = savedState
        self.legacyDatabasePresent = legacyDatabasePresent
        self.applicationSupportDirectory = applicationSupportDirectory
        self.applicationSupportWritable = applicationSupportWritable
        self.runState = runState
    }
}

/// Reads the facts in `ContainerReport` off a real directory.
public struct ContainerProbe {
    private let directory: StickiesDirectory
    private let legacyDatabaseURL: URL
    private let applicationSupportDirectory: URL
    private let fileManager: FileManager
    private let observeRunState: @Sendable () -> StickiesRunState

    public init(
        directory: StickiesDirectory,
        legacyDatabaseURL: URL,
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        observeRunState: @escaping @Sendable () -> StickiesRunState = StickiesApp.runState
    ) {
        self.directory = directory
        self.legacyDatabaseURL = legacyDatabaseURL
        self.applicationSupportDirectory = applicationSupportDirectory
        self.fileManager = fileManager
        self.observeRunState = observeRunState
    }

    /// The probe as configured for a real Mac. `homeDirectory` is a parameter
    /// so a test can assemble a whole synthetic home and probe that instead.
    public static func forHome(
        _ homeDirectory: URL = ContainerLocator.currentHomeDirectory,
        fileManager: FileManager = .default,
        observeRunState: @escaping @Sendable () -> StickiesRunState = StickiesApp.runState
    ) -> ContainerProbe {
        ContainerProbe(
            directory: ContainerLocator.stickiesDirectory(homeDirectory: homeDirectory),
            legacyDatabaseURL: ContainerLocator.legacyDatabaseURL(homeDirectory: homeDirectory),
            applicationSupportDirectory: ContainerLocator.applicationSupportDirectory(homeDirectory: homeDirectory),
            fileManager: fileManager,
            observeRunState: observeRunState
        )
    }

    /// Never throws: an unreadable container is a fact to report, not an error
    /// to propagate. Doctor's job is to describe a broken Mac, not to fail on
    /// one.
    public func run() -> ContainerReport {
        let (access, contents) = listContainer()

        return ContainerReport(
            directory: directory.root,
            access: access,
            notes: contents?.notes ?? [],
            unrecognizedEntries: contents?.unrecognized ?? [],
            savedState: readSavedState(expectedPresent: contents?.hasSavedState ?? false),
            legacyDatabasePresent: fileManager.fileExists(atPath: path(legacyDatabaseURL)),
            applicationSupportDirectory: applicationSupportDirectory,
            applicationSupportWritable: isWritable(applicationSupportDirectory),
            runState: observeRunState()
        )
    }

    private func listContainer() -> (ContainerReport.Access, StickiesDirectory.Contents?) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path(directory.root), isDirectory: &isDirectory) else {
            return (.missing, nil)
        }
        guard isDirectory.boolValue else {
            return (.notADirectory, nil)
        }

        do {
            // `contentsOfDirectory(atPath:)` rather than the URL variant: the
            // URL form resolves each entry, which would descend into every
            // .rtfd package for no benefit here.
            let names = try fileManager.contentsOfDirectory(atPath: path(directory.root))
            return (.readable, directory.classify(entryNames: names))
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return (.permissionDenied(error.localizedDescription), nil)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    private func readSavedState(expectedPresent: Bool) -> ContainerReport.SavedState {
        guard expectedPresent || fileManager.fileExists(atPath: path(directory.savedStateURL)) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: directory.savedStateURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let entries = plist as? [Any] else {
                return .unexpectedRoot(String(describing: type(of: plist)))
            }
            return .parsed(topLevelEntryCount: entries.count)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// A directory we have yet to create is fine as long as some ancestor
    /// exists and will take it — the whole chain gets created with
    /// `withIntermediateDirectories`, so the nearest existing ancestor is the
    /// one that decides.
    private func isWritable(_ url: URL) -> Bool {
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: path(candidate)) {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent != candidate else { return false }
            candidate = parent
        }
        return fileManager.isWritableFile(atPath: path(candidate))
    }

    private func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
