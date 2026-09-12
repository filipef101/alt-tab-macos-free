import XCTest

/// Pins the phantom-window decision (`PhantomWindowDetector`) against canonical `WindowState` /
/// `ApplicationState` snapshots, so the per-app real-user scenarios and the #5714 "never clears a
/// phantom" invariant are regression-proof. Group A covers the synchronous path (`Window.isPhantom`);
/// group B the authoritative CGS path; group C the two EXACT WindowServer facts that replaced the
/// inferences, each paired with the case it used to get wrong. See PhantomWindowDetectorSpecs.md.
final class PhantomWindowDetectorTests: XCTestCase {

    private func ws(isPhantom: Bool = false, isMinimized: Bool = false, isTabbed: Bool = false,
                    spaceIds: [UInt64] = []) -> WindowState {
        WindowState(id: "w", isPhantom: isPhantom, isWindowlessApp: false,
                    isFullscreen: false, isMinimized: isMinimized, isTabbed: isTabbed,
                    isOnAllSpaces: false, spaceIds: spaceIds, spaceIndexes: [],
                    lastFocusOrder: 0, creationOrder: 0, title: "Title")
    }

    private func appState(appIsHidden: Bool = false) -> ApplicationState {
        ApplicationState(pid: 0, bundleIdentifier: nil, localizedName: nil, isHidden: appIsHidden)
    }

    // MARK: - A. syncVerdict (synchronous)

    func testEmptySpacesIsPhantom() {
        XCTAssertTrue(PhantomWindowDetector.syncVerdict(ws(spaceIds: []), appState(),
            isOrderedIn: false, alpha: 1))
    }

    func testNonEmptySpacesAloneNotRaised() {
        XCTAssertFalse(PhantomWindowDetector.syncVerdict(ws(spaceIds: [1]), appState(),
            isOrderedIn: false, alpha: 1))
    }

    func testNeverClearsAPhantom() {
        // #5714 invariant: a phantom latched by cgsVerdict keeps a Space, and syncVerdict must not clear
        // it on the next show.
        XCTAssertTrue(PhantomWindowDetector.syncVerdict(ws(isPhantom: true, spaceIds: [4]), appState(),
            isOrderedIn: false, alpha: 1))
    }

    func testTabbedWithEmptySpacesNotRaised() {
        XCTAssertFalse(PhantomWindowDetector.syncVerdict(ws(isTabbed: true, spaceIds: []), appState(),
            isOrderedIn: false, alpha: 1))
    }

    func testTabbedClearsAStalePhantom() {
        // Regression: an inactive tab is transiently flagged phantom (empty spaceIds, before AX tab
        // detection runs). Once AX confirms it's tabbed, the synchronous path must CLEAR that stale
        // verdict — the monotonic-only version left it stuck, so "separate window per tab" dropped every
        // inactive tab and showed only the active one (one window per app).
        XCTAssertFalse(PhantomWindowDetector.syncVerdict(ws(isPhantom: true, isTabbed: true, spaceIds: []),
            appState(), isOrderedIn: false, alpha: 1))
    }

    func testMinimizedWithEmptySpacesNotRaised() {
        XCTAssertFalse(PhantomWindowDetector.syncVerdict(ws(isMinimized: true, spaceIds: []), appState(),
            isOrderedIn: false, alpha: 1))
    }

    func testHiddenAppWithEmptySpacesNotRaised() {
        XCTAssertFalse(PhantomWindowDetector.syncVerdict(ws(spaceIds: []), appState(appIsHidden: true),
            isOrderedIn: false, alpha: 1))
    }

    // MARK: - B. cgsVerdict (authoritative)

    func testMissingFromAllListsIsPhantom() {
        // Joplin / Sprig: CGS dropped the WID from every Space.
        XCTAssertTrue(PhantomWindowDetector.cgsVerdict(ws(spaceIds: []), appState(),
            inVisibleList: false, inAllList: false, isOrderedIn: false, alpha: 1, visibleSpaceIds: []))
    }

