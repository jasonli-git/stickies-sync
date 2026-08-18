import Foundation
import StickiesFormat
import StickiesStore

/// Settings that outlive a single command, so the background agent can run with
/// no arguments and the user configures the sync folder once.
public struct SyncConfiguration: Hashable, Sendable {
    public var syncFolder: URL?

    public init(syncFolder: URL? = nil) {
        self.syncFolder = syncFolder
    }

    public static func url(home: URL = ContainerLocator.currentHomeDirectory) -> URL {
        ContainerLocator.applicationSupportDirectory(homeDirectory: home)
            .appending(path: "config.plist", directoryHint: .notDirectory)
    }

    /// A missing or unreadable configuration reads as an empty one. There is
    /// nothing here a user cannot re-enter in one command, so failing the whole
    /// program over it would be worse than starting fresh.
    public static func load(home: URL = ContainerLocator.currentHomeDirectory) -> SyncConfiguration {
        guard let data = try? Data(contentsOf: url(home: home)),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = try? PlistValue(propertyList: object),
              let entry = plist.dictionaryValue
        else {
            return SyncConfiguration()
        }
        return SyncConfiguration(
            syncFolder: entry["SyncFolder"]?.stringValue.map {
                URL(filePath: $0, directoryHint: .isDirectory)
            }
        )
    }

    public func save(home: URL = ContainerLocator.currentHomeDirectory) throws {
        var entry: [String: PlistValue] = [:]
        entry["SyncFolder"] = syncFolder.map { .string($0.path(percentEncoded: false)) }

        let destination = Self.url(home: home)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization
            .data(fromPropertyList: PlistValue.dictionary(entry).propertyList, format: .xml, options: 0)
            .write(to: destination, options: .atomic)
    }
}
