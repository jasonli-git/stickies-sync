import Foundation
import Testing

@testable import StickiesStore

@Suite("ContainerProbe")
struct ContainerProbeTests {
    @Test("A populated container reports its notes, its state file, and nothing wrong")
    func probesAPopulatedContainer() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("A0000000-0000-0000-0000-000000000000")
            try home.addNote("B0000000-0000-0000-0000-000000000000")
            try home.writeSavedState(entryCount: 2)

            let report = home.probe().run()

            #expect(report.access == .readable)
            #expect(report.notes.map(\.rawValue) == [
                "A0000000-0000-0000-0000-000000000000",
                "B0000000-0000-0000-0000-000000000000",
            ])
            #expect(report.savedState == .parsed(topLevelEntryCount: 2))
            #expect(report.unrecognizedEntries.isEmpty)
            #expect(report.legacyDatabasePresent == false)
            #expect(report.applicationSupportWritable)
            #expect(report.overallStatus == .ok)
        }
    }

    @Test("A missing container is a reported fact, not a thrown error")
    func reportsAMissingContainer() throws {
        try SyntheticHome.run { home in
            let report = home.probe().run()

            #expect(report.access == .missing)
            #expect(report.notes.isEmpty)
            #expect(report.savedState == .missing)
            #expect(report.overallStatus == .failure)
        }
    }

    @Test("An entry that is neither a note nor the state file is surfaced, not skipped")
    func surfacesUnclassifiableEntries() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addDirectoryEntry(named: "Backups")

            let report = home.probe().run()

            #expect(report.notes.map(\.rawValue) == ["17"])
            #expect(report.unrecognizedEntries == ["Backups"])
            #expect(report.diagnostic(named: "Unrecognised entries")?.status == .warning)
        }
    }

    @Test("A state file whose root is not an array is treated as a format change")
    func detectsAnUnexpectedStateRoot() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.writeSavedState(propertyList: ["Frame": "0 0 300 300"])

            let report = home.probe().run()

            // The reported type name is whatever the plist bridge produced; the
            // case is what matters, so this does not pin the class name.
            guard case .unexpectedRoot = report.savedState else {
                Issue.record("expected an unexpected state root, got \(report.savedState)")
                return
            }
            #expect(report.diagnostic(named: "Saved window state")?.status == .failure)
        }
    }

    @Test("A corrupt state file fails the run rather than being ignored")
    func detectsAnUnreadableStateFile() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.writeRawSavedState(Data("not a property list".utf8))

            let report = home.probe().run()

            guard case .unreadable = report.savedState else {
                Issue.record("expected an unreadable state file, got \(report.savedState)")
                return
            }
            #expect(report.overallStatus == .failure)
        }
    }

    @Test("Notes and state entries that disagree in count are flagged")
    func flagsStateDisagreement() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("1")
            try home.addNote("2")
            try home.addNote("3")
            try home.writeSavedState(entryCount: 1)

            let report = home.probe().run()

            let diagnostic = try #require(report.diagnostic(named: "State/notes agreement"))
            #expect(diagnostic.status == .warning)
            #expect(diagnostic.detail.contains("3 note(s) but 1 state entry/entries"))
        }
    }

    @Test("A surviving pre-sandbox database is flagged as possibly unmigrated notes")
    func flagsTheLegacyDatabase() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.createLegacyDatabase()

            let report = home.probe().run()

            #expect(report.legacyDatabasePresent)
            #expect(report.diagnostic(named: "Legacy Stickies database")?.status == .warning)
        }
    }

    @Test("The run state comes from the injected observer, not from this Mac")
    func reportsTheObservedRunState() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("1")
            try home.writeSavedState(entryCount: 1)

            #expect(home.probe(runState: .running(frontmost: true)).run().runState == .running(frontmost: true))
            #expect(home.probe(runState: .notRunning).run().runState == .notRunning)
        }
    }
}

extension ContainerReport {
    func diagnostic(named name: String) -> Diagnostic? {
        diagnostics().first { $0.name == name }
    }
}
