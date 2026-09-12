import XCTest

/// Pins the per-process settle that collapses an app's burst of accessibility answers to its last one.
/// See AttentionSettlePolicySpecs.md.
final class AttentionSettlePolicyTests: XCTestCase {
    private let chrome: pid_t = 500
    private let finder: pid_t = 600

    private func offer(_ pid: pid_t, _ wid: CGWindowID, _ sequence: UInt64 = 1) -> SemanticAttentionOffer {
        SemanticAttentionOffer(process: ProcessGeneration(pid: pid, generation: 1), wid: wid,
            sequence: IngressSequence(rawValue: sequence))
    }

    /// **#5974, verbatim.** Chrome raises its four windows 29ms apart while already frontmost, answering
    /// once per window, and ends on the window it started on. One commit, naming the last answer.
    func testARunOfAnswersCommitsOnceWithTheLastWindow() {
        var policy = AttentionSettlePolicy()
        var commits = [CGWindowID]()
        var token = IngressSequence(rawValue: 0)
        for (i, wid) in [CGWindowID(1), 2, 3, 1].enumerated() {
            let now = Double(i) * 0.029
            // the previous deadline fires only if it was not superseded; at 29ms apart none of them is due
            token = policy.offer(offer(chrome, wid, UInt64(i + 1)), now: now).token
        }
        if let result = policy.fire(pid: chrome, token: token) { commits.append(result.wid) }
        XCTAssertEqual(commits, [1], "the run committed more than its final answer")
    }

    /// The teeth: a timer armed by an answer that was overtaken must commit nothing. Without the unique
    /// offer token every member of the run commits when its own timer fires, which is the bug the settle
    /// exists to prevent.
    func testASupersededTimerCommitsNothing() {
        var policy = AttentionSettlePolicy()
        let first = policy.offer(offer(chrome, 1), now: 0)
        _ = policy.offer(offer(chrome, 2, 2), now: 0.029)
        XCTAssertNil(policy.fire(pid: chrome, token: first.token),
                     "a superseded answer committed; the burst commits once per member")
    }

    /// The deadline follows the LAST answer. Anchored to the first, a run would commit 60ms after it began —
    /// mid-burst, on a window the user never landed on.
    func testTheDeadlineIsPushedBackByEachAnswer() {
        var policy = AttentionSettlePolicy()
        XCTAssertEqual(policy.offer(offer(chrome, 1), now: 0).deadline,
                       AttentionSettlePolicy.userSettle, accuracy: 0.0001)
        XCTAssertEqual(policy.offer(offer(chrome, 2, 2), now: 0.029).deadline,
                       0.029 + AttentionSettlePolicy.userSettle, accuracy: 0.0001)
    }

    /// One answer with nothing behind it is not a burst: it commits, unchanged.
    func testAQuietAnswerCommitsItself() {
        var policy = AttentionSettlePolicy()
        let token = policy.offer(offer(chrome, 7), now: 10).token
        XCTAssertEqual(policy.fire(pid: chrome, token: token)?.wid, 7)
        XCTAssertNil(policy.fire(pid: chrome, token: token), "the answer committed twice")
    }

    /// Two apps holding different facts is the normal state, not a conflict — so a talkative app must not
    /// hold up a quiet one's answer.
    func testTwoAppsSettleIndependently() {
        var policy = AttentionSettlePolicy()
        let finderToken = policy.offer(offer(finder, 100), now: 0).token
        _ = policy.offer(offer(chrome, 1), now: 0.01)
        _ = policy.offer(offer(chrome, 2, 2), now: 0.02)
        XCTAssertEqual(policy.fire(pid: finder, token: finderToken)?.wid, 100,
                       "one app's burst swallowed another app's answer")
    }

    /// A pending answer names a window of a process that has gone. A reused pid must not inherit it.
    func testAProcessExitDropsItsPendingAnswer() {
        var policy = AttentionSettlePolicy()
        let token = policy.offer(offer(chrome, 1), now: 0).token
        policy.forget(pid: chrome)
        XCTAssertNil(policy.fire(pid: chrome, token: token))
    }

    func testRecentInputSelectsTheShortSettle() {
        XCTAssertEqual(AttentionSettlePolicy.settle(recentInputAge: 0.1),
                       AttentionSettlePolicy.userSettle)
        XCTAssertEqual(AttentionSettlePolicy.settle(recentInputAge: 1.0),
                       AttentionSettlePolicy.programmaticSettle)
    }

    func testAProgrammaticRunSpaced150msApartCommitsOnce() {
        var policy = AttentionSettlePolicy()
        var token = IngressSequence(rawValue: 0)
        for (i, wid) in [CGWindowID(1), 2, 3, 1].enumerated() {
            let now = Double(i) * 0.15
            token = policy.offer(offer(chrome, wid, UInt64(i + 1)), now: now,
                                 settle: AttentionSettlePolicy.programmaticSettle).token
        }
        XCTAssertEqual(policy.fire(pid: chrome, token: token)?.wid, 1)
    }
}
