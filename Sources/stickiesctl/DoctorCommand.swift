import ArgumentParser
import Foundation
import StickiesFormat
import StickiesStore

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report whether this Mac's Stickies data can be read.",
        discussion: """
            Exits non-zero if any check fails. Warnings do not fail the run: an \
            empty Stickies or a frontmost Stickies is an ordinary state, not a \
            broken Mac.
            """
    )

    @Flag(name: .long, help: "Emit the report as JSON instead of text.")
    var json = false

    @OptionGroup var container: ContainerOptions

    func run() throws {
        let report = ContainerProbe.forHome(container.home).run()
        let diagnostics = report.diagnostics()

        if json {
            print(try DoctorPayload(report: report, diagnostics: diagnostics).encodedJSON())
        } else {
            print(renderText(report: report, diagnostics: diagnostics))
        }

        if report.overallStatus == .failure {
            throw ExitCode.failure
        }
    }
}

// MARK: - Text rendering

private func renderText(report: ContainerReport, diagnostics: [Diagnostic]) -> String {
    let width = diagnostics.map(\.name.count).max() ?? 0
    let rows = diagnostics.map { diagnostic in
        let name = diagnostic.name.padding(toLength: width, withPad: " ", startingAt: 0)
        return "  \(glyph(for: diagnostic.status))  \(name)   \(diagnostic.detail)"
    }
    return (["StickiesSync doctor", ""] + rows + ["", "Result: \(report.overallStatus.rawValue)"])
        .joined(separator: "\n")
}

private func glyph(for status: Diagnostic.Status) -> String {
    switch status {
    case .ok: "✔"
    case .warning: "!"
    case .failure: "✘"
    }
}

// MARK: - JSON rendering

/// An explicit wire shape rather than a derived one: the report's enums carry
/// associated values that would encode as awkward nested objects, and this
/// output is a presentation concern belonging to the CLI.
private struct DoctorPayload: Encodable {
    struct Entry: Encodable {
        let name: String
        let status: String
        let detail: String
    }

    let status: String
    let container: String
    let access: String
    let accessDetail: String?
    let noteCount: Int
    let notes: [StickyID]
    let unrecognizedEntries: [String]
    let savedState: String
    let savedStateEntryCount: Int?
    let savedStateDetail: String?
    let legacyDatabasePresent: Bool
    let stateDirectory: String
    let stateDirectoryWritable: Bool
    let stickiesRunning: Bool
    let stickiesFrontmost: Bool
    let diagnostics: [Entry]

    init(report: ContainerReport, diagnostics: [Diagnostic]) {
        let (access, accessDetail) = Self.describe(report.access)
        let (savedState, savedStateCount, savedStateDetail) = Self.describe(report.savedState)

        self.status = report.overallStatus.rawValue
        self.container = report.directory.path(percentEncoded: false)
        self.access = access
        self.accessDetail = accessDetail
        self.noteCount = report.notes.count
        self.notes = report.notes
        self.unrecognizedEntries = report.unrecognizedEntries
        self.savedState = savedState
        self.savedStateEntryCount = savedStateCount
        self.savedStateDetail = savedStateDetail
        self.legacyDatabasePresent = report.legacyDatabasePresent
        self.stateDirectory = report.applicationSupportDirectory.path(percentEncoded: false)
        self.stateDirectoryWritable = report.applicationSupportWritable
        self.stickiesRunning = report.runState.isRunning
        self.stickiesFrontmost = report.runState == .running(frontmost: true)
        self.diagnostics = diagnostics.map {
            Entry(name: $0.name, status: $0.status.rawValue, detail: $0.detail)
        }
    }

    private static func describe(_ access: ContainerReport.Access) -> (String, String?) {
        switch access {
        case .readable: ("readable", nil)
        case .missing: ("missing", nil)
        case .notADirectory: ("notADirectory", nil)
        case .permissionDenied(let message): ("permissionDenied", message)
        case .failed(let message): ("failed", message)
        }
    }

    private static func describe(_ savedState: ContainerReport.SavedState) -> (String, Int?, String?) {
        switch savedState {
        case .missing: ("missing", nil, nil)
        case .parsed(let count): ("parsed", count, nil)
        case .unexpectedRoot(let type): ("unexpectedRoot", nil, type)
        case .unreadable(let message): ("unreadable", nil, message)
        }
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
