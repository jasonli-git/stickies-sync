import Foundation

@testable import StickiesStore

/// Stands in for the Stickies application so tests of the write path do not
/// close the developer's own notes and reopen their windows.
final class FakeProcessControl: StickiesProcessControlling, @unchecked Sendable {
    private let lock = NSLock()

    private var state: StickiesRunState
    /// When true, `quit` reports failure and leaves the app running — a note
    /// with unsaved changes and a sheet up behaves this way.
    private let refusesToQuit: Bool
    private let launchError: (any Error)?

    private(set) var quitCallCount = 0
    private(set) var launchCallCount = 0

    init(
        state: StickiesRunState = .notRunning,
        refusesToQuit: Bool = false,
        launchError: (any Error)? = nil
    ) {
        self.state = state
        self.refusesToQuit = refusesToQuit
        self.launchError = launchError
    }

    func runState() -> StickiesRunState {
        lock.withLock { state }
    }

    func quit(within timeout: TimeInterval) -> Bool {
        lock.withLock {
            quitCallCount += 1
            guard !refusesToQuit else { return false }
            state = .notRunning
            return true
        }
    }

    func launch() throws {
        try lock.withLock {
            launchCallCount += 1
            if let launchError { throw launchError }
            state = .running(frontmost: false)
        }
    }
}

struct FakeLaunchError: Error, CustomStringConvertible {
    let description = "Stickies could not be launched"
}
