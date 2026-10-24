import Foundation

/// Detects whether a window is a "phantom": present in macOS APIs (AX hands it back with a valid
/// `CGWindowID`) but not something the app actually means to show the user — alpha=0 Outlook reminders,
/// `orderOut:` / `show:false` Electron windows, WeChat/Teams hidden windows, etc. The pixel content may
/// be absent, black, or anything; what matters is that AltTab shouldn't offer it as a switch target.
///
/// **Two exact WindowServer facts, not two inferences.** There are exactly two phantom families, and the
/// batched query AltTab already issues states both of them outright:
///
/// | family | producer | the fact |
/// |---|---|---|
/// | ordered out | Electron `show:false` (#5714, #5495, #5496) | the ordered-in bit is clear |
/// | alpha 0 | Outlook reminders (#5170, #5448) | `alpha == 0` |
///
/// Both were measured on macOS 26 by driving the two shapes on a probe's own windows. The split is real:
/// AX does NOT see the alpha-0 phantom (it lists it as an ordinary `AXStandardWindow`), and only the
/// ordered-out one is absent from `kAXWindows`.
///
/// What this replaces is a chain of inferences that each cost a regression: "absent from every Space" as a
/// stand-in for ordered-out (which is also what a live window looks like when our Space data is wrong,
/// #5791 / #5954), "CGS tagged it invisible" as a stand-in for alpha-0 (which is also what CGS says about a
/// freshly reopened Electron window for seconds after it is on screen and focused, #5849 — a case that
/// needed an explicit focus exemption, and now needs none, because such a window is ordered IN).
///
/// Pure kernel over the test-constructible `WindowState` + `ApplicationState` records (no SkyLight, no
/// `@testable`). Two entry points, by how much the caller knows:
enum PhantomWindowDetector {
    /// Synchronous, cheap — evaluated on every read (the derived `Window.isPhantom`). It sees the two exact
    /// facts, plus the latched CGS verdict fed in through `s.isPhantom` (owned by
    /// `Window.applyCgsPhantomVerdict`).
    ///
    /// EXCEPTION — `isTabbed` clears the flag. AX tab detection is authoritative but lands AFTER a window
    /// is first seen, so an inactive tab is briefly Space-less and ordered out before `TabGroup.updateState`
    /// runs. A real phantom is never part of an AXTabGroup, so clearing is safe. Without this the monotonic
    /// OR left inactive tabs stuck phantom, so "Group tabs: separate window for each tab" showed only the
    /// active tab (one per app).
    static func syncVerdict(_ s: WindowState, _ app: ApplicationState,
                            isOrderedIn: Bool, alpha: Float) -> Bool {
        if s.isTabbed { return false }
        // Exact, and the only signal for this family: AX cannot see an alpha-0 window as anything unusual.
        if alpha == 0 { return true }
        // Exact, and the reason the Space-based inference below can no longer hide a live window: whatever
        // CGS says about its Spaces, a window the WindowServer is still showing on screen is not a phantom.
        if isOrderedIn { return false }
        return s.isPhantom || (s.spaceIds.isEmpty && !s.isMinimized && !app.isHidden)
    }

    /// Authoritative — runs ~250ms post-show off-main (`Applications.refreshWindowsViaWindowServer`) with
    /// the all-Space CGS list. Owns the full verdict, including clearing. Disambiguation order is in
    /// `PhantomWindowDetectorSpecs.md`.
    ///
    /// The two CGS lists stay, and are NOT redundant with the WindowServer bits. `inAllList` answers the one
    /// question the query cannot: whether CGS has any record of the wid at all. `inVisibleList` is kept as a
    /// CLEARING signal only — it can exempt a window, never flag one — because it corrects cases the
    /// ordered-in bit does not reach in our model: the bit is maintained by 815/816, the batched query and
    /// the Space deltas, and a window whose Space becomes current again is not guaranteed to produce any of
    /// them. Dropping it was tried and put a fullscreen window's own tile behind a phantom flag on the
    /// summon right after switching back to its Space (generator seed 34).
    static func cgsVerdict(_ s: WindowState, _ app: ApplicationState,
                           inVisibleList: Bool, inAllList: Bool, isOrderedIn: Bool, alpha: Float,
                           visibleSpaceIds: [UInt64]) -> Bool {
        // Legitimate windows CGS may not list in any Space — an inactive tab (CGS lists no background tab,
        // so its spaceIds are backfilled from the active sibling), a minimized window, a hidden app's
        // window. They must be cleared BEFORE anything else, else "absent from every Space" flags them
        // phantom even though they're real (the inactive-tab / fullscreen-tab disappearance). A true phantom
        // is none of these. Mirrors `syncVerdict`, which exempts a tab from its first line.
        if s.isTabbed || s.isMinimized || app.isHidden { return false }
        // CGS dropped the wid from every Space AND every list: gone, whatever anything else says.
        if !inAllList { return true }
        if alpha == 0 { return true }
        // On screen by either account: the WindowServer's own bit, or CGS listing it as visible.
        if isOrderedIn || inVisibleList { return false }
        // Ordered out, and legitimately so: the window is parked on a Space that is not on screen.
        if !s.spaceIds.isEmpty && !s.spaceIds.contains(where: { visibleSpaceIds.contains($0) }) { return false }
        // Ordered out with no reason to be: the `orderOut:` / `show:false` family.
        return true
    }
}
