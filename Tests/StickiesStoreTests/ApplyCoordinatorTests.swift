import CoreGraphics
import Foundation
import StickiesFormat
import Testing

@testable import StickiesStore

@Suite("ApplyCoordinator")
struct ApplyCoordinatorTests {
    private func incoming(_ rawIdentifier: String, text: String = "Incoming note") throws -> StickyNote {
        let rtf = Data(#"""
            {\rtf1\ansi\ansicpg1252\cocoartf2870
            {\fonttbl\f0\fswiss\fcharset0 Helvetica;}
            \pard\tx560\pardeftab560\partightenfactor0
            \f0\fs28 \cf0 TEXT}
            """#.replacingOccurrences(of: "TEXT", with: text).utf8)

        return StickyNote(
            id: try #require(StickyID(rawValue: rawIdentifier)),
            package: try NotePackage(files: [NotePackage.richTextEntryName: rtf]),
            windowState: try makeWindowState(
                rawIdentifier,
                frame: CGRect(x: 500, y: 300, width: 320, height: 220)
            )
        )
    }

    // MARK: - The three guards

    @Test("Refuses while Stickies is frontmost, without quitting or writing")
    func refusesWhileFrontmost() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let control = FakeProcessControl(state: .running(frontmost: true))

            #expect(throws: ApplyRefusal.stickiesIsFrontmost) {
                try home.coordinator(processControl: control)
                    .apply(ApplyRequest(notes: [try incoming("17")]))
            }

            // The user is typing: nothing may be interrupted or changed.
            #expect(control.quitCallCount == 0)
            #expect(try home.reader().read().notes.isEmpty)
            #expect(try home.backupStore().backups().isEmpty)
        }
    }

    @Test("Refuses when Stickies will not quit, and does not write")
    func refusesWhenStickiesWillNotQuit() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let control = FakeProcessControl(state: .running(frontmost: false), refusesToQuit: true)

            #expect(throws: ApplyRefusal.stickiesWouldNotQuit(timeout: 0.1)) {
                try home.coordinator(processControl: control)
                    .apply(ApplyRequest(notes: [try incoming("17")]))
            }

            #expect(control.quitCallCount == 1)
            #expect(try home.reader().read().notes.isEmpty)
        }
    }

    @Test("Refuses to overwrite a note whose existing package cannot be read")
    func refusesToOverwriteAnUnreadableNote() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addEmptyPackage("17")  // a package with no rich text
            let control = FakeProcessControl(state: .running(frontmost: false))

            // Writing over it would destroy content this tool never managed to
            // read, which is the one case worth refusing outright.
            #expect(throws: ApplyRefusal.self) {
                try home.coordinator(processControl: control)
                    .apply(ApplyRequest(notes: [try incoming("17")]))
            }

            // Stickies was interrupted for nothing, so it goes back up before
            // the refusal surfaces.
            #expect(control.quitCallCount == 1)
            #expect(control.launchCallCount == 1)
            #expect(try home.reader().read().notes.isEmpty)
        }
    }

    @Test("Refuses to delete a note whose existing package cannot be read")
    func refusesToDeleteAnUnreadableNote() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addEmptyPackage("17")

            #expect(throws: ApplyRefusal.self) {
                try home.coordinator(processControl: FakeProcessControl())
                    .apply(ApplyRequest(removing: [try #require(StickyID(rawValue: "17"))]))
            }
        }
    }

    @Test("An unreadable note the request does not touch is warned about, not refused")
    func toleratesAnUnreadableNoteElsewhere() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addEmptyPackage("18")

            // Refusing here would disable sync for every note because of one
            // broken one — see the note on validate() in ApplyCoordinator.
            let outcome = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [try incoming("17")]))

            #expect(outcome.written.map(\.rawValue) == ["17"])
            #expect(outcome.warnings.contains { $0.contains("leaving unreadable note 18") })
            #expect(try home.reader().read().notes.map(\.id.rawValue) == ["17"])
        }
    }

    @Test("A window-state entry this version cannot parse does not block a write")
    func toleratesAnUnparseableStateEntry() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.writeSavedState(propertyList: [["UUID": "99"]] as [Any])

            // The writer keeps such entries verbatim, so nothing can be lost by
            // proceeding.
            let outcome = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [try incoming("17")]))

            #expect(outcome.written.map(\.rawValue) == ["17"])
            #expect(outcome.warnings.contains { $0.contains("cannot parse, verbatim") })
        }
    }

    // MARK: - Ownership of the relaunch

    @Test("Relaunches Stickies only when it was the one to quit it")
    func relaunchesOnlyWhatItQuit() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let closed = FakeProcessControl(state: .notRunning)

            let outcome = try home.coordinator(processControl: closed)
                .apply(ApplyRequest(notes: [try incoming("17")]))

            // An app the user closed deliberately stays closed.
            #expect(closed.quitCallCount == 0)
            #expect(closed.launchCallCount == 0)
            #expect(outcome.didQuitStickies == false)
            #expect(outcome.didRelaunchStickies == false)
            #expect(outcome.written.map(\.rawValue) == ["17"])
        }
    }

    @Test("Quits and relaunches a backgrounded Stickies")
    func quitsAndRelaunchesABackgroundStickies() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let control = FakeProcessControl(state: .running(frontmost: false))

            let outcome = try home.coordinator(processControl: control)
                .apply(ApplyRequest(notes: [try incoming("17")]))

            #expect(control.quitCallCount == 1)
            #expect(control.launchCallCount == 1)
            #expect(outcome.didQuitStickies)
            #expect(outcome.didRelaunchStickies)
        }
    }

    @Test("A failed relaunch is a warning, not a failed apply")
    func aFailedRelaunchDoesNotFailTheApply() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let control = FakeProcessControl(
                state: .running(frontmost: false),
                launchError: FakeLaunchError()
            )

            let outcome = try home.coordinator(processControl: control)
                .apply(ApplyRequest(notes: [try incoming("17")]))

            // The notes are written; reporting failure would invite a retry
            // that changes nothing.
            #expect(outcome.written.count == 1)
            #expect(outcome.didRelaunchStickies == false)
            #expect(outcome.warnings.contains { $0.contains("could not relaunch") })
            #expect(try home.reader().read().notes.count == 1)
        }
    }

    // MARK: - Writing

    @Test("Writes a note's package and window state into an empty container")
    func writesIntoAnEmptyContainer() throws {
        try SyntheticHome.run { home in
            try home.createContainer()

            let outcome = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [try incoming("17", text: "Hello from another Mac")]))

            let snapshot = try home.reader().read()
            let note = try #require(snapshot.notes.first)
            #expect(note.id.rawValue == "17")
            #expect(note.package.titleLine == "Hello from another Mac")
            #expect(note.windowState?.frame == CGRect(x: 500, y: 300, width: 320, height: 220))
            #expect(outcome.backupName != nil)
        }
    }

    @Test("Overwrites an existing note without disturbing its neighbours")
    func overwritesOneNoteOnly() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addNote("18")
            try home.writeSavedState(notes: [
                try makeWindowState("17", zOrder: 1),
                try makeWindowState("18", zOrder: 2),
            ])

            _ = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [try incoming("17", text: "Replaced")]))

            let snapshot = try home.reader().read()
            #expect(snapshot.notes.count == 2)
            #expect(snapshot.notes.first { $0.id.rawValue == "17" }?.package.titleLine == "Replaced")
            #expect(snapshot.notes.first { $0.id.rawValue == "18" }?.package.titleLine == "Shopping list")
            #expect(snapshot.notes.first { $0.id.rawValue == "18" }?.windowState?.zOrder == 2)
        }
    }

    @Test("Removing a note deletes its package and its state entry")
    func removesANote() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.addNote("18")
            try home.writeSavedState(notes: [try makeWindowState("17"), try makeWindowState("18")])

            let id = try #require(StickyID(rawValue: "18"))
            let outcome = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(removing: [id]))

            let snapshot = try home.reader().read()
            #expect(snapshot.notes.map(\.id.rawValue) == ["17"])
            #expect(snapshot.savedState.notes.map(\.id.rawValue) == ["17"])
            #expect(snapshot.stateWithoutPackage.isEmpty)
            #expect(outcome.removed.map(\.rawValue) == ["18"])
        }
    }

    @Test("An incoming note without window state keeps the position it already had")
    func keepsExistingStateWhenTheArchiveHasNone() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.writeSavedState(notes: [
                try makeWindowState("17", frame: CGRect(x: 1, y: 2, width: 300, height: 200)),
            ])

            var note = try incoming("17", text: "Text only")
            note.windowState = nil

            _ = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [note]))

            // An archive that carries no position is not a statement that the
            // note should lose the one it has.
            let snapshot = try home.reader().read()
            #expect(snapshot.notes.first?.package.titleLine == "Text only")
            #expect(snapshot.notes.first?.windowState?.frame == CGRect(x: 1, y: 2, width: 300, height: 200))
        }
    }

    @Test("Unrecognised container entries are reported and left alone")
    func leavesUnrecognizedEntriesAlone() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addDirectoryEntry(named: "Backups")

            let outcome = try home.coordinator(processControl: FakeProcessControl())
                .apply(ApplyRequest(notes: [try incoming("17")]))

            #expect(outcome.warnings.contains { $0.contains("Backups") })
            #expect(try home.reader().read().unrecognizedEntries == ["Backups"])
        }
    }

    // MARK: - Dry run

    @Test("A dry run changes nothing and does not interrupt Stickies")
    func dryRunChangesNothing() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let control = FakeProcessControl(state: .running(frontmost: false))
            let before = try home.containerContents()

            let outcome = try home.coordinator(processControl: control)
                .apply(ApplyRequest(notes: [try incoming("17")]), dryRun: true)

            #expect(outcome.wasDryRun)
            #expect(outcome.written.map(\.rawValue) == ["17"])
            #expect(outcome.backupName == nil)
            #expect(control.quitCallCount == 0)
            #expect(try home.containerContents() == before)
            #expect(outcome.warnings.contains { $0.contains("would quit it first") })
        }
    }

    @Test("An empty request does nothing at all")
    func anEmptyRequestIsANoOp() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let control = FakeProcessControl(state: .running(frontmost: true))

            // Frontmost would normally refuse; an empty request never gets that
            // far, because there is nothing to interrupt anyone for.
            let outcome = try home.coordinator(processControl: control).apply(ApplyRequest())

            #expect(outcome.written.isEmpty)
            #expect(outcome.backupName == nil)
            #expect(control.quitCallCount == 0)
        }
    }

    // MARK: - Backup and rollback

    @Test("A failed write is rolled back, leaving the container as it was")
    func rollsBackAFailedWrite() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.writeSavedState(notes: [try makeWindowState("17")])
            let before = try home.containerContents()

            // A writer whose scratch root cannot be created fails partway
            // through, after the backup has been taken.
            let failing = ContainerWriter(
                directory: home.stickiesDirectory,
                scratchRoot: URL(filePath: "/dev/null/scratch", directoryHint: .isDirectory)
            )
            let control = FakeProcessControl(state: .running(frontmost: false))

            #expect(throws: ApplyRefusal.self) {
                try home.coordinator(processControl: control, writer: failing)
                    .apply(ApplyRequest(notes: [try incoming("99")]))
            }

            #expect(try home.containerContents() == before)
            #expect(control.launchCallCount == 1)
        }
    }

    @Test("Old backups are pruned and the newest are kept")
    func prunesOldBackups() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            let store = home.backupStore()

            for _ in 0..<4 {
                _ = try store.makeBackup(of: home.stickiesDirectory.root)
            }
            #expect(try store.backups().count == 4)

            try store.prune(keeping: 2)
            let remaining = try store.backups()
            #expect(remaining.count == 2)
            // Newest first, and the two kept are the two newest.
            #expect(remaining.map(\.name).sorted(by: >) == remaining.map(\.name))
        }
    }

    @Test("A backup captures the container and restoring it undoes later changes")
    func backupAndRestoreRoundTrip() throws {
        try SyntheticHome.run { home in
            try home.createContainer()
            try home.addNote("17")
            try home.writeSavedState(notes: [try makeWindowState("17")])
            let original = try home.containerContents()

            let store = home.backupStore()
            let backup = try store.makeBackup(of: home.stickiesDirectory.root)

            try home.addNote("18")
            #expect(try home.containerContents() != original)

            try store.restore(backup, to: home.stickiesDirectory.root)

            // Restoring replaces the directory rather than merging into it, so
            // the note added afterwards is gone.
            #expect(try home.containerContents() == original)
        }
    }
}
