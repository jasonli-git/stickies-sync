import AppKit

/// Control over the Stickies application itself.
///
/// A protocol because the write path cannot be tested any other way: every test
/// of the quit/relaunch rules would otherwise close the developer's own notes
/// and reopen their windows. The real implementation is the only production
/// conformance; `FakeProcessControl` in the tests is the other.
public protocol StickiesProcessControlling: Sendable {
    func runState() -> StickiesRunState

    /// Asks Stickies to quit and waits for it to go. Returns `false` if it is
    /// still running when `timeout` expires — a note with unsaved changes and a
    /// modal sheet up will do that.
    func quit(within timeout: TimeInterval) -> Bool

    /// Launches Stickies without bringing it to the front.
    func launch() throws
}

public struct StickiesProcessControl: StickiesProcessControlling {
    public enum LaunchError: Error, CustomStringConvertible {
        case applicationNotFound
        case launchFailed(String)

        public var description: String {
            switch self {
            case .applicationNotFound:
                "no application with bundle identifier \(ContainerLocator.stickiesBundleIdentifier)"
            case .launchFailed(let message):
                "could not launch Stickies: \(message)"
            }
        }
    }

    /// How often to check whether Stickies has finished quitting. Short enough
    /// that a quick quit is not padded out, long enough not to spin.
    private let pollInterval: TimeInterval

    public init(pollInterval: TimeInterval = 0.05) {
        self.pollInterval = pollInterval
    }

    public func runState() -> StickiesRunState {
        StickiesApp.runState()
    }

    /// `terminate()` sends the same quit Apple Event the Quit menu item does, so
    /// Stickies autosaves on the way out. That matters: the notes on disk are
    /// only current *after* it has gone.
    public func quit(within timeout: TimeInterval) -> Bool {
        let instances = runningInstances()
        guard !instances.isEmpty else { return true }

        for instance in instances {
            _ = instance.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningInstances().isEmpty { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return runningInstances().isEmpty
    }

    public func launch() throws {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ContainerLocator.stickiesBundleIdentifier
        ) else {
            throw LaunchError.applicationNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // The user was not looking at Stickies when we quit it — putting its
        // windows in front now would be a worse interruption than the blink.
        configuration.activates = false

        // `openApplication` is asynchronous and this API is not, so the launch
        // is awaited on a semaphore.
        let outcome = LaunchOutcome()
        let finished = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            outcome.record(error)
            finished.signal()
        }
        finished.wait()

        if let error = outcome.recorded() {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
    }

    /// Carries the completion handler's result back across the semaphore. The
    /// signal and wait already establish the ordering; the lock is what makes
    /// that legible to the compiler.
    private final class LaunchOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?

        func record(_ error: (any Error)?) {
            lock.withLock { self.error = error }
        }

        func recorded() -> (any Error)? {
            lock.withLock { error }
        }
    }

    private func runningInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: ContainerLocator.stickiesBundleIdentifier
        )
    }
}
