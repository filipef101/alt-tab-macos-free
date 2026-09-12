import XCTest

/// Pins `PublishedWindows` — the fold behind `AXUIElement.windowsIncludingKeyAndMain`, the one batched AX
/// read `WindowElementAcquisition` makes before falling back to `windowsByBruteForce`. Pure data in, list
/// out: no AX, no IPC, no globals, so `AXUIElement` is stood in for by `String`.
///
/// What these guard: `kAXFocusedWindow` / `kAXMainWindow` are the only two window attributes AppKit does not
/// put behind its Space filter, so they are the only way an other-Space root is ever handed to us without a
/// brute-force sweep. Both ways of losing that are silent — dropping a key from `attributes`, or returning
/// early when `kAXWindows` is empty — and neither would turn any other test red.
final class PublishedWindowsTests: XCTestCase {

    private static let currentSpaceWindow = "wid115300"
    private static let otherSpaceWindow = "wid115299" // the measured off-Space root kAXWindows omits

    // MARK: - A. The attribute list is the contract

    func testAsksForTheTwoAttributesTheSpaceFilterDoesNotApplyTo() {
        XCTAssertEqual(PublishedWindows.attributes,
                       [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute])
    }

    // MARK: - B. The ordinary current-Space app

    func testKeepsWindowsOrderAndDropsFocusedAndMainAlreadyInIt() {
        XCTAssertEqual(PublishedWindows.merge(windows: ["a", "b", "c"], focused: "b", main: "b"),
                       ["a", "b", "c"])
    }

    func testDropsDuplicatesWithinWindows() {
        // bug in macOS: Mail.app starting at login returns the same window element several times.
        XCTAssertEqual(PublishedWindows.merge(windows: ["a", "a", "b"], focused: nil, main: nil), ["a", "b"])
    }

    // MARK: - C. The app with a window on another Space

    func testAppendsFocusedWindowMissingFromWindows() {
        // Measured: kAXWindows = [115300] while AXFocusedWindow = 115299, role AXWindow, on Space 3.
        XCTAssertEqual(
            PublishedWindows.merge(windows: [Self.currentSpaceWindow], focused: Self.otherSpaceWindow, main: nil),
            [Self.currentSpaceWindow, Self.otherSpaceWindow])
    }

    func testAppendsMainWindowMissingFromWindows() {
        XCTAssertEqual(
            PublishedWindows.merge(windows: [Self.currentSpaceWindow], focused: nil, main: Self.otherSpaceWindow),
            [Self.currentSpaceWindow, Self.otherSpaceWindow])
    }

    func testAppendsFocusedAndMainOnlyOnceWhenTheyAreTheSameElement() {
        XCTAssertEqual(
            PublishedWindows.merge(windows: [Self.currentSpaceWindow],
                                   focused: Self.otherSpaceWindow, main: Self.otherSpaceWindow),
            [Self.currentSpaceWindow, Self.otherSpaceWindow])
    }

    func testAppendsBothWhenFocusedAndMainDiffer() {
        XCTAssertEqual(PublishedWindows.merge(windows: ["doc"], focused: "panel", main: "otherDoc"),
                       ["doc", "panel", "otherDoc"])
    }

    // MARK: - D. The app whose windows are ALL on another Space (the regression guard)

    func testReturnsFocusedWindowWhenWindowsIsEmpty() {
        XCTAssertEqual(PublishedWindows.merge(windows: [], focused: Self.otherSpaceWindow, main: nil),
                       [Self.otherSpaceWindow])
    }

    func testReturnsFocusedWindowWhenWindowsIsNil() {
        XCTAssertEqual(PublishedWindows.merge(windows: nil, focused: Self.otherSpaceWindow, main: nil),
                       [Self.otherSpaceWindow])
    }

    // MARK: - E. Nothing to report

    func testReturnsEmptyWhenTheAppNamesNothing() {
        XCTAssertEqual(PublishedWindows.merge(windows: nil, focused: nil, main: nil), [String]())
    }
}
