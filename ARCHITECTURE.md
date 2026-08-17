# StickiesSync — Architecture

How the system is built and why. [SPEC.md](SPEC.md) is the source of truth for
what it should do; this document covers the structure chosen to do it, the
decisions behind that structure, and what is known to be wrong or unproven. As
of Milestone 2 a container can be read completely and written back safely on one
Mac — the format layer, a probe, a reader, a writer, the apply coordinator, and
the `doctor`, `list`, `export`, and `import` commands. Nothing moves between Macs
yet. Everything below distinguishes what exists from what is designed but not yet
written.

## System Shape

A local-first, single-user macOS background utility that replicates note
objects between a person's own Macs.

- **Runtime:** a `launchd` agent plus a `stickiesctl` command-line tool, both
  built from a SwiftPM package. Swift 6 language mode, deployment target
  macOS 14. No GUI is required for the product to be complete.
- **Storage:** the user's notes stay where Stickies keeps them. StickiesSync's
  own state — the replica database and container backups — lives under
  `~/Library/Application Support/StickiesSync/`, and is disposable: deleting it
  costs sync history, never notes.
- **Boundaries:** three of them. `StickiesFormat` knows the on-disk format and
  nothing about the filesystem. `StickiesStore` knows this Mac and nothing
  about synchronization. The sync engine (Milestone 3) will know about
  replication and nothing about Macs or networks.
- **External dependencies:** exactly one, `swift-argument-parser`. Everything
  else is Foundation and AppKit.
