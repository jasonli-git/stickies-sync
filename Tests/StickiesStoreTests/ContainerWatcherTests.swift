import Foundation
import Testing

@testable import StickiesStore

/// FSEvents is a real system service with real latency, so these tests wait on
/// a semaphore with a generous deadline rather than sleeping a fixed amount.
/// They are the only timing-dependent tests in the suite.
@Suite("ContainerWatcher")
struct ContainerWatcherTests {
    /// Long enough that a loaded machine does not fail the test, short enough
    /// that a genuine breakage does not hang the suite.
    private static let deadline: TimeInterval = 10

    @Test("Fires when a note package is written inside the container")
    func firesOnAChangeInsideAPackage() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")

            let fired = DispatchSemaphore(value: 0)
            let watcher = ContainerWatcher(
                directory: home.stickiesDirectory.root,
                coalescingWindow: 0.1
            )
            try watcher.start { fired.signal() }
            defer { watcher.stop() }

            // A note's text lives inside its .rtfd package, so this is the case
            // a directory-only watch would miss entirely.
            try home.addNote("17", richText: Data("edited".utf8))

            #expect(fired.wait(timeout: .now() + Self.deadline) == .success)
        }
    }

    @Test("Fires when a note is added to the container")
    func firesOnANewNote() throws {
        try SyntheticHome.run { home in
            try home.createContainer()

            let fired = DispatchSemaphore(value: 0)
            let watcher = ContainerWatcher(
                directory: home.stickiesDirectory.root,
                coalescingWindow: 0.1
            )
            try watcher.start { fired.signal() }
            defer { watcher.stop() }

            try home.addNote("18")

            #expect(fired.wait(timeout: .now() + Self.deadline) == .success)
        }
    }

    @Test("Stops calling back once stopped")
    func stopsCleanly() throws {
        try SyntheticHome.run { home in
            try home.createContainer()

            let counter = CallCounter()
            let watcher = ContainerWatcher(
                directory: home.stickiesDirectory.root,
                coalescingWindow: 0.1
            )
            try watcher.start { counter.record() }
            watcher.stop()

            try home.addNote("19")
            Thread.sleep(forTimeInterval: 1)

            #expect(counter.count == 0)
        }
    }

    @Test("Starting twice is harmless")
    func startingTwiceIsIdempotent() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let watcher = ContainerWatcher(directory: home.stickiesDirectory.root)

            try watcher.start {}
            try watcher.start {}
            watcher.stop()
        }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.withLock { calls += 1 }
    }

    var count: Int {
        lock.withLock { calls }
    }
}
