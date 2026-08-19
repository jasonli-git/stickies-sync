# StickiesSync — Specification

Source of truth for scope. How it is built and why is in
[ARCHITECTURE.md](ARCHITECTURE.md); when things land is in
[ROADMAP.md](ROADMAP.md).

## Vision

An "iCloud for Stickies" that does not require a proprietary cloud backend.

Apple's Stickies app has no synchronization. A note written on one Mac exists
only on that Mac. StickiesSync is a background utility that keeps Stickies
consistent across several Macs owned by the same person, moving individual notes
— their text, formatting, colour, and appearance — over a transport the user
chooses and controls. Where each note *sits* stays with the Mac it was arranged
on; see F2a.

It understands *notes*, not files. A whole-directory copy cannot tell which of
two divergent copies of a note is newer, cannot merge, and cannot recover a note
deleted by accident. Modelling each sticky as an object with an identity and a
history is what makes intelligent conflict handling possible, and it is the
entire reason this project exists rather than a `rsync` cron job.

## Core principles

1. **Never lose a note.** Every write to the Stickies container is preceded by
   a backup. Conflicts produce a visible extra copy rather than a silent
   choice. Deletions are tombstones with recoverable content, not erasures.
2. **Stickies is the source of truth; StickiesSync is a courier.** The utility
   never becomes the place notes live. If StickiesSync is uninstalled, the user
   is left with a normal, working Stickies.
3. **Read freely, write rarely and deliberately.** Reads are cheap and safe.
   Writes require the app to be closed and are therefore batched, debounced,
   and visible. When in doubt, do not write.
4. **Causality over clocks.** Two Macs disagree about the time. Ordering is
   established by version vectors, never by comparing wall-clock timestamps.
5. **The transport knows nothing about notes.** Any medium that can carry
   opaque files between two Macs — a synced folder, a LAN socket, an object
   store — is a valid backend, and swapping one for another changes no
   note-handling code.
6. **Fail visibly, degrade to inaction.** An unrecognised format, a permission
   the user has not granted, or an unparseable peer record stops
   synchronization and says so. It never guesses and writes.

## User experience

StickiesSync runs as a `launchd` agent with no window. The user's day-to-day
experience is that Stickies simply matches across their Macs.

- **Local edits propagate on their own.** The user types into a sticky on Mac A.
  Within seconds of them stopping, the change is on the transport.
- **Remote edits arrive with a blink.** Because Stickies overwrites its files
  from memory while running, applying a remote change requires quitting
  Stickies, writing, and relaunching it. Notes vanish and reappear in place,
  once, for about a second. Pending changes are coalesced so ten incoming notes
  cause one blink, not ten.
- **The blink never interrupts.** StickiesSync will not quit Stickies while it
  is the frontmost application — that means the user is typing in it. Changes
  wait until they look away.
- **Conflicts become a second sticky.** When the same note was edited on two
  Macs since they last spoke, one version stays in place and the other appears
  as a new sticky marked as a conflict copy. The user resolves it by reading
  both and deleting one. Nothing is decided silently.
- **Each Mac keeps its own layout.** Where a note sits is not synchronized. A
  frame that suits a 27-inch display is off the edge of a laptop, and Stickies
  rewrites frames it dislikes without being asked, so replicating position drags
  every Mac's layout down to the smallest screen in use. A note arriving somewhere
  new is placed where the sender had it, and is the receiving Mac's to arrange
  after that. Colour, translucency and float-on-top do travel — nothing but the
  user ever changes those.
- **Deleted notes are recoverable** from the command line for as long as history
  is retained.
- **Nothing happens without permission.** The utility requires Full Disk Access
  to read another application's container and says so plainly when it lacks it.

The v1 interface is `stickiesctl`, a command-line tool, plus the background
agent. A menu-bar status item is desirable but not required for the product to
be complete.

## Functional requirements

| # | Requirement |
|---|-------------|
| F1 | Enumerate the notes in the local Stickies container as individual objects with stable identities |
| F2 | Replicate per-note text, rich formatting, embedded attachments, colour, translucency, and float-on-top. These describe the note itself and are the same on every Mac |
| F2a | Capture window frame, expanded/collapsed state, multi-screen frames, and z-order, but treat them as **belonging to the Mac they were set on** rather than to the note. A note arriving somewhere for the first time is placed where the sender had it; from then on each Mac keeps its own layout, and moving a window never affects another Mac |
| F3 | Detect a change to any single note without rescanning or resending the others |
| F4 | Apply a remote note to the local container without corrupting Stickies' state, and without losing concurrent local work |
| F5 | Back up the container before every write, and roll back if a write fails partway |
| F6 | Establish ordering between two Macs' versions of a note without relying on clock agreement |
| F7 | Detect concurrent edits and surface both versions to the user |
| F8 | Propagate deletions as tombstones, and retain deleted content for recovery |
| F9 | Retain prior versions of each note and restore any of them on request |
| F10 | Operate while offline and reconcile on reconnection, with no ordering assumptions about which Mac comes back first |
| F11 | Support more than two Macs |
| F12 | Move note data over a replaceable transport, the first being a shared directory |
| F13 | Encrypt note data end-to-end, so a transport the user does not control never sees plaintext |
| F14 | Refuse to operate, loudly, against a Stickies data format it does not recognise |

## Non-goals for v1

Explicitly out of scope. Each is a thing this project could grow into and
deliberately will not, because v1 is a personal-use utility for one person's
Macs.

- **iOS, iPadOS, or web access.** Stickies is a Mac application; there is
  nothing to sync to.
- **Notes.app, Reminders, or any other note store.** Stickies only.
- **Mac App Store distribution.** Reading another application's container needs
  Full Disk Access, which a sandboxed app cannot have. This closes the door on
  the App Store permanently, not just for v1.
- **Signing, notarization, an auto-updater, a crash reporter, or an onboarding
  wizard.** v1 is built from source by its user.
- **Real-time collaborative editing.** No character-level merge of rich text.
  Two people typing in the same note at the same moment is not the target case;
  one person on two Macs is.
- **Sharing notes with other people.** Single user, multiple machines.
- **Syncing Stickies' application preferences** — default note colour, default
  window translucency, window-menu ordering. Notes only.
- **A graphical interface as a completion requirement.** Desirable, scheduled,
  not load-bearing.
- **macOS versions other than those verified.** The format is undocumented and
  Apple may change it. Supporting a version means having tested against it.

## Philosophy on the parts that are easy to build wrong

**The write path is the whole problem.** Stickies holds every note open as an
autosaving `NSDocument` and has no mechanism for noticing that a file changed
underneath it. A file written while Stickies runs is overwritten by the next
autosave, and may corrupt the shared state file. Every design here follows from
that: the reason for the quit/relaunch cycle, the reason writes are batched, the
reason the frontmost check exists, and the reason a backup precedes every write.
Any future contributor tempted to "just write the file" should read this
paragraph twice.

**Timestamps are not ordering.** The tempting implementation of conflict
resolution — compare modification dates, newest wins — silently destroys work
whenever two Macs' clocks disagree, which is always, by some amount. Version
vectors cost one small table and remove the entire class of bug.

**A conflict is a fact, not a failure.** The system's job when two versions
diverge is to make both visible, not to be clever. An automatic merge of rich
text that is right 95% of the time is worse than a conflict copy that is right
always, because the 5% is silent.

**The format is borrowed, not owned.** StickiesSync reads a private, unversioned
format belonging to someone else's application. It must therefore detect the
unfamiliar and refuse, rather than write a best guess into the user's notes. An
unrecognised key in the state file is a stop signal.
