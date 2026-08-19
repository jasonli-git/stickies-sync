import Foundation
import SyncEngine

/// Decides whether a finished sync pass is worth telling anyone about.
///
/// A background agent runs a pass every thirty seconds forever, so most of them
/// have to be silent or the log is worthless. The tempting rule — "report a pass
/// that changed something" — is the one that has now failed twice: a pass whose
/// apply was refused, or that found a peer it could not open, changes nothing and
/// so said nothing, and the note simply never arrived with no explanation
/// anywhere.
///
/// The rule here is that a pass is worth reporting when it says something the
/// last reported pass did not. A warning that persists is stated once, at onset,
/// and again when it clears — never every thirty seconds.
///
/// It lives here rather than in the CLI for the reason #8 gives: the judgement
/// has to be the same in the agent's log and in the Milestone 6 menu bar app,
/// and keeping it in one place is what stops each from inventing its own.
public struct PassReporter: Sendable {
    public struct Decision: Equatable, Sendable {
        /// Whether to surface this pass at all.
        public let shouldReport: Bool
        /// Whether warnings that had been reported are now gone — worth saying
        /// out loud, because the last thing the log said was that something was
        /// wrong.
        public let warningsCleared: Bool
    }

    /// The warnings carried by the last pass that was reported.
    private var reported: [String] = []

    public init() {}

    /// `explicit` marks a pass the user asked for by name — an initial pass, or a
    /// one-shot `sync`. Those always report, because somebody is waiting to read
    /// the answer.
    public mutating func decide(_ outcome: SyncOutcome, explicit: Bool = false) -> Decision {
        let changed = outcome.warnings != reported
        let cleared = changed && outcome.warnings.isEmpty && !reported.isEmpty

        // Recorded whenever the pass is reported, so the next comparison is
        // against what was actually last said rather than against the last pass
        // that happened to run.
        if explicit || outcome.didAnything || changed {
            reported = outcome.warnings
            return Decision(shouldReport: true, warningsCleared: cleared)
        }
        return Decision(shouldReport: false, warningsCleared: false)
    }
}
