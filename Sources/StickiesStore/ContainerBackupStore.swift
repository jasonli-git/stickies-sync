import Foundation

/// Copies of the Stickies container taken immediately before a write.
///
/// This is the safety net the whole write path rests on. Writing a directory
/// tree cannot be made atomic, so instead of trying, every write is preceded by
/// a full copy and any failure restores it — SPEC.md F5. Backups are cheap: a
/// container of notes is kilobytes.
public struct ContainerBackupStore {
    public struct Backup: Hashable, Sendable {
        public let url: URL
        public let name: String
    }

    public enum BackupError: Error, CustomStringConvertible {
        case restoreFailed(underlying: String)

        public var description: String {
            switch self {
            case .restoreFailed(let message):
                "could not restore the container from its backup: \(message)"
            }
        }
    }

    private let root: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    /// `now` is injected so a test gets deterministic backup names instead of
    /// whatever the clock says.
    public init(
        root: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = root
        self.fileManager = fileManager
        self.now = now
    }

    public static func forHome(
        _ homeDirectory: URL = ContainerLocator.currentHomeDirectory,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ContainerBackupStore {
        ContainerBackupStore(
            root: ContainerLocator.applicationSupportDirectory(homeDirectory: homeDirectory)
                .appending(path: "Backups", directoryHint: .isDirectory),
            fileManager: fileManager,
            now: now
        )
    }

    /// Copies the container wholesale. A name collision within the same second
    /// is resolved by suffixing, so two writes in quick succession cannot
    /// overwrite each other's safety net.
    public func makeBackup(of directory: URL) throws -> Backup {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let base = Self.nameFormatter.string(from: now())
        var name = base
        var destination = root.appending(path: name, directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            name = "\(base)-\(suffix)"
            destination = root.appending(path: name, directoryHint: .isDirectory)
            suffix += 1
        }

        try fileManager.copyItem(at: directory, to: destination)
        return Backup(url: destination, name: name)
    }

    /// Puts the container back exactly as the backup has it, including removing
    /// files the failed write had created. Replacing the directory rather than
    /// merging into it is what makes that true.
    public func restore(_ backup: Backup, to directory: URL) throws {
        do {
            if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.copyItem(at: backup.url, to: directory)
        } catch {
            throw BackupError.restoreFailed(underlying: error.localizedDescription)
        }
    }

    /// Newest first.
    public func backups() throws -> [Backup] {
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
            .map { Backup(url: root.appending(path: $0, directoryHint: .isDirectory), name: $0) }
    }

    /// Keeps the newest `count` backups and removes the rest. Names sort
    /// chronologically by construction, so no file dates are consulted — a
    /// restored or copied backup directory keeps its place in the order.
    @discardableResult
    public func prune(keeping count: Int) throws -> [Backup] {
        let removable = try backups().dropFirst(count)
        for backup in removable {
            try fileManager.removeItem(at: backup.url)
        }
        return Array(removable)
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Sorts chronologically as a string, which is what prune() relies on.
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