- **Permissions:** none. Reading another application's container was measured to
  need no TCC grant on macOS 26.6.1 (#19). The Mac App Store is still closed off,
  but by the sandbox rather than by TCC.

Future shapes stay cheap because the pieces that would change are already named
as seams. A LAN, object-store, or self-hosted backend replaces one conformance
to `SyncTransport` (Milestone 4) and touches no note-handling code. A different
conflict policy replaces `ConflictPolicy`. A macOS release that changes the
Stickies format changes `StickiesFormat` alone, and the versioned record codec
keeps an updated Mac talking to one that has not updated yet.

## Decisions Log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Swift 6 + SwiftPM, with all logic in library targets and executables kept thin | The project has to touch AppKit, `NSRunningApplication`, RTFD, and property lists — all of which are native and would be fought through any other language. Library-first means the sync logic is testable without a GUI, a window server, or the user's real notes; an Xcode project was rejected because it would make `make check` depend on a full Xcode install, which this Mac does not have (see #11) |
| 2 | A note's identity is a validated string, not a `UUID` | Stickies names new packages with UUIDs, but its legacy-database importer emits decimal names (`%lu.rtfd` in the app binary) and `.SavedStickiesState` keys off whichever string the package uses. A `UUID`-typed identifier would silently drop every note carried over from a pre-sandbox Mac. `StickyID` validates against path escapes instead, and exposes `uuid` for the common case |
| 3 | Remote changes are applied by quitting Stickies, writing, and relaunching it | Stickies holds every note open as an autosaving `NSDocument` (`autosavesInPlace` in the binary) and never reloads from disk, so a file written underneath it is overwritten by the next autosave. Deferring writes until the user happens to quit was rejected: a Mac left with Stickies open all day would never receive anything. Driving the UI through the Accessibility API was rejected as a primary path — it cannot faithfully apply rich formatting and breaks on any macOS release. The cost is a visible ~1s blink, mitigated by batching all pending changes into one cycle |
| 4 | Ordering between Macs comes from per-note version vectors, never wall-clock timestamps | Two Macs' clocks always disagree by some amount, and timestamp-comparison conflict resolution silently destroys the loser's work whenever the skew exceeds the edit interval. A version vector costs one small table and removes the entire class of bug. Arrives in Milestone 3 |
| 5 | Divergent versions produce a visible conflict copy, not an automatic merge | Rich text is not plain text; a character-level CRDT over RTF is a research project, and a heuristic merge that is right 95% of the time fails silently in the other 5%. `ConflictPolicy` is the seam where a real text merge slots in once the format layer can diff RTF meaningfully |
| 6 | The first transport is a shared directory in which no device ever writes outside its own subtree (`devices/<device-id>/…`) | One implementation covers iCloud Drive, Syncthing, Dropbox, and an SMB share with no code change, and needs no networking code in v1. The write-disjoint layout matters because both iCloud Drive and Syncthing handle two devices writing one file badly; keeping writes disjoint means the underlying syncer never sees a conflict and all reconciliation happens where we control it. Bonjour and object-store transports are deferred to Milestone 7 behind `SyncTransport` |
| 7 | Non-sandboxed, Developer ID-less, built from source; no Mac App Store | Reading `~/Library/Containers/com.apple.Stickies/…` requires Full Disk Access, which a sandboxed app cannot hold. Since the App Store is closed off regardless, v1 also drops signing, notarization, an updater, and an onboarding flow as scope that buys nothing for a personal tool |
| 8 | `ContainerProbe` reports facts; `ContainerReport.diagnostics()` judges them | The judgement — is an empty container a problem? is a frontmost Stickies? — is the part that has to stay consistent between the CLI and the Milestone 6 menu bar app. Keeping it in `StickiesStore` rather than the CLI means both render the same list rather than each inventing its own opinion |
| 9 | Directory entries that cannot be classified are collected and reported, never skipped | The format is private, undocumented, and Apple's to change. A tool that silently ignores what it does not recognise will one day write a confident, wrong file into someone's notes. SPEC.md F14 makes refusal the required behavior; `StickiesDirectory.Contents.unrecognized` is the mechanism |
| 10 | `swift-argument-parser` is the only third-party dependency | Apple-maintained, and the alternative is hand-rolling flag parsing that grows worse with every subcommand. It is confined to the `stickiesctl` target, so no library code depends on it |
| 11 | Tests run through `make test`, which injects toolchain paths, rather than bare `swift test` | This Mac has Command Line Tools and no Xcode. XCTest is absent from CLT entirely, and while swift-testing *is* present, SwiftPM does not wire up its framework, macro plugin, or interop dylib without a full Xcode. The Makefile adds the three paths only when the CLT layout is the active one, so installing Xcode makes the workaround disappear rather than conflict. Rejected: hardcoding the paths into `Package.swift`, which would break the moment Xcode is installed; and writing a hand-rolled assertion library, which throws away tooling to solve a path problem |
| 12 | Only modules with real content exist; planned modules are named in ROADMAP.md, not stubbed | An empty `SyncEngine` target that compiles is indistinguishable from a finished one at a glance. The layout below is what is built, not what is intended |
| 13 | A note's content is held as the package's raw bytes, never as an `NSAttributedString` | Reading RTFD into an attributed string and writing it back produces *different bytes* for the same document — fonts resolve, attribute runs coalesce, the colour table is rebuilt — and SPEC.md F4/F5 require a note to survive a round trip unchanged. Bytes also mean an attachment format this tool has never heard of replicates correctly, and give Milestone 3 something stable to hash. Rejected: an attributed-string model, which would have been friendlier to work with and quietly lossy |
| 14 | Window state is parsed into typed fields, but every key this version does not know is retained verbatim and written back | The format is Apple's to extend. `MultiScreenFrame` is the live example: the binary references it, but it has never been observed on a single-display Mac, so its value shape is unknown. A model that dropped it would silently destroy a two-display Mac's per-screen positions on the first write. Rejected: parsing into a fixed struct and discarding the remainder |
| 15 | Only `UUID`, `Frame`, and `StickyColor` are required in a state entry; every other key is optional, and an absent optional is not written back | `ZOrder` is genuinely absent on a Mac with one note, so requiring it would fail on ordinary input; inventing a default for a key a future macOS stops writing is the silent guess SPEC.md F14 forbids. Not writing an absent key leaves Stickies to supply its own default instead of having us assert one |
| 16 | A state entry that fails to parse costs that one note, not the read | An all-or-nothing parse means one odd entry hides the other forty notes. `SavedStickiesState.Entry.unreadable` keeps the raw value so the entry is both reported *and* written back untouched. Rejected: throwing on first bad entry, which would make a single unknown note disable sync entirely |
| 17 | The export archive is an XML property list, not JSON | A note's window state already *is* a plist dictionary, unknown keys included; JSON would mean inventing a mapping for plist types and hoping it is lossless. As a plist, fidelity is structural rather than conventional, and package bytes ride in `<data>` with no base64 hand-rolling. `formatVersion` lets a newer StickiesSync refuse an archive it would misread. Rejected: JSON, which is more universal and buys nothing for a macOS-only tool |
| 18 | Geometry strings are parsed strictly, by matching a punctuation skeleton | `NSRectFromString` answers malformed input with `NSZeroRect`, indistinguishable from a genuine zero rect. A first attempt here counted braces and numbers instead, and accepted `{{8, 1110} {300, 200}}` with the separating comma missing; comparing the punctuation shape against `{{#,#},{#,#}}` rejects anything merely plausible |
| 19 | Reading the Stickies container needs no TCC permission. **Supersedes the Full Disk Access premise of #7** | Measured on macOS 26.6.1: a process denied both `~/Library/Application Support/com.apple.TCC/TCC.db` and `~/Library/Safari` — so demonstrably without Full Disk Access — reads the Stickies container and other app containers without error. Apple protects specific applications' data, and Stickies is not among them. #7's conclusion survives: the Mac App Store stays closed, because the *sandbox* forbids reading another app's container whatever TCC says. What changes is that v1 needs no permission onboarding at all |
| 20 | `.DS_Store` is the one package entry excluded from replication | Finder metadata is machine-local by definition and never part of an RTFD document, so carrying it between Macs is noise that would also register as a spurious change in Milestone 3. Every other file in a package, recognised or not, is carried verbatim |
| 21 | Property-list values are modelled as a `PlistValue` enum rather than `[String: Any]` | `Any` is neither `Sendable` nor `Equatable`, and every read of it is an unchecked cast — untenable for a value that gets compared, hashed, carried across concurrency domains, and written back. The cost is one conversion at each filesystem boundary |
| 22 | Reading a note's text lives in `StickiesStore`, not `StickiesFormat` | RTF parsing is an AppKit facility, and `StickiesFormat` deliberately imports nothing but Foundation and CoreGraphics so that the byte-level format layer stays free of UI frameworks. `StickiesStore` already imports AppKit for run-state detection, so the extension sits there |
| 23 | An apply quits Stickies **before** reading the container or taking a backup | The obvious order — validate, back up, quit, write — is wrong, because Stickies autosaves as it quits. Anything read beforehand is stale the moment the quit lands, and a backup taken beforehand would restore a container missing the user's last few keystrokes. Only the frontmost check runs first, since it is the one refusal worth making without disturbing anything |
| 24 | A write is refused only where it would overwrite or delete a note whose existing package could not be read | The first implementation refused whenever *anything* in the container was unreadable, and a test caught that as over-strict. Unparseable state entries are written back verbatim (#16), so writing cannot damage them; an unreadable package the request never touches is likewise left alone. Refusing over either would disable sync entirely for one odd note — the failure mode #16 exists to avoid. Everything tolerated is reported as a warning naming what was left alone |
| 25 | Safety comes from a full backup and restore, not from transactional writes | A directory tree cannot be written atomically, and a container of notes is kilobytes, so copying it before every write is cheap and total. Individual packages still go in through a scratch directory and `replaceItemAt`, so a note is never observably half-written; the backup covers the gap between them. Rejected: a journal or write-ahead log, which is real machinery for a problem a copy solves |
| 26 | The scratch directory lives under Application Support, not inside the container | A staging file that outlived a crash would otherwise sit in the container forever, reported as an entry nothing recognises and confusing every later read. It has to be on the same volume for the atomic replace to work, which both paths under `~/Library` satisfy |
| 27 | An incoming note with no window state keeps whatever entry the container already had | An archive that carries no position is not a statement that the note should lose the one it has. Rejected: writing a default frame, which would move the user's note for no reason |
| 28 | A failed relaunch is a warning on a successful apply, not a failure | The notes are already written by that point. Reporting the apply as failed would invite a retry that changes nothing and quits Stickies a second time |

## Module Layout

```
Sources/
  StickiesFormat/         The on-disk format. No I/O of any kind.
    StickyID.swift           Note identity; package-filename conversion.
    StickiesDirectory.swift  Path arithmetic over a container root; entry classification.
    PlistValue.swift         Typed property-list value (#21).
    GeometryString.swift     Strict {{x, y}, {w, h}} and {w, h} parsing (#18).
    StickyWindowState.swift  One .SavedStickiesState entry: geometry, flags, palette (#14, #15).
    SavedStickiesState.swift The state document: parse, look up, serialize (#16).
    NotePackage.swift        An .rtfd package as its constituent bytes (#13).
    StickyNote.swift         Identity + package + window state.
    NoteArchive.swift        Versioned portable archive of whole notes (#17).
  StickiesStore/          This Mac: where the container is, and what state it is in.
    ContainerLocator.swift   Container, legacy database, and app-support paths from a home dir.
    StickiesApp.swift        Whether Stickies is running, and whether it is frontmost.
    ContainerProbe.swift     Reads observable facts into a ContainerReport.
    Diagnostics.swift        Judges a ContainerReport into pass/warn/fail diagnostics.
    StickiesReader.swift     Reads a container into a StickiesSnapshot.
    NoteText.swift           Plain text and title line from rich text (#22).
    StickiesProcessControl.swift  Run state, quit-and-wait, launch, behind a protocol.
    ContainerBackupStore.swift    Timestamped container copies; restore and prune (#25).
    ContainerWriter.swift    Installs packages and merges the state file (#25, #26).
    ApplyCoordinator.swift   Orders the quit, validate, back up, write, relaunch (#23).
  stickiesctl/            CLI. Presentation only — no logic worth testing lives here.
    StickiesCTL.swift        Command tree.
    CLISupport.swift         Shared --home option, table rendering, stderr reporting.
    DoctorCommand.swift      Text and JSON rendering of a ContainerReport.
    ListCommand.swift        One row per note.
    ExportCommand.swift      Writes a NoteArchive.
    ImportCommand.swift      Applies a NoteArchive; --replace and --dry-run.
Tests/
  StickiesFormatTests/    Unit and golden-file tests; Fixtures/ holds real captured files.
  StickiesStoreTests/     Probe and reader tests against a synthetic home on a real filesystem.
```

**Dependency rule:** `StickiesFormat` imports nothing but Foundation and
CoreGraphics. `StickiesStore` imports `StickiesFormat` and AppKit. `stickiesctl`
imports both plus `ArgumentParser`. Nothing imports upward, and no library target
imports `ArgumentParser`.

`StickiesFormat` performs no filesystem access at all, which is why
`StickiesDirectory` takes a root `URL` rather than hiding behind a filesystem
protocol: tests hand it a fixture path and production hands it the real
container, and neither needs a test double.

The modules named in [ROADMAP.md](ROADMAP.md) — the sync engine, the transport,
the crypto layer, the menu-bar app — do not exist yet and have no placeholder
targets (#12).

## The Stickies data format

Established by inspecting Stickies 10.3 on macOS 26.6.1 — the application
binary's symbol and string tables, its `Info.plist`, its entitlements — and then
by observing a real container: launching Stickies, hand-writing a note package
and a state entry, and watching what the app did with them. None of it is
documented by Apple.

```
~/Library/Containers/com.apple.Stickies/Data/Library/Stickies/
  <UUID>.rtfd/
    TXT.rtf              the note's rich text
    <attachments>        images and files embedded in the note, flat, no subdirectories
  .SavedStickiesState    XML plist, an array of per-note dictionaries
```

A state entry as Stickies writes it, with every key and type observed on a real
Mac:

| Key | Type | Notes |
|-----|------|-------|
| `UUID` | String | Matches the package base name |
| `Frame` | String | `"{{8, 1110}, {300, 200}}"` — screen position and size |
| `ExpandedSize` | String | `"{300, 200}"` — size to restore when un-collapsed |
| `ExpandFrameY` | Number | Y coordinate to restore when un-collapsed |
| `Floating` | Boolean | Note floats above other windows |
| `Translucent` | Boolean | Per-note translucency |
| `SpellCheckingTypes` | Integer | `NSTextCheckingTypes` mask; observed `9191` |
| `ZOrder` | Integer | **Written only when the Mac has more than one note** |
| `StickyColor` | Dictionary | `{Red, Green, Blue, Alpha}` reals, 0…1 |
| `SpineColor`, `ControlColor`, `HighlightColor` | Dictionary | Shades Stickies derives from `StickyColor`, but stores |
| `MultiScreenFrame` | *unknown* | Referenced by the binary; never observed on this single-display Mac, so preserved unparsed (#14) |

Verified from the binary:

| Fact | Evidence in the binary |
|------|------------------------|
| One `.rtfd` package per note, named by UUID | `generateUniqueUUIDAtPath:`, literal UUID filenames |
| Legacy migrated notes may be named `%lu.rtfd` instead | the `%lu.rtfd` format string |
| Window state is keyed by that same identifier | `savedStateForUUID:`, `removeSavedStateForUUID:` |
| State keys are `Frame`, `MultiScreenFrame`, `ExpandedSize`, `ZOrder`, `SpellCheckingTypes` | string table; `setWindowFrame:expanded:expandFrameY:forUUID:`, `setWindowZOrder:forUUID:` |
| Notes are `NSDocument`s (`SNDocument`) that autosave in place | `Info.plist` `NSDocumentClass`; `autosavesInPlace`, `setAutosavingDelay:` |
| Per-note colour and translucency exist as note properties | `setSpineColor:stickyColor:`, `isTranslucent`, `colorFromDictionaryRepresentation:` |
| Stickies has no iCloud sync | links only Foundation, CoreFoundation, AppKit, Cocoa, CoreServices, QuartzCore, UniformTypeIdentifiers — no CloudKit, no networking |
| Stickies has no AppleScript dictionary | no scripting keys in `Info.plist`; only the required Apple Event suite, which is enough to send `quit` |
| Stickies is itself sandboxed | `com.apple.security.app-sandbox` in its entitlements |

The five questions Milestone 0 left open, and what measurement showed:

| Question | Answer |
|----------|--------|
| Internal layout of an `.rtfd` package | Flat: `TXT.rtf` plus attachment files, no subdirectories |
| Where per-note colour lives | **In `.SavedStickiesState`, not the RTF.** Colour, translucency, and geometry are all readable without parsing rich text at all |
| Exact state key spellings and types | The table above |
| Is the state file written live or only at quit? | **Live.** Creating a note wrote the file immediately while Stickies ran, and quitting afterwards changed nothing. The quit cycle is therefore needed for writes only — Milestone 3's watcher can read freely |
| Is Full Disk Access required? | **No** (#19). A process denied both `TCC.db` and `~/Library/Safari` read the container without error |

One measurement is still missing: whether a window *move or resize* is flushed
immediately or on a delay. Note creation was flushed at once, and the binary has
`setAutosavingDelay:`, so a short debounce is likely. It matters only for how
promptly Milestone 3 notices a dragged window, not for correctness.

Two things a hand-written note proved, both of which de-risk Milestone 2: Stickies
loaded a package and state entry it had not written, honouring the frame, colour,
floating and translucent flags exactly; and it left the rich text byte-identical,
having no reason to rewrite a document nobody edited.

## Health check pipeline

```
ContainerLocator      home directory      -> container, legacy DB, app-support paths
        |
ContainerProbe.run()  filesystem + AppKit -> ContainerReport   (facts; never throws)
        |
report.diagnostics()  interpretation      -> [Diagnostic]      (ok / warning / failure)
        |
DoctorCommand         presentation        -> text or JSON, exit 1 on failure
```

`ContainerProbe.run()` does not throw. An unreadable container is a fact doctor
exists to report, not an error that should abort the report — a Mac missing Full
Disk Access must still get the other seven diagnostics, one of which tells it
how to fix the first. Warnings never fail the run: an empty Stickies and a
frontmost Stickies are ordinary states.

The run-state observer is injected as a closure so tests never touch AppKit or
depend on what happens to be running on the machine. `StickiesApp.runState()`
returns `.notRunning` rather than failing when there is no window server, so a
Mac reached over SSH degrades to the same answer it would give with Stickies
quit.

## Reading a container

```
StickiesDirectory.classify()  listing        -> notes | state file | unrecognised
        |
SavedStickiesState(data:)     state file     -> [.note | .unreadable]  per entry (#16)
        |
StickiesReader.readPackage()  each .rtfd     -> NotePackage            bytes (#13)
        |
StickiesReader.read()         join by id     -> StickiesSnapshot
        |
ListCommand / ExportCommand   presentation   -> table, or a NoteArchive (#17)
```

`read()` throws only when the container listing or the state *file* cannot be
read at all — a failure the caller cannot work around. Everything else is
collected into the snapshot, in five separate fields, because each awkward case
means something different:

| Field | What it means |
|-------|---------------|
| `notes` | Read completely. Safe to replicate |
| `stateWithoutPackage` | Window state for a note that is not on disk. Stickies mid-write, or a stale entry |
| `unreadableNotes` | A package exists but did not validate. **Data we would silently drop** |
| `unreadableStateEntries` | An entry the format layer could not parse. Note syncs without position or colour |
| `unrecognizedEntries` | Something in the container that is neither a note nor the state file |

`isFullyUnderstood` is true only when the last three are all empty — the
precondition SPEC.md F14 requires before Milestone 2 writes anything anywhere.
`hasUnreadableData` is the narrower test the CLI fails a command on: an entry we
merely do not *recognise* is reported and tolerated, while a note we could not
*read* is not.

## The write path

Stickies reads its directory at launch and writes over it thereafter, from
memory, with no file-presenter behavior that would let it notice an external
edit. Anything written while it runs is lost at the next autosave, and a
concurrent write to `.SavedStickiesState` can corrupt state for every note at
once. `ApplyCoordinator` exists to make writing safe in spite of that.

```
request empty?          -> nothing at all: no quit, no backup
Stickies frontmost?     -> refuse. The user is typing; nothing is touched
quit Stickies              (it autosaves on the way out — #23)
read + validate         -> refuse: relaunch first, leave the Mac as we found it
back up the container      (#25)
write packages, then the state file
  on failure            -> restore the backup, relaunch, report the rollback
relaunch                   only if we were the one who quit it
prune old backups          failure here is a warning, not a failed apply
```

The order is the design, and it is not the obvious one. Quitting comes *before*
reading and backing up, because Stickies flushes its notes as it quits: anything
read earlier is stale, and a backup taken earlier would restore a container
missing the user's last keystrokes (#23).

Three guards, each of which has a test:

| Guard | Behaviour |
|-------|-----------|
| Frontmost | Refuses outright. A frontmost Stickies means the user is typing in it |
| Ownership | Relaunches only if the coordinator was the one that quit Stickies, so an app the user closed deliberately stays closed |
| Unreadable notes | Refuses when the request would overwrite or delete a note whose existing package could not be read (#24) |

Writes go through `ContainerWriter`, which stages each package in a scratch
directory outside the container and then `replaceItemAt`s it into place, so a note
is never observably half-written. The state file is merged rather than
regenerated: entries for notes the request does not touch keep their positions in
the array, and entries this version cannot parse are written back verbatim.

Rollback is a full restore from the backup taken moments earlier — replacing the
container directory rather than merging into it, so files a failed write created
are removed too. If the restore *also* fails, the error names the backup, because
at that point a person has to look.

## Fidelity of a write

Measured by importing into the real Stickies repeatedly and reading back what it
left on disk after loading and quitting.

Preserved exactly, every time: note text and rich formatting (byte-identical
package contents), attachments, all four colours, window size, floating, and
translucency.

**Window position and z-order are best-effort.** On one import — the one that
introduced a brand-new note — Stickies repositioned two notes after loading them,
`{{400, 700}}` becoming `{{1279, 673}}`, and swapped their z-order. Six later
imports, including ones performed while Stickies was running, honoured written
frames exactly, so the behaviour is not reproducible on demand and its trigger is
unknown. Stickies owns window placement and can overrule what is on disk; nothing
in StickiesSync can prevent that, so position is written faithfully and not
guaranteed. Z-order should be read as advisory in any case, since Stickies
renumbers it as windows are raised.

## Known limitations

- **`swift test` does not work on this Mac; `make test` does.** The Command Line
  Tools ship swift-testing but SwiftPM does not wire it up, and XCTest is absent
  altogether (#11). Anyone running the bare command sees `no such module
  'Testing'`. Installing Xcode fixes it and makes the Makefile's injected flags
  drop out on their own.
- **Only macOS 26.6.1 has been verified.** The package's deployment target is
  macOS 14 because nothing built so far needs anything newer, but that is a
  compile-time floor, not a statement about the format. No older release has
  been tested against.
- **A TCC denial may be indistinguishable from an empty directory.** Denials
  normally surface as `NSFileReadNoPermission`, which the probe reports
  precisely. If a future macOS gates app containers and returns an empty listing
  instead, doctor would report "no notes" on a Mac that has plenty.
- **Doctor counts state entries without reading them.** It checks only that
  `.SavedStickiesState` parses as an array; the entries themselves are parsed by
  `StickiesReader`, so `list` and `export` will report a malformed entry that
  `doctor` calls healthy.
- **Only one attachment shape has been exercised.** Packages carrying real
  images, and notes above a few hundred bytes, have not been read from a
  Stickies-authored container — the test Mac has no such notes. Attachments are
  carried as opaque bytes, so the risk is in the assumption that the package
  stays flat, not in the copying.
- **`.DS_Store` inside a package is dropped, not replicated** (#20). Deliberate,
  but it does mean a package is not reproduced byte-for-byte in the pathological
  case where someone has browsed into it with Finder.
- **A note with no window state syncs without position or colour.** It is
  reported on stderr rather than failing the read, because the note's text is
  still worth replicating. Milestone 4 has to decide what position a note like
  that lands in on the receiving Mac.
- **Window position is not guaranteed across a write**, as described under
  "Fidelity of a write" above. Observed once, cause unknown, not reproducible.
- **`ApplyOutcome.written` counts everything requested, not everything that
  changed.** A note written identically to what was already on disk is still
  reported as written, because nothing yet compares the two. Milestone 3's
  content hashing is what makes "actually changed" answerable, and until then an
  import's summary overstates what it did.
- **An import applies the whole archive every time.** There is no batching or
  debouncing yet, so ten archives imported in a row quit and relaunch Stickies
  ten times. The coalescing SPEC.md promises belongs to the Milestone 4 agent,
  which is the first component with a queue to coalesce.
- **Backups are pruned by count, not by age or size** — the newest ten are kept.
  A Mac that syncs heavily therefore retains a shorter history than a quiet one.
