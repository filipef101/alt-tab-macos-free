import XCTest

/// Pins `GestureTriggerKernel` and `GestureTracker`, the decision extracted from `TrackpadEvents` for
/// #5137 ("the trackpad gesture stops working until AltTab is relaunched"). Pure value types in,
/// `Outcome` out — no trackpad, no taps, no globals; `TrackpadEvents` is the adapter that maps
/// `NSTouch` into these frames.
///
/// Groups: A `GestureTracker` identity handling (recycled identities, the root cause) ·
/// B the `swipeStillPossible` latch (the reason it never recovered) · C triggering ·
/// D "another gesture claimed these fingers" · E `maxFingersDownDuringTrigger` · F a gesture must not
/// inherit a spent session.
final class GestureTriggerKernelTests: XCTestCase {

    // MARK: - Helpers

    private func moved(_ ids: [String], x: CGFloat, y: CGFloat) -> [GestureTouch] {
        ids.map { GestureTouch(id: $0, position: NSPoint(x: x, y: y), isBegan: false) }
    }

    private func began(_ ids: [String], x: CGFloat, y: CGFloat) -> [GestureTouch] {
        ids.map { GestureTouch(id: $0, position: NSPoint(x: x, y: y), isBegan: true) }
    }

    /// A frame where every listed touch is both active and down. `fingersDown` defaults to the number
    /// of active touches, which is the common case.
    private func frame(_ touches: [GestureTouch], fingersDown: Int? = nil, down: Set<String>? = nil,
                       required: Int = 4, horizontal: Bool = true) -> GestureTriggerKernel.Frame {
        GestureTriggerKernel.Frame(
            fingersDown: fingersDown ?? touches.count,
            activeTouches: touches,
            touchesDownIds: down ?? Set(touches.map { $0.id }),
            requiredFingers: required,
            horizontal: horizontal)
    }

    /// Every finger off the trackpad.
    private var liftFrame: GestureTriggerKernel.Frame {
        frame([], fingersDown: 0)
    }

    private static let fourFingers = ["A", "B", "C", "D"]

    /// Lands four fingers mid-trackpad; the first frame of a gesture only re-bases, never triggers.
    private func land(_ kernel: GestureTriggerKernel, horizontal: Bool = true, required: Int = 4) {
        let ids = Array(Self.fourFingers.prefix(required))
        XCTAssertEqual(kernel.handle(frame(began(ids, x: 0.5, y: 0.5), required: required, horizontal: horizontal)), .ignore)
    }

    // MARK: - A. GestureTracker: a touch identity means nothing once the finger is up

    /// The root cause of #5137. `NSTouch.h`: "while touch identities may be re-used, they are unique
    /// during the life of the touch". A lifted finger's start position must go, or a recycled identity
    /// inherits it and the measured travel is another finger's, from another gesture.
    func testRecycledIdentityIsNotMistakenForAnOngoingTouch() {
        let tracker = GestureTracker()
        XCTAssertTrue(tracker.isNewGesture(began(["A", "B"], x: 0.5, y: 0.5)))
        XCTAssertFalse(tracker.isNewGesture(moved(["A", "B"], x: 0.5, y: 0.5)))
        tracker.prune(toTouchesDown: []) // the fingers leave the trackpad
        // The identities come back for brand-new fingers, and we never see their `.began` (macOS drops
        // events between valid ones). Without pruning this reads as the old touches still moving.
        let recycled = moved(["A", "B"], x: 0.1, y: 0.1)
        XCTAssertTrue(tracker.isNewGesture(recycled))
        XCTAssertEqual(tracker.distances(recycled), [.zero, .zero]) // measured from 0.1, not from 0.5
    }

    /// Pruning keys off the fingers that are DOWN, not the ones being measured. A finger that pauses
    /// for one event drops out of `activeTouches` but must keep its start position, or every pause
    /// re-bases the gesture and the swipe needs extra travel.
    func testStationaryFingerKeepsItsStartPosition() {
        let tracker = GestureTracker()
        XCTAssertTrue(tracker.isNewGesture(began(Self.fourFingers, x: 0.5, y: 0.5)))
        tracker.prune(toTouchesDown: Set(Self.fourFingers)) // D is stationary, but still down
        XCTAssertFalse(tracker.isNewGesture(moved(["A", "B", "C"], x: 0.55, y: 0.5)))
        // D rejoins: its start position is still on file, so this is not a new gesture
        XCTAssertFalse(tracker.isNewGesture(moved(Self.fourFingers, x: 0.56, y: 0.5)))
    }

    /// `.began` is the OS saying the touch is new, and it wins over having a start position on file.
    func testBeganPhaseAlwaysStartsANewGesture() {
        let tracker = GestureTracker()
        XCTAssertTrue(tracker.isNewGesture(began(["A"], x: 0.5, y: 0.5)))
        XCTAssertTrue(tracker.isNewGesture(began(["A"], x: 0.2, y: 0.5)))
        XCTAssertEqual(tracker.distances(moved(["A"], x: 0.2, y: 0.5)), [.zero]) // re-based to 0.2
    }

