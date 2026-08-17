import CoreGraphics
import Foundation
import StickiesFormat

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

func stickyID(_ raw: String) throws -> StickyID {
    guard let id = StickyID(rawValue: raw) else {
        throw FixtureError(description: "\(raw) is not a usable sticky identifier")
    }
    return id
}

func richText(_ body: String) -> Data {
    Data(
        """
        {\\rtf1\\ansi\\ansicpg1252\\cocoartf2870
        {\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}
        \\pard\\tx560\\pardeftab560\\partightenfactor0
        \\f0\\fs28 \\cf0 \(body)}
        """.utf8
    )
}

func windowState(
    _ raw: String,
    frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200),
    color: StickyColor = StickyColor(red: 1, green: 0.96, blue: 0.61),
    zOrder: Int? = nil
) throws -> StickyWindowState {
    StickyWindowState(
        id: try stickyID(raw),
        frame: frame,
        palette: StickyPalette(sticky: color),
        zOrder: zOrder
    )
}

func note(
    _ raw: String,
    text: String = "Shopping list",
    attachments: [String: Data] = [:],
    state: StickyWindowState? = nil
) throws -> StickyNote {
    var files = attachments
    files[NotePackage.richTextEntryName] = richText(text)
    return StickyNote(
        id: try stickyID(raw),
        package: try NotePackage(files: files),
        windowState: try state ?? windowState(raw)
    )
}
