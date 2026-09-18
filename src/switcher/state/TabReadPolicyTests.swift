import XCTest

class TabReadPolicyTests: XCTestCase {
    private func candidate(_ wid: CGWindowID, _ capability: AppTabCapability = .neverSeenTabGroup,
                           changed: Bool = false, lastRead: UInt64? = 10) -> TabReadCandidate {
        TabReadCandidate(wid: wid, capability: capability, appWindowsChangedSinceLastRead: changed,
            lastReadGeneration: lastRead)
    }

    // MARK: - A. Always read (rules 1-3)

    /// a window whose tabs were never read is always read
    func testNeverReadIsRead() {
        let read = TabReadPolicy.windowsToRead([candidate(1, lastRead: nil)])
        XCTAssertEqual(read, [1])
    }

    /// a window of an app we have learned nothing about yet is always read
    func testUnknownCapabilityIsRead() {
        let read = TabReadPolicy.windowsToRead([candidate(1, .unknown)])
        XCTAssertEqual(read, [1])
    }

    /// the app gained or lost a window since this window's last read, so its grouping may be stale
    func testStructuralChangeIsRead() {
        let read = TabReadPolicy.windowsToRead([candidate(1, .seenTabGroup, changed: true)])
        XCTAssertEqual(read, [1])
    }

    // MARK: - B. Settled windows are skipped

    /// a settled window of an app that has never shown tabs is skipped once the backstop budget is spent
    func testSettledNonTabbingWindowIsSkipped() {
        let candidates = (1...10).map { candidate(CGWindowID($0), .neverSeenTabGroup, lastRead: UInt64(100 + $0)) }
        let read = TabReadPolicy.windowsToRead(candidates)
        XCTAssertFalse(read.contains(10))
    }

    /// the same for a tabbing app: capability alone never forces a read, which is what makes Finder and
    /// Terminal cheap
    func testSettledTabbingWindowIsSkipped() {
        let candidates = (1...10).map { candidate(CGWindowID($0), .seenTabGroup, lastRead: UInt64(100 + $0)) }
        let read = TabReadPolicy.windowsToRead(candidates)
        XCTAssertFalse(read.contains(10))
    }

    // MARK: - C. The rolling backstop

    /// exactly `backstopReadsPerPass` windows are re-read, stalest first
    func testBackstopReadsTheStalestOnly() {
        let candidates = (1...12).map { candidate(CGWindowID($0), lastRead: UInt64($0)) }
        let read = TabReadPolicy.windowsToRead(candidates)
        XCTAssertEqual(read.count, TabReadPolicy.backstopReadsPerPass)
        XCTAssertEqual(read, [1, 2, 3, 4, 5])
    }

    /// among equally stale windows, the ones whose app actually has tabs are re-checked first, so a missed
    /// notification is noticed sooner where tabs exist
    func testBackstopPrefersTabbingApps() {
        var candidates = (1...5).map { candidate(CGWindowID($0), .neverSeenTabGroup, lastRead: 50) }
        candidates += (6...10).map { candidate(CGWindowID($0), .seenTabGroup, lastRead: 50) }
        let read = TabReadPolicy.windowsToRead(candidates)
        XCTAssertEqual(read, [6, 7, 8, 9, 10])
    }

    /// fewer settled windows than the budget means all of them are re-read
    func testBackstopBudgetLargerThanCandidateSet() {
        let candidates = (1...3).map { candidate(CGWindowID($0), lastRead: UInt64($0)) }
        let read = TabReadPolicy.windowsToRead(candidates)
        XCTAssertEqual(read, [1, 2, 3])
    }

    // MARK: - D. Edges

    /// no candidates, nothing read
    func testEmptyInput() {
        XCTAssertEqual(TabReadPolicy.windowsToRead([]), [])
    }

    /// when every window already qualifies under rules 1-3, the backstop has nothing left to add
    func testAllQualifyingNeedsNoBackstop() {
        let candidates = (1...12).map { candidate(CGWindowID($0), .seenTabGroup, changed: true) }
        let read = TabReadPolicy.windowsToRead(candidates)
        XCTAssertEqual(read.count, 12)
    }
}
