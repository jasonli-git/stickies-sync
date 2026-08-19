import Foundation

/// One judged check. Presentation-free: the CLI renders these as text or JSON,
/// and the menu-bar app of Milestone 6 will render the same list as a problems
/// panel.
public struct Diagnostic: Equatable, Sendable {
    public enum Status: String, Sendable, Comparable {
        case ok
        case warning
        case failure

        private var severity: Int {
            switch self {
            case .ok: 0
            case .warning: 1
            case .failure: 2
            }
        }

        public static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.severity < rhs.severity
        }
    }

    public let name: String
    public let status: Status
    public let detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

extension ContainerReport {
    /// The worst status among the diagnostics — what a caller checks to decide
    /// whether this Mac is usable.
    public var overallStatus: Diagnostic.Status {
        diagnostics().map(\.status).max() ?? .ok
    }

    public func diagnostics() -> [Diagnostic] {
        [
            containerDiagnostic,
            noteDiagnostic,
            unrecognizedEntryDiagnostic,
            savedStateDiagnostic,
            stateAgreementDiagnostic,
            legacyDatabaseDiagnostic,
            runStateDiagnostic,
            applicationSupportDiagnostic,
        ]
    }

    private var containerDiagnostic: Diagnostic {
        let name = "Stickies container"
        switch access {
        case .readable:
            return Diagnostic(name: name, status: .ok, detail: directory.path(percentEncoded: false))
        case .missing:
            return Diagnostic(
                name: name,
                status: .failure,
                detail: "not found at \(directory.path(percentEncoded: false)) — has Stickies ever run on this Mac?"
            )
        case .notADirectory:
            return Diagnostic(
                name: name,
                status: .failure,
                detail: "\(directory.path(percentEncoded: false)) exists but is not a directory"
            )
        case .permissionDenied(let message):
            // Whether the container needs a TCC grant varies between Macs in a
            // way this project does not understand: one Mac reads it with no
            // Full Disk Access at all while another was denied until FDA was
            // granted. So this says what to do rather than claiming the denial is
            // surprising — an earlier version called it "unexpected, since the
            // container needs no special permission", which sent the reader
            // looking anywhere but at the grant.
            return Diagnostic(
                name: name,
                status: .failure,
                detail: "permission denied (\(message)) — grant Full Disk Access to whatever runs "
                    + "stickiesctl (the binary itself under launchd, or the terminal or app "
                    + "launching it), in System Settings ▸ Privacy & Security ▸ Full Disk Access"
            )
        case .failed(let message):
            return Diagnostic(name: name, status: .failure, detail: "unreadable: \(message)")
        }
    }

    private var noteDiagnostic: Diagnostic {
        guard access == .readable else {
            return Diagnostic(name: "Note packages", status: .warning, detail: "not counted — container unreadable")
        }
        if notes.isEmpty {
            return Diagnostic(name: "Note packages", status: .warning, detail: "none — there are no stickies to sync yet")
        }
        return Diagnostic(name: "Note packages", status: .ok, detail: "\(notes.count) found")
    }

    private var unrecognizedEntryDiagnostic: Diagnostic {
        let name = "Unrecognised entries"
        guard access == .readable else {
            return Diagnostic(name: name, status: .ok, detail: "not checked — container unreadable")
        }
        guard !unrecognizedEntries.isEmpty else {
            return Diagnostic(name: name, status: .ok, detail: "none")
        }
        // Not a failure: doctor's job is to describe the Mac. It is the sync
        // path that must refuse to run against a format it cannot account for
        // (SPEC.md F14).
        return Diagnostic(
            name: name,
            status: .warning,
            detail: "\(unrecognizedEntries.count) entry/entries this tool cannot classify: "
                + unrecognizedEntries.joined(separator: ", ")
        )
    }

    private var savedStateDiagnostic: Diagnostic {
        let name = "Saved window state"
        switch savedState {
        case .parsed(let count):
            return Diagnostic(name: name, status: .ok, detail: "parses as a plist array of \(count) entry/entries")
        case .missing:
            return Diagnostic(
                name: name,
                status: notes.isEmpty ? .ok : .warning,
                detail: notes.isEmpty
                    ? "absent, as expected with no notes"
                    : "absent despite \(notes.count) note(s) — window positions cannot be synced"
            )
        case .unexpectedRoot(let type):
            return Diagnostic(
                name: name,
                status: .failure,
                detail: "root is \(type), expected an array — the format may have changed"
            )
        case .unreadable(let message):
            return Diagnostic(name: name, status: .failure, detail: "unreadable: \(message)")
        }
    }

    /// One entry per note is the expected shape. A mismatch is the earliest
    /// signal that the state file is written on a different schedule from the
    /// note packages — the open question Milestone 1 has to settle.
    private var stateAgreementDiagnostic: Diagnostic {
        let name = "State/notes agreement"
        guard access == .readable, case .parsed(let stateCount) = savedState else {
            return Diagnostic(name: name, status: .ok, detail: "not checked")
        }
        guard stateCount != notes.count else {
            return Diagnostic(name: name, status: .ok, detail: "\(notes.count) note(s), \(stateCount) state entry/entries")
        }
        return Diagnostic(
            name: name,
            status: .warning,
            detail: "\(notes.count) note(s) but \(stateCount) state entry/entries — "
                + "state is stale, or is flushed only when Stickies quits"
        )
    }

    private var legacyDatabaseDiagnostic: Diagnostic {
        let name = "Legacy Stickies database"
        guard legacyDatabasePresent else {
            return Diagnostic(name: name, status: .ok, detail: "not present")
        }
        return Diagnostic(
            name: name,
            status: .warning,
            detail: "~/Library/StickiesDatabase exists — pre-sandbox notes may not have been migrated, "
                + "and this tool does not read that format"
        )
    }

    private var runStateDiagnostic: Diagnostic {
        let name = "Stickies process"
        switch runState {
        case .notRunning:
            return Diagnostic(name: name, status: .ok, detail: "not running — reads and writes are both safe")
        case .running(frontmost: false):
            return Diagnostic(
                name: name,
                status: .ok,
                detail: "running in the background — reads are safe; a write must quit and relaunch it"
            )
        case .running(frontmost: true):
            return Diagnostic(
                name: name,
                status: .warning,
                detail: "running and frontmost — the user is likely typing, so writes must wait"
            )
        }
    }

    private var applicationSupportDiagnostic: Diagnostic {
        let name = "StickiesSync state directory"
        let path = applicationSupportDirectory.path(percentEncoded: false)
        return applicationSupportWritable
            ? Diagnostic(name: name, status: .ok, detail: "writable at \(path)")
            : Diagnostic(name: name, status: .failure, detail: "not writable at \(path)")
    }
}
