import AppKit

/// Whether the Stickies application is currently holding the notes open.
///
/// This drives the write path: Stickies keeps every note open as an autosaving
/// `NSDocument` and never reloads from disk, so anything written while it runs
/// is overwritten by its next autosave. `frontmost` narrows that further — a
/// frontmost Stickies means the user is probably typing, and quitting it out
/// from under them is not acceptable (see the user-experience section of
/// SPEC.md).
public enum StickiesRunState: Equatable, Sendable {
    case notRunning
    case running(frontmost: Bool)

    public var isRunning: Bool {
        self != .notRunning
    }
}

public enum StickiesApp {
    /// Observes the running application list. Returns `.notRunning` rather than
    /// failing when there is no window server to ask (an SSH session, say), so
    /// callers on a headless Mac degrade to "safe to write" rather than
    /// erroring — the same answer they would get from a Mac with Stickies quit.
    public static func runState() -> StickiesRunState {
        let instances = NSRunningApplication.runningApplications(
            withBundleIdentifier: ContainerLocator.stickiesBundleIdentifier
        )
        guard !instances.isEmpty else { return .notRunning }

        let frontmostIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return .running(frontmost: frontmostIdentifier == ContainerLocator.stickiesBundleIdentifier)
    }
}
