# StickiesSync

Automatic synchronization for Apple's Stickies app. Stickies has no sync of its
own — a note written on one Mac exists only on that Mac — so StickiesSync runs
as a background agent that keeps notes consistent across several Macs owned by
the same person, over a transport the user chooses and controls rather than a
proprietary cloud. It models each sticky as an individual object with an
identity and a history, which is what makes per-note conflict resolution and
deleted-note recovery possible where a directory copy would only overwrite.

Built for its author's own Macs. See [SPEC.md](SPEC.md) for what it is meant to
do and [ARCHITECTURE.md](ARCHITECTURE.md) for how it is built.

## Features

Milestones 0 through 4 are complete: notes sync between Macs over a shared
folder, with version history, deleted-note recovery, and visible conflict copies.
The remaining items are encryption and a menu-bar app, tracked in
[ROADMAP.md](ROADMAP.md).

- **Health check** *(built)* — `stickiesctl doctor` locates the Stickies
  container, reports whether it can be read, counts note packages, checks that
  the window-state file parses, flags entries it cannot classify, notices a
  surviving pre-sandbox database, and reports whether Stickies is running and
  frontmost.
- **Reading notes** *(built)* — `stickiesctl list` shows every note with its
  size, screen position, colour, z-order, floating and translucency flags, and
  first line of text. Anything in the container that could not be read is
  reported rather than skipped.
- **Portable export** *(built)* — `stickiesctl export` writes a versioned
  archive carrying each note's package bytes and window state verbatim, verified
  byte-identical to the container it came from.
- **Per-note change detection** *(built)* — `stickiesctl watch` reports each
  note that is added, edited, moved, or deleted as it happens, telling a text
  edit apart from a window move. A change to one sticky is one change, not a
  whole-directory diff.
- **Version history and deleted-note recovery** *(built)* — every change retains
  a version; `stickiesctl history` lists them and `restore` puts one back, a
  deleted note included.
- **Safe write-back** *(built)* — `stickiesctl import` quits Stickies, writes,
  and relaunches it, because Stickies overwrites its files from memory while
  running. It refuses while Stickies is frontmost, never relaunches an app you
  closed yourself, copies the container to a backup first, and restores that
  backup if the write fails.
- **Fidelity** *(built)* — text, rich formatting, embedded attachments, all four
  colours, floating and translucency all survive a write, and all of them sync.
- **Each Mac keeps its own layout** *(built)* — window positions and z-order are
  deliberately *not* synced. A frame that fits a 27-inch display is off the edge
  of a laptop, and Stickies rewrites frames it does not like; replicating that
  made every Mac's layout collapse to the smallest screen. A note arriving
  somewhere new is placed where the sender had it, and is yours to move after
  that.
- **Cross-Mac sync** *(built)* — `stickiesctl sync --watch` exchanges notes
  through a shared folder. Each Mac writes only its own subtree of it, so iCloud
  Drive or Syncthing never has to resolve anything itself.
- **Batching** *(built)* — every incoming change is applied in one batch, so ten
  arriving notes cause one blink rather than ten.
- **Conflict copies** *(built)* — when the same note changed on two Macs, the
  later edit keeps the note and the other becomes a second sticky in a
  distinctive colour. Both Macs derive the same copy independently.
- **Runs in the background** *(built)* — `stickiesctl agent install` sets up a
  `launchd` job that syncs at login.
- **Choice of transport** — a shared directory today, which covers iCloud Drive,
  Syncthing, Dropbox, or an SMB mount without code changes; LAN peer-to-peer and
  object stores later.
- **End-to-end encryption**, so a transport you do not control never sees
  plaintext. **Not built yet** — today anything that can read the sync folder can
  read every note.

## Tech stack

- **Language and build:** Swift 6, SwiftPM, deployment target macOS 14.
  `swift-argument-parser` is the only third-party dependency.
- **Format layer:** Foundation and CoreGraphics — RTFD packages held as bytes,
  window state as XML property lists.
- **System integration:** AppKit for application run state and rich-text
  reading.
