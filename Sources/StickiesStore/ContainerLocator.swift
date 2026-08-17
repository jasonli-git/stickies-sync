import Foundation
import StickiesFormat

/// Where things live on a real Mac.
///
/// Every path is derived from a home directory passed in, so a test can build
/// the whole layout under a temporary directory without touching the user's
/// notes.
public enum ContainerLocator {
    public static let stickiesBundleIdentifier = "com.apple.Stickies"

    public static var currentHomeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Stickies is sandboxed, so notes live inside its container rather than at
    /// the pre-sandbox `~/Library/Stickies`. Reading another application's
    /// container is what makes Full Disk Access a hard requirement.
    public static func stickiesDirectory(homeDirectory: URL = currentHomeDirectory) -> StickiesDirectory {
        StickiesDirectory(
            root: homeDirectory.appending(
                path: "Library/Containers/\(stickiesBundleIdentifier)/Data/Library/Stickies",
                directoryHint: .isDirectory
            )
        )
    }

    /// Pre-sandbox note store. Still present on a Mac whose notes were never
    /// migrated, in which case the container above will be empty and the user's
    /// real notes are here instead.
    public static func legacyDatabaseURL(homeDirectory: URL = currentHomeDirectory) -> URL {
        homeDirectory.appending(path: "Library/StickiesDatabase", directoryHint: .notDirectory)
    }

    /// Where StickiesSync keeps its own state — the replica database from
    /// Milestone 3 and the container backups from Milestone 2.
    public static func applicationSupportDirectory(homeDirectory: URL = currentHomeDirectory) -> URL {
        homeDirectory.appending(path: "Library/Application Support/StickiesSync", directoryHint: .isDirectory)
    }
}
