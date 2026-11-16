import XCTest

final class TrackingTypesTests: XCTestCase {
    private let p1 = ProcessGeneration(pid: 42, generation: 1)
    private let p2 = ProcessGeneration(pid: 42, generation: 2)

    /// **A pid is not an identity.** macOS reuses pids, so without the generation a callback from a process
    /// that has already died reads as current to every rule keyed on identity — and the window ids it names
    /// get attributed to whatever is running under that pid now.
    func testProcessGenerationSeparatesPidReuse() {
        XCTAssertNotEqual(p1, p2)
        XCTAssertNotEqual(WindowIdentity(process: p1, wid: 7), WindowIdentity(process: p2, wid: 7))
    }

    /// Process qualification makes ownership and stale-callback ordering explicit even though macOS keeps
    /// the WindowServer number itself unique for the login session.
    func testWindowIdentityOrdersByProcessThenWid() {
        XCTAssertLessThan(WindowIdentity(process: p1, wid: 9), WindowIdentity(process: p2, wid: 1))
        XCTAssertLessThan(WindowIdentity(process: p1, wid: 1), WindowIdentity(process: p1, wid: 2))
    }

    /// Arrival order is what `AttentionModel` compares, so it has to be a total order on its own.
    func testIngressSequenceOrders() {
        XCTAssertLessThan(IngressSequence(rawValue: 1), IngressSequence(rawValue: 2))
    }

    func testSnapshotAnswersOnlyApplyForTheNewestIssue() {
        var order = QueryIssueOrder()
        let old = order.issue()
        let new = order.issue()
        XCTAssertFalse(order.accepts(old))
        XCTAssertTrue(order.accepts(new))
    }
}
