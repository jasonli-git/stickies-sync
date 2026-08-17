import CoreServices
import Foundation

/// Watches the Stickies container for changes and calls back when it settles.
///
/// FSEvents rather than a `DispatchSource` on the directory: a note's text lives
/// inside its `.rtfd` package, so a watch that saw only the container directory
/// would miss every edit. FSEvents watches a subtree.
///
/// The callback says *that* something changed, never what. Working out what
/// changed is `Replica.reconcile`'s job, and it needs the whole container
/// anyway, so carrying per-file event details would be effort spent on
/// information the next step throws away.
public final class ContainerWatcher: @unchecked Sendable {
    /// FSEvents' own latency, which is also the debounce. Events inside the
    /// window are coalesced into one callback, so holding down a key produces a
    /// callback every half second rather than one per keystroke.
    public static let defaultCoalescingWindow: TimeInterval = 0.5

    public enum WatchError: Error, CustomStringConvertible {
        case streamCreationFailed(path: String)

        public var description: String {
            switch self {
            case .streamCreationFailed(let path): "could not watch \(path) for changes"
            }
        }
    }

    private let directory: URL
    private let coalescingWindow: TimeInterval
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable () -> Void)?

    public init(
        directory: URL,
        coalescingWindow: TimeInterval = defaultCoalescingWindow,
        queue: DispatchQueue = DispatchQueue(label: "com.stickiessync.watcher")
    ) {
        self.directory = directory
        self.coalescingWindow = coalescingWindow
        self.queue = queue
    }

    public static func forHome(
        _ homeDirectory: URL = ContainerLocator.currentHomeDirectory,
        coalescingWindow: TimeInterval = defaultCoalescingWindow
    ) -> ContainerWatcher {
        ContainerWatcher(
            directory: ContainerLocator.stickiesDirectory(homeDirectory: homeDirectory).root,
            coalescingWindow: coalescingWindow
        )
    }

    deinit {
        stop()
    }

    /// Starts watching. `onChange` runs on this watcher's queue, one call at a
    /// time.
    public func start(onChange: @escaping @Sendable () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        handler = onChange

        // Unretained: the watcher owns the stream and tears it down in `stop`
        // and `deinit`, so the stream can never outlive the object it points at.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let path = directory.path(percentEncoded: false)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            containerWatcherCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            coalescingWindow,
            // WatchRoot so the container being replaced wholesale — which is
            // exactly what a rollback does — still registers.
            UInt32(kFSEventStreamCreateFlagWatchRoot)
        ) else {
            handler = nil
            throw WatchError.streamCreationFailed(path: path)
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        handler = nil
    }

    fileprivate func containerChanged() {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?()
    }
}

/// A C function pointer, so it cannot capture: the watcher arrives through the
/// stream context's `info` pointer.
private let containerWatcherCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<ContainerWatcher>.fromOpaque(info).takeUnretainedValue().containerChanged()
}
