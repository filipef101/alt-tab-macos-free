# PhantomWindowDetector — Specs

## Summary

`PhantomWindowDetector` decides whether a window is a **phantom** — present in macOS APIs (AX returns it
as a live window with a valid `CGWindowID`) but not something the app means to show the user, so AltTab
shouldn't offer it as a switch target. The pixel content may be absent, black, or anything; that's the
symptom, not the definition. Producers: alpha=0 Outlook reminders (#5170/#5448), `orderOut:` /
`show:false` Electron windows (Codex/Slack #5714, Joplin #5495, Sprig #5496), WeChat/Teams/DingTalk
hidden windows (#5508). Extracted as a pure kernel from `Window` / `Applications` so the "is this a
phantom?" decision is unit-testable without CGS/AX.

A phantom is read on **two orthogonal CGS axes**:

- **Space assignment** (`cgWindowId.spaces()` → `CGSCopySpacesForWindows(…, .all, …)`) — which Space a
  window *belongs to*. `orderOut:` / `setAlphaValue:0` does **not** un-assign it.
- **On-screen membership** (`CGSCopyWindowsWithOptionsAndTags` with vs. without the `.invisible1/.invisible2`
  bits) — the `inVisibleList` (excludes the invisible tags) vs `inAllList` (includes them) pair.

They're independent, which gives two strengths of phantom:

1. **Strong** — WID missing from *both* CGS lists; CGS evicted it entirely, so `spaceIds` comes back `[]`.
2. **Weak** — WID in `inAllList` but not `inVisibleList`; CGS still tracks it (so `spaceIds` is
   **non-empty**) but tags it invisible. **Non-empty `spaceIds` therefore does not imply visibility.**

## The two facts, and what they replaced

There are exactly two phantom families, and the batched WindowServer query AltTab already issues states both
of them outright rather than by inference:

| family | producer | the fact |
|---|---|---|
| ordered out | Electron `show:false` (#5714, #5495, #5496) | the ordered-in bit is clear |
| alpha 0 | Outlook reminders (#5170, #5448) | `alpha == 0` |

The split is real: accessibility does NOT see the alpha-0 phantom (it lists it as an ordinary
`AXStandardWindow`), and only the ordered-out one is absent from `kAXWindows`.

What these replace is a chain of stand-ins, each of which cost a regression. "Absent from every Space" stood
in for ordered-out, which is also what a live window looks like when our Space data is wrong (#5791, #5954).
"CGS tagged it invisible" stood in for alpha-0, which is also what CGS says about a freshly reopened Electron
window for seconds after it is on screen and focused (#5849) — a case that needed an explicit FOCUS
exemption, threading the MRU into a pure kernel, and now needs none, because such a window is ordered in.

Both CGS lists stay, and neither is redundant. `inAllList` answers the one question the WindowServer query
cannot: whether CGS has any record of the wid. `inVisibleList` is kept as a CLEARING signal only — it can
exempt a window, never flag one — because the ordered-in bit is maintained by 815/816, the batched query and
the Space deltas, and a window whose Space becomes current again need not produce any of them. Dropping it
was tried and hid a fullscreen window's own tile on the summon right after switching back to its Space.

## Two entry points

- **`syncVerdict(s, app)`** — synchronous, cheap, runs on every show (`Window.recomputeIsPhantom`). Has
  only local facts, so it can observe only the strong signal. **Monotonic for the weak signal**: it ORs
  the strong signal onto the current `s.isPhantom`, so it may raise the flag but never clears it on a
  non-empty Space. A weak-signal phantom keeps its Space, which this path can't see; clearing there would
  clobber `cgsVerdict`'s verdict on every show and the phantom would reappear on every summon (the #5714
  bug). **Exception — `isTabbed` clears**: AX tab detection is authoritative but lands after a window is
  first seen, so an inactive tab is briefly flagged phantom (empty `spaceIds`, not-yet-known tabbed); once
  AX confirms the tab this path un-flags it (a real phantom is never part of an AXTabGroup). Without it,
  the monotonic OR left inactive tabs stuck phantom and "separate window per tab" showed one per app.
- **`cgsVerdict(s, app, inVisibleList, inAllList, visibleSpaceIds)`** — authoritative, runs ~250ms
  post-show off-main (`Applications.refreshIsPhantom`) with the two CGS lists. Knows both signals; owns
  the full verdict, including clearing. Disambiguation order (first match wins):
  1. minimized / hidden app / tabbed → not a phantom (legitimate; CGS may list none of these in any Space —
     a background tab especially — so they must clear *before* the strong signal or they'd trip it)
  2. not in `inAllList` → **phantom** (strong)
  3. in `inVisibleList` → not a phantom (currently rendered)
  4. non-empty `spaceIds` ∩ `visibleSpaceIds` == ∅ → not a phantom (other-Space window)
  5. else → **phantom** (weak: alpha=0 / `orderOut:` on a visible Space)

## Test scenarios

Mirrors `PhantomWindowDetectorTests.swift` 1:1. Each test starts from an all-permissive baseline window
and flips the knobs it exercises.

### A. syncVerdict (synchronous)
- **testEmptySpacesIsPhantom** — no Space + not tabbed/minimized/hidden, and not on screen → flagged phantom.
- **testNonEmptySpacesAloneNotRaised** — a window with a Space is not flagged.
- **testNeverClearsAPhantom** — already a phantom + non-empty `spaceIds` → **stays a phantom** (the #5714
  invariant: the synchronous path never clears a latched verdict).
- **testTabbedWithEmptySpacesNotRaised** — empty Space but tabbed → not flagged.
- **testTabbedClearsAStalePhantom** — already a phantom + empty Space but now tabbed → **cleared** (the
  inactive-tab exemption, which is the one thing that may clear synchronously).
- **testMinimizedWithEmptySpacesNotRaised** — empty Space but minimized → not flagged.
- **testHiddenAppWithEmptySpacesNotRaised** — empty Space but app hidden → not flagged.

### B. cgsVerdict (authoritative)
- **testMissingFromAllListsIsPhantom** — missing from the all-Space CGS list → phantom (Joplin / Sprig).
- **testOrderedInIsNotPhantom** — the WindowServer is showing it → not a phantom.
- **testOrderedOutOnVisibleSpaceIsPhantom** — listed, on a visible Space, opaque, and NOT ordered in → the
  `orderOut:` / `show:false` family.
- **testOtherSpaceWindowIsNotPhantom** — ordered out because its Space is not among the visible ones.
- **testMinimizedIsNotPhantom** — ordered out because it is minimized.
- **testHiddenAppIsNotPhantom** — ordered out because its app is hidden.
- **testTabbedIsNotPhantom** — ordered out because it is a background tab.
- **testTabbedMissingFromAllListsIsNotPhantom** — tabbed but missing from the CGS list (the real inactive
  background tab, whose `spaceIds` are backfilled from its active sibling): the legitimate-window exemption
  beats the strong signal, or the tab disappears.
- **testMinimizedMissingFromAllListsIsNotPhantom** — same exemption for a minimized window CGS dropped.

### C. The two exact facts, each against the case its stand-in got wrong
- **testAlphaZeroIsPhantomEvenOnScreen** — genuinely ordered in, on a visible Space, and still invisible to
  the user. Only alpha says so, on both entry points; no accessibility signal can ever catch this family.
- **testOnScreenWindowIsNeverPhantomWhateverCgsSaysAboutItsSpaces** — #5849, on both entry points. This used
  to need the focus exemption; the ordered-in bit settles it as a fact about the window rather than about
  where the user is looking.
- **testOnScreenExemptionDoesNotResurrectAWindowCgsForgot** — the exemption is not unconditional: a wid CGS
  dropped from every list is gone, and a stale ordered-in bit must not bring it back (#5714).
