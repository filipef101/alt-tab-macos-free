import Foundation

/// Names the main-thread step that stalled. #5981 was a 3.0s freeze that had to be inferred from the gap
/// between two log timestamps, because nothing recorded which step ate it.
///
/// `step()` at the top of a main-thread function closes the previous step and opens this one. A step is
/// only ever reported if it ran longer than `thresholdInMs`, so a healthy pass costs one clock read and
/// one comparison per call — cheap enough to leave on in release, which is where the reports that matter
/// come from (a user's log, not a developer's).
///
/// Steps are a flat sequence, not a tree: a nested `step()` closes its caller's, so what gets reported is
/// "from entering X to entering the next instrumented function". Work a caller does inline after a callee
/// returns is therefore attributed to the callee. Close enough to name a culprit, and it keeps the call
/// site to one line.
enum MainThreadStall {
    /// One frame at 60Hz. Under it the step cannot have been seen, so it is not worth a line.
    static let thresholdInMs = 16.0
    private static var openFile: String?
    private static var openFunction = ""
    private static var openedAt = 0.0
    private static var observer: CFRunLoopObserver?

    /// Call at the top of a main-thread function on a latency-critical path: summoning the switcher, a
    /// keystroke while cycling or searching, dismissal with focus.
    static func step(file: String = #fileID, function: String = #function) {
        guard Thread.isMainThread else { return }
        let now = ProcessInfo.processInfo.systemUptime
        closeOpenStep(now)
        openFile = file
        openFunction = function
        openedAt = now
    }

    /// Closes the turn's last step when the run loop is about to sleep, so an idle main thread doesn't
    /// accumulate one enormous step spanning the wait.
    static func observe() {
        guard observer == nil else { return }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            closeOpenStep(ProcessInfo.processInfo.systemUptime)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func closeOpenStep(_ now: Double) {
        guard let file = openFile else { return }
        openFile = nil
        let elapsedInMs = (now - openedAt) * 1000
        guard elapsedInMs >= thresholdInMs else { return }
        // Snapshotted: `Logger` renders the message later, on its write queue, by which time the next
        // step has already overwritten `openFunction`.
        let name = "\((file as NSString).lastPathComponent) \(openFunction)"
        Logger.warning { "\(name) blocked main for \(Int(elapsedInMs.rounded()))ms" }
    }
}
