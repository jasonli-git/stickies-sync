import Foundation
import StickiesFormat
import Testing

@testable import StickiesStore

@Suite("NotePackage text")
struct NoteTextTests {
    @Test("Reads the text out of rich text Stickies wrote")
    func readsPlainText() throws {
        let package = try NotePackage(files: [NotePackage.richTextEntryName: sampleRichText])

        #expect(package.plainText == "Shopping list\nMilk and eggs.")
        #expect(package.titleLine == "Shopping list")
    }

    @Test("An empty note has no title rather than an empty one")
    func handlesAnEmptyNote() throws {
        // This is byte-for-byte what Stickies writes for a note with no text.
        let empty = Data(#"""
        {\rtf1\ansi\ansicpg1252\cocoartf2870
        \cocoatextscaling0\cocoaplatform0{\fonttbl}
        {\colortbl;\red255\green255\blue255;}
        {\*\expandedcolortbl;;}
        }
        """#.utf8)
        let package = try NotePackage(files: [NotePackage.richTextEntryName: empty])

        #expect(package.plainText == "")
        #expect(package.titleLine == nil)
    }

    @Test("Leading blank lines are skipped when picking a title")
    func skipsLeadingBlankLines() throws {
        let rtf = Data(#"""
        {\rtf1\ansi\ansicpg1252\cocoartf2870
        {\fonttbl\f0\fswiss\fcharset0 Helvetica;}
        \pard\tx560\pardeftab560\partightenfactor0
        \f0\fs28 \
        \
        Actual first line.}
        """#.utf8)
        let package = try NotePackage(files: [NotePackage.richTextEntryName: rtf])

        #expect(package.titleLine == "Actual first line.")
    }

    @Test("Rich text that does not parse yields no text rather than an empty note")
    func reportsUnparseableRichText() throws {
        let package = try NotePackage(files: [NotePackage.richTextEntryName: Data([0xFF, 0xFE, 0x00])])

        // An empty string here would be indistinguishable from an empty note,
        // which is how a listing ends up quietly lying about a note's content.
        #expect(package.plainText == nil)
        #expect(package.titleLine == nil)
    }
}
