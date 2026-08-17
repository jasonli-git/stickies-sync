import Foundation

/// A single sticky note: its identity, its content, and its window state.
///
/// `windowState` is optional because the two halves live in different files and
/// either can be missing. A package with no state entry happens while Stickies
/// is mid-write and on a container assembled by hand; the note still has text
/// and is still worth replicating, just without position or colour.
public struct StickyNote: Hashable, Sendable {
    public var id: StickyID
    public var package: NotePackage
    public var windowState: StickyWindowState?

    public init(id: StickyID, package: NotePackage, windowState: StickyWindowState? = nil) {
        self.id = id
        self.package = package
        self.windowState = windowState
    }
}