- **Local state:** SQLite (the system library, no wrapper package) at
  `~/Library/Application Support/StickiesSync/replica.sqlite3`; SHA-256 digests
  via CryptoKit; FSEvents for change notification.
- **Tests:** swift-testing, 170 tests, including golden-file tests against a real
  `.SavedStickiesState` and a byte-for-byte export→wipe→import round trip.

## Setup

Requires macOS and the Swift 6 toolchain (Command Line Tools are enough; full
Xcode is not needed until the optional menu-bar app).

```bash
git clone https://github.com/jasonli-git/stickies-sync.git
cd stickies-sync
make check
make doctor
```

Run `make test` rather than `swift test` — on a Mac with Command Line Tools and
no Xcode, SwiftPM does not wire up swift-testing on its own, and the Makefile
injects the missing toolchain paths. See limitation #11 in
[ARCHITECTURE.md](ARCHITECTURE.md).

`stickiesctl doctor` output on a Mac with no stickies yet:

```
StickiesSync doctor

  ✔  Stickies container             /Users/you/Library/Containers/com.apple.Stickies/Data/Library/Stickies/
  !  Note packages                  none — there are no stickies to sync yet
  ✔  Unrecognised entries           none
  ✔  Saved window state             parses as a plist array of 0 entry/entries
  ✔  State/notes agreement          0 note(s), 0 state entry/entries
  ✔  Legacy Stickies database       not present
  ✔  Stickies process               not running — reads and writes are both safe
  ✔  StickiesSync state directory   writable at /Users/you/Library/Application Support/StickiesSync/

Result: warning
```

Add `--json` for machine-readable output. Warnings do not fail the run; failures
exit non-zero.

Listing, exporting, and importing notes:

```bash
swift run stickiesctl list
swift run stickiesctl export -o notes.plist
swift run stickiesctl import notes.plist --dry-run
swift run stickiesctl import notes.plist
```

`export` writes an XML property list holding every note's package bytes and
window state unchanged. `import` writes such an archive back: it quits Stickies
first, since Stickies overwrites its files from memory while running, then
relaunches it — but never while Stickies is frontmost, because that means you are
typing in it. The container is copied to
`~/Library/Application Support/StickiesSync/Backups/` before every write and
restored if the write fails. Add `--replace` to delete notes the archive does not
contain, or `--dry-run` to see what would change.

All three commands report anything in the container they could not read on
standard error, and exit non-zero when that would mean losing a note.

Tracking changes and recovering notes:

```bash
swift run stickiesctl scan
swift run stickiesctl watch
swift run stickiesctl history
swift run stickiesctl restore <sticky-id>
```

`scan` records what changed since the last scan; `watch` does the same
continuously as you type in Stickies, telling a text edit apart from a window
move. `history` lists the versions retained per note, deleted ones included, and
`restore` puts one back through the same safe apply path as `import`.

Syncing with another Mac:

```bash
swift run stickiesctl sync --folder ~/Library/Mobile\ Documents/com~apple~CloudDocs/StickiesSync
swift run stickiesctl sync --watch
swift run stickiesctl agent install
swift run stickiesctl agent status
```

Point every Mac at the same shared folder — any directory another service keeps
in step, such as iCloud Drive or a Syncthing folder. The folder is remembered
after the first `--folder`. Each Mac writes only its own subtree, so the service
moving the files never has to resolve anything itself.

Every command takes `--home <path>` to read a synthetic container instead of the
real one, which is how the test suite exercises them.

**No special permission is needed.** Reading Stickies' container was measured to
require no Full Disk Access grant on macOS 26.6.1 — see decision #19 in
[ARCHITECTURE.md](ARCHITECTURE.md). StickiesSync still cannot be sandboxed or
shipped through the Mac App Store, because the sandbox forbids reading another
application's container regardless.

## Status

v0.5.1 — Milestones 0 through 4 of 7 complete. Notes sync between Macs, verified
between two real ones. Nothing on the wire is encrypted yet. Progress is in
[ROADMAP.md](ROADMAP.md); what shipped is in [CHANGELOG.md](CHANGELOG.md).