    func testTouchWithUnreadablePositionIsSkippedNotMeasured() {
        let tracker = GestureTracker()
        let unreadable = [GestureTouch(id: "A", position: nil, isBegan: true)]
        XCTAssertTrue(tracker.isNewGesture(unreadable))
        XCTAssertTrue(tracker.distances(unreadable).isEmpty)
    }

    // MARK: - B. The swipeStillPossible latch (#5137)

    /// Wandering across the gesture's axis cancels the swipe for the rest of the gesture. Intended:
    /// it mirrors the native Space swipe.
    func testOffAxisWanderCancelsTheSwipeForTheRestOfTheGesture() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        // 0.15 across the axis, well past maxSwipeDistanceInWrongDirection
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.65))), .ignore)
        // a clean 0.2 along the axis would trigger, but this gesture is spent
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.5))), .ignore)
    }

    /// The regression guard. Raising the fingers ends the gesture, and the cancelled swipe must not
    /// outlive it: this is what used to kill gestures until AltTab was relaunched, because
    /// `swipeStillPossible` gates its own recomputation and nothing on this path cleared it.
    func testCancelledSwipeDoesNotSurviveTheFingersBeingRaised() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.65))), .ignore) // cancelled
        XCTAssertEqual(kernel.handle(liftFrame), .ignore)
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.5))), .trigger)
    }

    /// A single finger left on the trackpad is pointer mode, not a gesture: it ends the gesture too.
    /// This is the frame the pre-fix code reached constantly while clearing only half the state.
    func testCancelledSwipeDoesNotSurviveDownToOneFinger() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.65))), .ignore) // cancelled
        XCTAssertEqual(kernel.handle(frame(moved(["A"], x: 0.5, y: 0.5), fingersDown: 1)), .ignore)
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.5))), .trigger)
    }

    /// `reset()` is what `TrackpadEvents.reset` calls when a switcher session ends; it must clear the
    /// latch too. The pre-fix code deliberately skipped the trigger state here.
    func testResetClearsACancelledSwipe() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.65))), .ignore) // cancelled
        kernel.reset()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.5))), .trigger)
    }

    // MARK: - C. Triggering

    func testHorizontalSwipeTriggers() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.55, y: 0.5))), .trigger)
    }

    func testVerticalSwipeTriggersWhenTheGestureIsVertical() {
        let kernel = GestureTriggerKernel()
        land(kernel, horizontal: false)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.55), horizontal: false)), .trigger)
    }

    /// Below `minSwipeDistance` nothing happens yet — the same grace the native Space swipe takes.
    func testSwipeShorterThanTheMinimumDoesNotTrigger() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.505, y: 0.5))), .ignore)
    }

    /// A vertical swipe under a horizontal configuration is the native gesture, not ours.
    func testSwipeAlongTheOtherAxisDoesNotTrigger() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.7))), .ignore)
    }

    /// The first frame only records where the fingers started.
    func testFirstFrameOfAGestureNeverTriggers() {
        let kernel = GestureTriggerKernel()
        XCTAssertEqual(kernel.handle(frame(began(Self.fourFingers, x: 0.9, y: 0.5))), .ignore)
    }

    func testThreeFingersDoNotTriggerAFourFingerGesture() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B", "C"], x: 0.7, y: 0.5), down: Set(Self.fourFingers))), .ignore)
    }

    func testThreeFingerGestureTriggersOnThreeFingers() {
        let kernel = GestureTriggerKernel()
        land(kernel, required: 3)
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B", "C"], x: 0.55, y: 0.5), required: 3)), .trigger)
    }

    /// #5499: Universal Control forwards indirect touches whose position can't be read. With no
    /// readable position there is no distance to check, and we must not trigger on that emptiness.
    func testUnreadablePositionsNeverTrigger() {
        let kernel = GestureTriggerKernel()
        let unreadable = Self.fourFingers.map { GestureTouch(id: $0, position: nil, isBegan: false) }
        XCTAssertEqual(kernel.handle(frame(unreadable)), .ignore) // records nothing
        XCTAssertEqual(kernel.handle(frame(unreadable)), .ignore)
    }

    // MARK: - D. Another gesture already claimed these fingers

    /// A fifth finger travelling means the user is doing something else (a system swipe, a scroll);
    /// we must not read the remaining fingers as our gesture. Prevents 4→3 and 2→3 triggers.
    func testExtraTravellingFingerBlocksTheTrigger() {
        let kernel = GestureTriggerKernel()
        let five = Self.fourFingers + ["E"]
        XCTAssertEqual(kernel.handle(frame(began(five, x: 0.5, y: 0.5))), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(five, x: 0.6, y: 0.5))), .ignore) // claimed
        // four of them now do a clean swipe; still refused
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.5), down: Set(five))), .ignore)
    }

    func testClaimedFingersAreReleasedWhenTheFingersAreRaised() {
        let kernel = GestureTriggerKernel()
        let five = Self.fourFingers + ["E"]
        XCTAssertEqual(kernel.handle(frame(began(five, x: 0.5, y: 0.5))), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(five, x: 0.6, y: 0.5))), .ignore) // claimed
        XCTAssertEqual(kernel.handle(liftFrame), .ignore)
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.5))), .trigger)
    }

    // MARK: - E. maxFingersDownDuringTrigger

    /// Recorded so that, once the switcher is open, "the user lifted the fingers that swiped" can be
    /// told from "the user lifted a thumb they were resting".
    func testMaxFingersDownIsRecordedDuringTheTrigger() {
        let kernel = GestureTriggerKernel()
        let ids = Self.fourFingers + ["E"] // a resting thumb, stationary so not active
        XCTAssertEqual(kernel.handle(frame(began(Self.fourFingers, x: 0.5, y: 0.5), fingersDown: 5, down: Set(ids))), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.55, y: 0.5), fingersDown: 5, down: Set(ids))), .trigger)
        XCTAssertEqual(kernel.maxFingersDownDuringTrigger, 5)
    }

    /// It describes one trigger, so it must not leak into the next gesture — a stale 5 would make the
    /// switcher focus on release a finger too early.
    func testMaxFingersDownIsClearedWhenTheGestureEnds() {
        let kernel = GestureTriggerKernel()
        let ids = Self.fourFingers + ["E"]
        XCTAssertEqual(kernel.handle(frame(began(Self.fourFingers, x: 0.5, y: 0.5), fingersDown: 5, down: Set(ids))), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.55, y: 0.5), fingersDown: 5, down: Set(ids))), .trigger)
        XCTAssertEqual(kernel.handle(liftFrame), .ignore)
        XCTAssertEqual(kernel.maxFingersDownDuringTrigger, 0)
    }

    // MARK: - F. A gesture must start clean, not inherit a spent session

    /// Reported after the #5137 fix, and present long before it: a long vertical wander followed by a
    /// horizontal swipe used to trigger, because any event where a finger paused took
    /// `activeTouches.count` off `requiredFingers`, and that branch reset `swipeStillPossible` along
    /// with the start positions. The off-axis cancel is scoped to the finger-down session, so only
    /// raising the fingers may clear it.
    func testOffAxisWanderIsNotForgivenByAFingerPausing() {
        let kernel = GestureTriggerKernel()
        land(kernel)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.75))), .ignore) // cancelled
        // one finger goes stationary for a single event: still down, just not active
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B", "C"], x: 0.5, y: 0.75), down: Set(Self.fourFingers))), .ignore)
        // and now a clean horizontal swipe, fingers never lifted
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.5, y: 0.75))), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(Self.fourFingers, x: 0.7, y: 0.75))), .ignore)
    }

    /// Fingers never land on the same event, so a 3-finger gesture passes through 1 and 2 active
    /// fingers on the way in. None of that may spend the session it belongs to. This is the guard that
    /// makes "only *more* fingers than we want claim the session" the safe rule, and the reason the
    /// stricter `!=` version was reverted.
    func testFingersArrivingOneByOneStillTrigger() {
        let kernel = GestureTriggerKernel()
        XCTAssertEqual(kernel.handle(frame(began(["A"], x: 0.5, y: 0.5), required: 3)), .ignore)
        XCTAssertEqual(kernel.handle(frame(began(["B"], x: 0.5, y: 0.5) + moved(["A"], x: 0.51, y: 0.5), required: 3)), .ignore)
        XCTAssertEqual(kernel.handle(frame(began(["C"], x: 0.5, y: 0.5) + moved(["A", "B"], x: 0.52, y: 0.5), required: 3)), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B", "C"], x: 0.56, y: 0.5), required: 3)), .trigger)
    }

    /// The line between the two things a pause may do. A finger
    /// pausing mid-swipe must not *spend* the session — the swipe can still trigger. What it does do is
    /// restart the measurement, so the travel has to be fresh from the pause onward. That is
    /// long-standing behaviour and it is the strict side of the trade, so it is pinned here rather than
    /// removed: `minSwipeDistance` is 1.5% of the trackpad, so in the hand it costs a little more travel.
    func testFingerPausingMidSwipeOnlyRestartsTheMeasurement() {
        let kernel = GestureTriggerKernel()
        land(kernel, required: 3)
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B"], x: 0.53, y: 0.5), down: ["A", "B", "C"], required: 3)), .ignore)
        // measurement re-bases here, rather than counting the 0.03 travelled before the pause
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B", "C"], x: 0.56, y: 0.5), required: 3)), .ignore)
        XCTAssertEqual(kernel.handle(frame(moved(["A", "B", "C"], x: 0.60, y: 0.5), required: 3)), .trigger)
    }
}
