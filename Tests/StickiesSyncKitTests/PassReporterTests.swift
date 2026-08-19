import Foundation
import StickiesFormat
import SyncEngine
import Testing

@testable import StickiesSyncKit

@Suite("Deciding what a pass says")
struct PassReporterTests {
    private func quiet() -> SyncOutcome { SyncOutcome() }

    private func warning(_ text: String) -> SyncOutcome {
        var outcome = SyncOutcome()
        outcome.warnings = [text]
        return outcome
    }

    private func adopted() throws -> SyncOutcome {
        var outcome = SyncOutcome()
        outcome.adopted = [try #require(StickyID(rawValue: "17"))]
        return outcome
    }

    @Test("A pass that changed nothing and warned about nothing is silent")
    func quietPassesAreSilent() {
        var reporter = PassReporter()

        // The property that makes a thirty-second agent tolerable at all.
        #expect(reporter.decide(quiet()).shouldReport == false)
        #expect(reporter.decide(quiet()).shouldReport == false)
    }

    @Test("A pass the user asked for always reports, even when it did nothing")
    func explicitPassesAlwaysReport() {
        var reporter = PassReporter()

        #expect(reporter.decide(quiet(), explicit: true).shouldReport)
    }

    @Test("A pass that adopted something reports")
    func changesReport() throws {
        var reporter = PassReporter()

        #expect(reporter.decide(try adopted()).shouldReport)
    }

    @Test("A pass that only warns still reports")
    func warningsAloneReport() {
        var reporter = PassReporter()

        // The bug this type exists for, twice over: a refused apply and an
        // unopenable peer both change nothing, so a "did it change anything"
        // rule left the log silent while a note never arrived.
        #expect(reporter.decide(warning("nothing applied: Stickies is frontmost")).shouldReport)
    }

    @Test("The same warning is not repeated on every pass")
    func persistentWarningsAreStatedOnce() {
        var reporter = PassReporter()
        let unpaired = warning("ignoring what 8C9EF3BF published — sealed under a different vault")

        #expect(reporter.decide(unpaired).shouldReport)
        // A Mac that is never paired would otherwise write this line twice a
        // minute, forever, burying everything worth reading.
        #expect(reporter.decide(unpaired).shouldReport == false)
        #expect(reporter.decide(unpaired).shouldReport == false)
    }

    @Test("A different warning is reported even though one was already standing")
    func newWarningsBreakThrough() {
        var reporter = PassReporter()

        #expect(reporter.decide(warning("first")).shouldReport)
        #expect(reporter.decide(warning("second")).shouldReport)
    }

    @Test("Warnings clearing is itself worth reporting")
    func recoveryIsReported() {
        var reporter = PassReporter()
        _ = reporter.decide(warning("cannot read note 17"))

        let decision = reporter.decide(quiet())

        // The last thing the log said was that something was wrong. Saying
        // nothing when it comes right leaves the reader believing it still is.
        #expect(decision.shouldReport)
        #expect(decision.warningsCleared)
        // And then it settles again.
        #expect(reporter.decide(quiet()).shouldReport == false)
    }

    @Test("A first pass with no warnings has nothing to clear")
    func nothingToClearAtTheStart() {
        var reporter = PassReporter()

        #expect(reporter.decide(quiet(), explicit: true).warningsCleared == false)
    }

    @Test("Comparison is against the last pass reported, not the last pass run")
    func comparesAgainstWhatWasSaid() throws {
        var reporter = PassReporter()
        let standing = warning("cannot read note 17")
        #expect(reporter.decide(standing).shouldReport)

        // A pass that adopts a note reports, and carries the same standing
        // warning with it — so the warning has now been said again, and must not
        // count as new on the pass after it.
        var both = try adopted()
        both.warnings = standing.warnings
        #expect(reporter.decide(both).shouldReport)
        #expect(reporter.decide(standing).shouldReport == false)
    }
}
