import Foundation
import StickiesFormat

@testable import StickiesStore

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// A throwaway home directory laid out like a real Mac's.
///
/// The probe reads a real filesystem rather than an abstraction over one, so
/// tests give it a real filesystem — just not the user's. Every path comes from
/// `ContainerLocator`, so a change to the container layout is exercised here
/// rather than duplicated in the tests.
struct SyntheticHome {
    let root: URL
    private let fileManager = FileManager.default

    /// Creates a home, runs the body, and removes the home afterwards.
    static func run(_ body: (SyntheticHome) throws -> Void) throws {
        let root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "StickiesSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SyntheticHome(root: root))
    }

    var stickiesDirectory: StickiesDirectory {
        ContainerLocator.stickiesDirectory(homeDirectory: root)
    }

    func createContainer() throws {
        try fileManager.createDirectory(at: stickiesDirectory.root, withIntermediateDirectories: true)
    }

    /// Note packages are directories on disk. Their contents are Milestone 1's
    /// concern, so an empty package is enough to be counted here.
    @discardableResult
    func addNote(_ rawIdentifier: String) throws -> StickyID {
        guard let id = StickyID(rawValue: rawIdentifier) else {
            throw FixtureError(description: "\(rawIdentifier) is not a usable sticky identifier")
        }
        try fileManager.createDirectory(at: stickiesDirectory.packageURL(for: id), withIntermediateDirectories: true)
        return id
    }

    func addDirectoryEntry(named name: String) throws {
        try fileManager.createDirectory(
            at: stickiesDirectory.root.appending(path: name, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func writeSavedState(entryCount: Int) throws {
        try writeSavedState(propertyList: Array(repeating: [String: Any](), count: entryCount))
    }

    func writeSavedState(propertyList: Any) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: stickiesDirectory.savedStateURL)
    }

    func writeRawSavedState(_ bytes: Data) throws {
        try bytes.write(to: stickiesDirectory.savedStateURL)
    }

    func createLegacyDatabase() throws {
        let url = ContainerLocator.legacyDatabaseURL(homeDirectory: root)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func probe(runState: StickiesRunState = .notRunning) -> ContainerProbe {
        ContainerProbe.forHome(root, observeRunState: { runState })
    }
}
