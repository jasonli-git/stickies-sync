import Foundation
import Testing

/// Files captured from a real Stickies container on macOS 26.6.1 (Stickies
/// 10.3). They are the only evidence that this tool reads the actual format
/// rather than a guess at it, so they are compared against byte for byte and
/// must not be tidied.
enum Fixtures {
    /// `.SavedStickiesState` from a Mac with two notes: one Stickies created
    /// itself, one written by hand and then accepted by Stickies unchanged.
    static let twoNoteState = "SavedStickiesState-two-notes"

    static func data(_ name: String, extension ext: String = "plist") throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "fixture \(name).\(ext) is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }
}

/// The rich text of the hand-written fixture note, byte for byte as Stickies
/// left it. Inline rather than a file so the test reads as its own explanation.
let handwrittenRichText = Data(#"""
{\rtf1\ansi\ansicpg1252\cocoartf2870
{\fonttbl\f0\fswiss\fcharset0 Helvetica;\f1\fswiss\fcharset0 Helvetica-Bold;}
{\colortbl;\red255\green255\blue255;\red255\green0\blue0;}
\pard\tx560\pardeftab560\partightenfactor0
\f0\fs28 \cf0 Hand-written note. \f1\b bold\f0\b0  \i italic\i0  \cf2 red\cf0 .\
Second line.}
"""#.utf8)
