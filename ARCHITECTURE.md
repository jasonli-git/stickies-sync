# StickiesSync — Architecture

How the system is built and why. [SPEC.md](SPEC.md) is the source of truth for
what it should do; this document covers the structure chosen to do it, the
decisions behind that structure, and what is known to be wrong or unproven. As
of Milestone 4 notes move between Macs over a shared folder, with conflicts
resolved into visible copies. Everything below distinguishes what exists from
what is designed but not yet written.

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
- **Boundaries:** four of them. `StickiesFormat` knows the on-disk format and
  nothing about the filesystem. `StickiesStore` knows this Mac and nothing about
  synchronization. `SyncEngine` knows about replication and transports, and
  nothing about Macs or containers. `StickiesSyncKit` is the only place the
  middle two meet.
- **External dependencies:** exactly one, `swift-argument-parser`. Everything
  else is Foundation, AppKit, CoreServices, SQLite3 and CryptoKit.
- **Permissions:** none. Reading another application's container was measured to
  need no TCC grant on macOS 26.6.1 (#19). The Mac App Store is still closed off,
  but by the sandbox rather than by TCC.

Future shapes stay cheap because the pieces that would change are already named
as seams. A LAN, object-store, or self-hosted backend replaces one conformance
to `SyncTransport` and touches no note-handling code. A different conflict
policy replaces `MergeDecision`. A macOS release that changes the
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
| 29 | `SyncEngine` depends on `StickiesFormat` only, never on `StickiesStore` | The engine replicates notes; it must not learn what a Mac, a container, or a network is, or Milestone 4's transport work would have to reach through it. It is handed `[StickyNote]` and returns what changed. The CLI is the only place the store and the engine meet, in `ContainerOptions.reconcile` — a join of about four lines, which is the right size for that seam |
| 30 | SQLite is used through a hand-written wrapper over the system library, not a package | The schema is four tables and roughly twenty statements. GRDB and SQLite.swift were both considered and rejected: they are good libraries, but this would be a dependency the project leans on permanently to save ~180 lines, and `swift-argument-parser` staying the only third-party package is worth more than the saving (#10). `Database` is the seam if that ever stops being true |
| 31 | A note has two digests — content and window state — not one | Stickies moves windows and renumbers z-order on its own, so a single digest would report a note as edited every time its window shifted, and a sync driven by that would ship the note's whole content because the user dragged it. Two digests let `NoteChange.isWindowStateOnly` exist, so Milestone 4 can price a move differently from an edit. Costs one extra column and one extra hash per note |
| 32 | Hashing goes through a canonical byte encoding of the property list, not `Hashable` or a serialized plist | Swift's `Hashable` is seeded per process, so a digest stored today would not match the same value hashed tomorrow — a replica that reported every note as edited on every launch. A serialized plist is not canonical either, since dictionary key order follows the hash table's layout. `PlistValue.canonicalBytes` sorts keys and length-prefixes every string and blob, so no two distinct values can collide by running together at a boundary |
| 33 | `reconcile` detects and records in one transaction; there is no "just tell me what changed" | A caller that could ask without committing would eventually ask twice and act twice. Observing a change exactly once is the property the whole replica exists to provide, and making it optional would put that property in every caller's hands |
| 34 | A retained version is stored as a single-note `NoteArchive` blob | Reuses the format layer's codec instead of inventing a second serialization for the same data, so history automatically gains anything the archive gains — and a version restored from history is byte-identical to one restored from an exported file, because it is the same bytes through the same decoder |
| 35 | The schema is a numbered list of migrations, applied on every open | The replica is a cache the user carries across versions of this tool, but it is the *only* home of the version history, so rebuilding it from scratch on a schema change would destroy the thing it exists to hold. Migrations are append-only and `user_version` records progress |
| 37 | Every choice in `MergeDecision` is a pure function of the two records | Two Macs never talk to each other: each sees the same pair and decides alone. A conflict copy named with a fresh UUID, or a winner chosen by "whoever is resolving", makes the two Macs disagree permanently — each creating conflict copies of the other's conflict copies. So the winner comes from `(recordedAt, origin device)` and the copy's identifier is a SHA-256 of the original identifier and the losing vector. Both Macs compute the same answers from the same inputs |
| 38 | A conflict copy carries the *loser's* vector, not a fresh one | Each Mac creates the copy independently. If each stamped it with its own new version the two copies would be concurrent and would immediately conflict with each other, forever. Carrying the loser's vector makes the two copies identical, so they compare equal and settle |
| 39 | A conflict copy is marked by colour and offset, never by editing the note | SPEC.md requires the copy be marked. Prepending a "CONFLICT COPY" line was rejected: building it means re-serializing rich text, which produces different bytes on different Macs (#13) — so the two copies would differ and conflict with each other. A colour and a frame offset are exact numbers both Macs write identically, and they are visible the moment the note appears |
| 40 | An edit always beats a deletion | A tombstone has nothing to preserve, so this is not a conflict worth showing anyone and no copy is made. It does mean deleting a note on one Mac while editing it on another resurrects the note; that is the direction SPEC.md's first principle says to fail in |
| 41 | `SyncService` lives in a new `StickiesSyncKit`, not in the CLI | It is the only code that needs both halves — the container and the replica — and putting it in the executable would make it untestable and unavailable to the Milestone 6 app. Everything below it stays ignorant of the other half (#29) |
| 42 | `integrate` records a history version only when there is content to retain | Found by the convergence test, not by reading the code. A resolution that keeps local content and only advances the vector was writing a history row with a NULL archive — onto the key `(note, device, seq)` that already held that content, erasing it. The Mac then published an older version and quietly overwrote the peer's correct text with stale text. A pass that changes no content now writes no version |
| 43 | The origin column is backfilled when a replica opens, not by its migration | `ALTER TABLE … DEFAULT ''` leaves every pre-existing row empty, and the migration cannot fill it because it runs before the device row exists. Rows left empty publish records with no origin, and the receiving Mac then files every version of that note under sequence zero, each overwriting the last. Caught by inspecting the first records actually written to iCloud Drive, not by any test |
| 44 | Window geometry is machine-local: it never bumps a version and is never published | Measured across two real Macs. A frame is a function of the display it was placed on, and Stickies rewrites out-of-bounds frames by itself, so replicating geometry makes every Mac's layout collapse to the smallest screen in the set — merely opening Stickies on a laptop rearranged the desktop Mac's notes. Colour, translucency and floating still travel, because those describe the note rather than the screen. Rejected: suppressing only the *publish* of a move, which leaves geometry riding inside the record so the next content edit drags it across anyway; and per-device geometry maps, which preserve more but cost a bigger record, garbage collection per departed device, and merge surface that two Macs do not need |
| 45 | A note arriving for the first time is seeded with the sender's placement | There is no local placement to preserve yet, and the sender's frame is better information than whatever corner Stickies would otherwise choose. From then on the placement belongs to the receiving Mac |
| 46 | Placement is preserved by `SyncService`, not by `MergeDecision` | The first attempt put it in the merge rules, where `local.note` comes from the replica's newest *retained* version — and since a move deliberately retains no version, that geometry is stale by design. It reinstated the very positions it was meant to protect. Placement lives in the container, and the service is the only layer that can see it; the engine decides which content wins and nothing about where it goes |
| 47 | Migration 3 recomputes digests from retained history at open, rather than leaving them stale | Splitting geometry out of the appearance digest invalidates every stored hash. Left stale, the first scan reports every note as edited, and two Macs both doing that bump their own counter on every note and then conflict over all of them at once — a conflict copy of the entire container, on upgrade |
| 36 | A tombstone row carries no content of its own | The version recorded before the deletion already holds it, and duplicating it would double the storage for every deleted note. `newestRecoverableVersion` skips deletions to find it |

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
    ContainerWatcher.swift   FSEvents over the container subtree.
  SyncEngine/             Replication. Knows nothing of Macs or containers (#29).
    Database.swift           Thin wrapper over the system SQLite (#30).
    Schema.swift             Numbered, append-only migrations (#35).
    NoteDigest.swift         Separate content and window-state digests (#31).
    VersionVector.swift      Per-note causality; ordering without clocks (#4).
    Replica.swift            Reconciles notes against belief; history, tombstones, integration.
    SyncRecord.swift         One note version as it travels.
    DeviceManifest.swift     What a Mac claims to hold, without the content.
    SyncTransport.swift      The transport seam, and FolderTransport (#6).
    MergeDecision.swift      Deterministic resolution and conflict copies (#37-#40).
  StickiesSyncKit/        Composition root: the only place store and engine meet (#41).
    SyncConfiguration.swift  Persisted sync-folder setting.
    SyncService.swift        One pass: read, reconcile, pull, apply, integrate, publish.
  stickiesctl/            CLI. Presentation only — no logic worth testing lives here.
    StickiesCTL.swift        Command tree.
    CLISupport.swift         Shared --home option, table rendering, stderr reporting.
    DoctorCommand.swift      Text and JSON rendering of a ContainerReport.
    ListCommand.swift        One row per note.
    ExportCommand.swift      Writes a NoteArchive.
    ImportCommand.swift      Applies a NoteArchive; --replace and --dry-run.
    ScanCommand.swift        One reconcile, printing what changed.
    WatchCommand.swift       The same, driven by the watcher, until interrupted.
    HistoryCommand.swift     Retained versions, deleted notes included.
    RestoreCommand.swift     Puts a retained version back through the apply path.
    SyncCommand.swift        One pass or a watching loop over the shared folder.
    AgentCommand.swift       Installs, removes, and reports on the launchd agent.
Tests/
  StickiesFormatTests/    Unit and golden-file tests; Fixtures/ holds real captured files.
  StickiesStoreTests/     Probe, reader, writer, and watcher tests against a synthetic home.
  SyncEngineTests/        Digest, vector, and replica tests against an in-memory database.
  StickiesSyncKitTests/   Two simulated Macs over one shared folder; convergence.
```

**Dependency rule:** `StickiesFormat` imports nothing but Foundation and
CoreGraphics. `StickiesStore` imports `StickiesFormat`, AppKit, and CoreServices.
`SyncEngine` imports `StickiesFormat`, SQLite3, and CryptoKit — **not**
`StickiesStore` (#29). `stickiesctl` imports all three plus `ArgumentParser`.
Nothing imports upward, and no library target imports `ArgumentParser`.

The store and the engine never meet except in the CLI, where
`ContainerOptions.reconcile` reads a snapshot from one and hands its notes to the
other. That join is four lines, and keeping it that small is what will let
Milestone 4's agent drive the same two halves from a transport.

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

**Window position and z-order are best-effort, and the trigger is now known.**
Milestone 2 recorded this as "seen once, not reproducible" — that was wrong, and
only looked random because a second Mac was not yet in play. Measured on
2026-08-18 across a 2560×1440 Mac and a 1512×982 one: opening Stickies on the
smaller display clamps notes whose frames lie outside it, and **rewrites some of
them to disk** — `{{8, 1110}}` became `{{8, 749}}` while `{{2000, 1000}}` was left
alone, and z-orders shifted. A partial, inconsistent rewrite rather than a uniform
clamp.

The consequence was not cosmetic. Those rewrites read as ordinary window-only
changes, so they replicated: the larger Mac adopted the smaller Mac's clamped
layout, and since the clamped frames fit the larger screen nothing bounced back.
The steady state was that every Mac's layout collapsed to the smallest display in
the set, re-triggered whenever a note was repositioned on a larger one — merely
opening Stickies on a laptop rearranged the desktop Mac's notes.

That is why geometry is now machine-local (#44). Stickies still rewrites frames
whenever it likes; the difference is that nothing downstream cares.

## The replica

`~/Library/Application Support/StickiesSync/replica.sqlite3`, in WAL mode with
foreign keys on. Disposable in the sense that deleting it loses sync history and
version history but never a note — the notes live in Stickies.

```sql
device           (singleton, device_id, name)              -- one row, ever
notes            (sticky_id PK, content_hash, state_hash,
                  is_deleted, updated_at)
version_vectors  (sticky_id, device_id, seq)               -- PK (sticky_id, device_id)
note_versions    (sticky_id, device_id, seq, archive,
                  is_deletion, recorded_at)                -- PK (sticky_id, device_id, seq)
```

Key properties the schema encodes:

- **Content and appearance are hashed separately** (#31), which is what makes
  "this note only moved" expressible at all.
- **`device_id` is written once and never rewritten.** Every version vector in
  the history refers to it, so regenerating it would orphan the lot.
- **Vectors and versions cascade from `notes`**, so a note cannot leave history
  or counters behind.
- **`archive` is NULL exactly for a deletion** (#36). Recovery walks back to the
  newest version that has one.
- **`updated_at` is informational.** Ordering between Macs comes from vectors,
  never from these timestamps (#4). They order the history *within* one Mac,
  which is why they are ISO 8601 strings that sort lexicographically.

## Detecting a change

```
ContainerWatcher       FSEvents on the subtree  -> "something changed" (coalesced)
        |
StickiesReader.read()  container                -> StickiesSnapshot
        |
Replica.reconcile()    snapshot.notes           -> [NoteChange], recorded atomically
        |
ScanCommand / WatchCommand                      -> one line per change
```

The watcher reports only *that* something changed, never what. Working out what
changed needs the whole container anyway, so per-file event details would be
effort spent on information the next stage discards.

`reconcile` classifies each note by comparing digests against the replica's
belief:

| Situation | Reported as |
|-----------|-------------|
| Not in the replica | `.added` |
| Digests both match | nothing — the scan is silent |
| Content digest differs | `.edited`, `contentChanged` |
| Only the state digest differs | `.edited`, `isWindowStateOnly` |
| In the replica, tombstoned, now on disk | `.reappeared` |
| In the replica, not on disk, not yet tombstoned | `.deleted` |

Every reported change bumps this Mac's counter in the note's vector and appends a
retained version, inside one transaction with the classification. Milestone 3
only ever increments the local counter, since every change it can see originated
here; merging a peer's vector is Milestone 4.

A tombstoned note stays tombstoned rather than being rediscovered on every later
scan — the deletion is reported exactly once.

## Syncing between Macs

Each Mac writes only its own subtree, so the service moving the files never has
to resolve anything (#6):

```
<sync folder>/devices/<device-id>/manifest.plist
<sync folder>/devices/<device-id>/records/<sticky-id>.plist
```

The manifest lists every note the Mac holds with its version vector but no
content, so a peer reads one small file and fetches only the records it is behind
on. Records are written before the manifest, so a peer reading mid-publish never
sees a manifest promising a record that has not landed.

One pass of `SyncService.syncOnce`:

```
read the container      -> StickiesReader
reconcile               -> Replica: record what this Mac did since last time
for each peer manifest
  for each entry        -> compare vectors; fetch the record only if behind
                        -> MergeDecision.resolve  (pure; both Macs agree)
apply everything at once -> ApplyCoordinator: ONE quit/relaunch of Stickies
integrate               -> Replica: adopt peers' versions under THEIR identity
publish                 -> transport
```

Two orderings matter. Applying is a single batch, so ten notes arriving cause one
blink rather than ten — the coalescing SPEC.md promises. And integration happens
only *after* the container has taken the write, so a refused or failed apply
never leaves the replica claiming notes that were never written.

### Resolving one note

| Vectors | Outcome |
|---------|---------|
| Never seen | Adopt the peer's record as-is |
| Equal, or local descends remote | Nothing |
| Local is an ancestor | Adopt; the note takes the remote vector |
| Concurrent, one side a deletion | The edit wins, no copy (#40) |
| Concurrent, both have content | Later writer keeps the identifier; the loser becomes a conflict copy (#37, #38, #39) |

Whatever is adopted keeps *this* Mac's window placement (#44, #46). Only a note
arriving for the first time takes the sender's frame, because there is nothing
local to preserve (#45).

On any concurrent resolution the surviving note takes the *merged* vector. That
is what stops the two Macs from rediscovering the same conflict on every pass.

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
  The same is true of retained note versions, at twenty per note.
- **A window move still costs a full retained version.** `isWindowStateOnly`
  distinguishes the change for a caller, but the version row stores the whole
  note either way, so a note dragged around repeatedly consumes its twenty
  versions on positions rather than edits. Storing state-only deltas would fix it
  and is not worth the complexity until something demonstrates the need.
- **An import does not update the replica; the next scan does.** `restore` and
  `sync` both reconcile themselves, but `import` does not, so a change applied by
  `import` is attributed to this Mac when the next scan notices it. Correct for a
  hand-run import, which really did originate here.
- **A sync pass reads and rewrites every record it publishes.** There is no
  incremental publish: a Mac with a thousand notes serializes a thousand records
  each pass, even though the transport skips writing the unchanged ones. Fine at
  the scale Stickies is used at, and the place to fix it is `localRecords`.
- **Nothing is encrypted yet.** Anything with read access to the sync folder can
  read every note, and could publish a `devices/` subtree of its own and have it
  believed. Milestone 5 is what closes both.
- **A peer that vanishes is never forgotten.** Its `devices/<id>/` subtree stays
  in the folder and its counters stay in every vector. Harmless but untidy, and
  there is no `forget-device` command.
- **Convergence has been verified between two simulated Macs on one machine, not
  between two real ones.** The test pair shares a filesystem and a clock source;
  real Macs will not. What that setup cannot exercise: clock skew changing the
  conflict tiebreak, iCloud Drive or Syncthing delaying or reordering file
  arrival, and a Mac whose Stickies is running during an apply.
- **`watch` holds one replica for its lifetime and reopens nothing.** If the
  database is deleted or replaced underneath a running watch, it keeps writing to
  the old file handle until restarted.
- **The FSEvents tests are the only timing-dependent tests in the suite.** They
  wait on a semaphore with a ten-second deadline rather than sleeping, but they
  do depend on a real system service delivering events.
