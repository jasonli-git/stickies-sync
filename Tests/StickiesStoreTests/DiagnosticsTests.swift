import Foundation
import StickiesFormat
import Testing

@testable import StickiesStore

@Suite("Diagnostics")
struct DiagnosticsTests {
    /// A healthy Mac, which each test then breaks in exactly one way.
    private func report(
        access: ContainerReport.Access = .readable,
        notes: [String] = ["1"],
        unrecognizedEntries: [String] = [],
        savedState: ContainerReport.SavedState = .parsed(topLevelEntryCount: 1),
        legacyDatabasePresent: Bool = false,
        applicationSupportWritable: Bool = true,
        runState: StickiesRunState = .notRunning
    ) -> ContainerReport {
        ContainerReport(
            directory: URL(filePath: "/tmp/Stickies", directoryHint: .isDirectory),
            access: access,
            notes: notes.compactMap(StickyID.init(rawValue:)),
            unrecognizedEntries: unrecognizedEntries,
            savedState: savedState,
            legacyDatabasePresent: legacyDatabasePresent,
            applicationSupportDirectory: URL(filePath: "/tmp/StickiesSync", directoryHint: .isDirectory),
            applicationSupportWritable: applicationSupportWritable,
            runState: runState
        )
    }

    @Test("A healthy Mac produces no warnings and no failures")
    func healthyMacIsOK() {
        let diagnostics = report().diagnostics()
        #expect(diagnostics.allSatisfy { $0.status == .ok })
        #expect(report().overallStatus == .ok)
    }

    @Test("Denied access names Full Disk Access as the fix")
    func permissionDeniedNamesTheFix() throws {
        let report = report(access: .permissionDenied("Operation not permitted"))
        let diagnostic = try #require(report.diagnostic(named: "Stickies container"))

        #expect(diagnostic.status == .failure)
        #expect(diagnostic.detail.contains("Full Disk Access"))
        #expect(report.overallStatus == .failure)
    }

    @Test("A background Stickies is fine; a frontmost one is a reason to wait")
    func runStateDrivesTheWriteAdvice() throws {
        #expect(report(runState: .notRunning).diagnostic(named: "Stickies process")?.status == .ok)
        #expect(report(runState: .running(frontmost: false)).diagnostic(named: "Stickies process")?.status == .ok)

        let frontmost = try #require(report(runState: .running(frontmost: true)).diagnostic(named: "Stickies process"))
        #expect(frontmost.status == .warning)
        #expect(report(runState: .running(frontmost: true)).overallStatus == .warning)
    }

    @Test("A missing state file is expected with no notes and a problem with them")
    func missingStateDependsOnWhetherNotesExist() {
        #expect(report(notes: [], savedState: .missing).diagnostic(named: "Saved window state")?.status == .ok)
        #expect(report(notes: ["1"], savedState: .missing).diagnostic(named: "Saved window state")?.status == .warning)
    }

    @Test("An unwritable state directory fails, since nothing can be backed up without it")
    func unwritableStateDirectoryFails() {
        let report = report(applicationSupportWritable: false)
        #expect(report.diagnostic(named: "StickiesSync state directory")?.status == .failure)
        #expect(report.overallStatus == .failure)
    }

    @Test("Warnings alone never escalate to a failure")
    func warningsDoNotFail() {
        let report = report(
            notes: [],
            unrecognizedEntries: ["Backups"],
            savedState: .parsed(topLevelEntryCount: 3),
            legacyDatabasePresent: true,
            runState: .running(frontmost: true)
        )
        #expect(report.diagnostics().contains { $0.status == .warning })
        #expect(report.overallStatus == .warning)
    }
}