    func testOrderedInIsNotPhantom() {
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(spaceIds: [1]), appState(),
            inVisibleList: false, inAllList: true, isOrderedIn: true, alpha: 1, visibleSpaceIds: [1]))
    }

    func testOrderedOutOnVisibleSpaceIsPhantom() {
        // Codex / Slack: on the current visible Space, alive otherwise, but the WindowServer is not
        // showing it — the `orderOut:` / `show:false` family.
        XCTAssertTrue(PhantomWindowDetector.cgsVerdict(ws(spaceIds: [1]), appState(),
            inVisibleList: false, inAllList: true, isOrderedIn: false, alpha: 1, visibleSpaceIds: [1]))
    }

    func testOtherSpaceWindowIsNotPhantom() {
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(spaceIds: [2]), appState(),
            inVisibleList: false, inAllList: true, isOrderedIn: false, alpha: 1, visibleSpaceIds: [1]))
    }

    func testMinimizedIsNotPhantom() {
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(isMinimized: true, spaceIds: [1]), appState(),
            inVisibleList: false, inAllList: true, isOrderedIn: false, alpha: 1, visibleSpaceIds: [1]))
    }

    func testHiddenAppIsNotPhantom() {
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(spaceIds: [1]), appState(appIsHidden: true),
            inVisibleList: false, inAllList: true, isOrderedIn: false, alpha: 1, visibleSpaceIds: [1]))
    }

    func testTabbedIsNotPhantom() {
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(isTabbed: true, spaceIds: [1]), appState(),
            inVisibleList: false, inAllList: true, isOrderedIn: false, alpha: 1, visibleSpaceIds: [1]))
    }

    func testTabbedMissingFromAllListsIsNotPhantom() {
        // The real inactive background tab: CGS lists no tab in any Space, so it's absent from the list
        // even though its spaceIds are backfilled from the active sibling. The legitimate-window exemption
        // must beat the strong signal, or the tab disappears (fullscreen-tab / "separate window per tab").
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(isTabbed: true, spaceIds: [4]), appState(),
            inVisibleList: false, inAllList: false, isOrderedIn: false, alpha: 1, visibleSpaceIds: [4]))
    }

    func testMinimizedMissingFromAllListsIsNotPhantom() {
        // Same exemption for a minimized window CGS dropped from its per-Space lists.
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(isMinimized: true, spaceIds: []), appState(),
            inVisibleList: false, inAllList: false, isOrderedIn: false, alpha: 1, visibleSpaceIds: []))
    }

    // MARK: - C. the two exact facts, each against the case the inference got wrong

    func testAlphaZeroIsPhantomEvenOnScreen() {
        // Outlook reminders (#5170, #5448): the window is genuinely ordered in and on a visible Space, and
        // it is still invisible to the user. Only alpha says so — AX lists it as an ordinary
        // AXStandardWindow, so no accessibility signal can ever catch this family.
        XCTAssertTrue(PhantomWindowDetector.cgsVerdict(ws(spaceIds: [1]), appState(),
            inVisibleList: true, inAllList: true, isOrderedIn: true, alpha: 0, visibleSpaceIds: [1]))
        XCTAssertTrue(PhantomWindowDetector.syncVerdict(ws(spaceIds: [1]), appState(),
            isOrderedIn: true, alpha: 0))
    }

    func testOnScreenWindowIsNeverPhantomWhateverCgsSaysAboutItsSpaces() {
        // #5849: Slack reopened from the Dock is on screen and focused while CGS still tags it invisible
        // and reports no Space for it. This used to need an explicit `isFocused` exemption, which had to be
        // threaded from the MRU into a pure kernel; the ordered-in bit settles it as a fact about the
        // window rather than about where the user is looking.
        XCTAssertFalse(PhantomWindowDetector.cgsVerdict(ws(spaceIds: []), appState(),
            inVisibleList: false, inAllList: true, isOrderedIn: true, alpha: 1, visibleSpaceIds: [1]))
        XCTAssertFalse(PhantomWindowDetector.syncVerdict(ws(spaceIds: []), appState(),
            isOrderedIn: true, alpha: 1))
    }

    func testOnScreenExemptionDoesNotResurrectAWindowCgsForgot() {
        // The exemption is not unconditional: a wid CGS dropped from every list is gone, and a stale
        // ordered-in bit must not bring it back. Resurrecting it here would undo #5714.
        XCTAssertTrue(PhantomWindowDetector.cgsVerdict(ws(spaceIds: []), appState(),
            inVisibleList: false, inAllList: false, isOrderedIn: true, alpha: 1, visibleSpaceIds: []))
    }
}
