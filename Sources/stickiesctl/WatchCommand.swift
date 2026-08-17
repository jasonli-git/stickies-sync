import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore
import SyncEngine

struct WatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch the container and report note-level changes as they happen.",
        discussion: """
            Scans once at startup, then again whenever the container settles \
            after a change. Runs until interrupted with Ctrl-C. Nothing is \
            written to Stickies — this only observes.
            """
    )

    @OptionGroup var container: ContainerOptions

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Seconds to let changes settle before scanning.",
            valueName: "seconds"
        )
    )
    var settle: Double = ContainerWatcher.defaultCoalescingWindow

    func run() throws {
        // stdout is block-buffered when it is not a terminal, so a redirected or
        // piped watch would show nothing until the buffer filled — and would
        // lose it entirely on Ctrl-C. Line buffering makes each report appear as
        // it happens, which is the only reason to run this command at all.
        setvbuf(stdout, nil, _IOLBF, 0)

        let replica = try container.openReplica()
        let options = container

        print("Watching \(ContainerLocator.stickiesDirectory(homeDirectory: options.home).root.path(percentEncoded: false))")
        print("Device \(replica.deviceName) (\(replica.deviceID)). Ctrl-C to stop.\n")

        // FSEvents delivers on the watcher's own serial queue, so scans are
        // already one at a time; the replica needs no locking of its own.
        let scan = ScanRunner(options: options, replica: replica)
        scan.run(label: "initial scan")

        let watcher = ContainerWatcher.forHome(options.home, coalescingWindow: settle)
        try watcher.start { scan.run(label: nil) }
        defer { watcher.stop() }

        RunLoop.main.run()
    }
}

/// Holds the replica across callbacks. A class because the FSEvents handler is
/// `@Sendable` and outlives the call to `run()`.
private final class ScanRunner: @unchecked Sendable {
    private let options: ContainerOptions
    private let replica: Replica

    init(options: ContainerOptions, replica: Replica) {
        self.options = options
        self.replica = replica
    }

    /// Never throws out to the watcher: a container that is briefly unreadable —
    /// mid-write by Stickies, or being restored from a backup — must not kill a
    /// long-running watch.
    func run(label: String?) {
        do {
            let (changes, snapshot) = try options.reconcile(replica)
            guard !changes.isEmpty || label != nil else { return }

            if let label { print("[\(label)]") }
            print(ScanCommand.render(changes, deviceName: replica.deviceName))
            for line in snapshot.problemLines {
                printError(line)
            }
        } catch {
            printError("scan failed, still watching: \(error)")
        }
    }
}
