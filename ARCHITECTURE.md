# StickiesSync — Architecture

How the system is built and why. [SPEC.md](SPEC.md) is the source of truth for
what it should do; this document covers the structure chosen to do it, the
decisions behind that structure, and what is known to be wrong or unproven. As
of Milestone 0 the built surface is small — a format layer, a container probe,
and `stickiesctl doctor` — and everything below distinguishes what exists from
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
- **Boundaries:** three of them. `StickiesFormat` knows the on-disk format and
  nothing about the filesystem. `StickiesStore` knows this Mac and nothing
  about synchronization. The sync engine (Milestone 3) will know about
  replication and nothing about Macs or networks.
- **External dependencies:** exactly one, `swift-argument-parser`. Everything
  else is Foundation and AppKit.
- **Permissions:** Full Disk Access, because reading another application's
  container requires it. This is the constraint that rules out sandboxing and
  therefore the Mac App Store.

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

## Module Layout

```
Sources/
  StickiesFormat/         The on-disk format. No I/O of any kind.
    StickyID.swift        Note identity; package-filename conversion.
    StickiesDirectory.swift  Path arithmetic over a container root; entry classification.
  StickiesStore/          This Mac: where the container is, and what state it is in.
    ContainerLocator.swift   Container, legacy database, and app-support paths from a home dir.
    StickiesApp.swift        Whether Stickies is running, and whether it is frontmost.
    ContainerProbe.swift     Reads observable facts into a ContainerReport.
    Diagnostics.swift        Judges a ContainerReport into pass/warn/fail diagnostics.
  stickiesctl/            CLI. Presentation only — no logic worth testing lives here.
    StickiesCTL.swift        Command tree.
    DoctorCommand.swift      Text and JSON rendering of a ContainerReport.
Tests/
  StickiesFormatTests/    Pure unit tests.
  StickiesStoreTests/     Probe tests against a synthetic home directory on a real filesystem.
```

**Dependency rule:** `StickiesFormat` imports nothing but Foundation.
`StickiesStore` imports `StickiesFormat` and AppKit. `stickiesctl` imports both
plus `ArgumentParser`. Nothing imports upward, and no library target imports
`ArgumentParser`.

`StickiesFormat` performs no filesystem access at all, which is why
`StickiesDirectory` takes a root `URL` rather than hiding behind a filesystem
protocol: tests hand it a fixture path and production hands it the real
container, and neither needs a test double.

The modules named in [ROADMAP.md](ROADMAP.md) — the sync engine, the transport,
the crypto layer, the menu-bar app — do not exist yet and have no placeholder
targets (#12).

## The Stickies data format

Everything here was established by inspecting Stickies 10.3 on macOS 26.6.1: the
application binary's symbol and string tables, its `Info.plist`, its
entitlements, and the container on this Mac. None of it is documented by Apple.

```
~/Library/Containers/com.apple.Stickies/Data/Library/Stickies/
  <UUID>.rtfd            one package per note: rich text plus attachments
  .SavedStickiesState    XML plist, an array of per-note window state
```

Verified:

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

Open, and answered by Milestone 1:

- The internal layout of an `.rtfd` package as Stickies writes it.
- **Whether per-note colour lives in the RTF document attributes or in
  `.SavedStickiesState`.** This decides whether colour can be read without
  parsing RTF.
- The exact on-disk spelling and value types of the state-dictionary keys.
- **Whether `.SavedStickiesState` is written continuously or only at quit.** If
  only at quit, window frames and z-order can only be read *after* a quit,
  making the quit cycle the trustworthy read path as well as the write path —
  which changes the watcher in Milestone 3 substantially.
- Whether Full Disk Access is genuinely required, measured with a binary that
  has not inherited some other process's grant.

`stickiesctl doctor` already reports the two observable signals that bear on
these: the count of entries it cannot classify, and any disagreement between the
number of note packages and the number of state entries.

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

## The write path

Not built. Milestone 2 owns it, and this section records the constraint it must
satisfy, because the constraint is a verified property of Stickies rather than a
plan.

Stickies reads its directory at launch and writes over it thereafter, from
memory, with no file-presenter behavior that would let it notice an external
edit. Anything written while it runs is lost at the next autosave, and a
concurrent write to `.SavedStickiesState` can corrupt state for every note at
once. The apply coordinator therefore has to:

1. Refuse to act while Stickies is frontmost — that means the user is typing.
2. Coalesce all pending remote changes into one quit/write/relaunch cycle.
3. Relaunch only if it was the one that quit Stickies, never resurrecting an app
   the user closed deliberately.
4. Back up the container before writing, and roll back on partial failure.

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
  precisely. If a future macOS instead returns an empty listing, doctor would
  report "no notes" on a Mac that has plenty. Milestone 1's permission
  measurement is where this gets confirmed either way.
- **Doctor counts state entries without reading them.** It checks only that
  `.SavedStickiesState` parses as an array, so a state file full of entries in a
  format we cannot understand still reports as healthy. Parsing the entries is
  Milestone 1.
