import XCTest

@testable import CohorlyReplay

/// A monotonic clock and a delayed-run queue the test advances by hand.
final class ManualScheduler {
    private(set) var now: TimeInterval = 1000
    private var pending: [(at: TimeInterval, work: () -> Void)] = []

    var schedule: (TimeInterval, @escaping () -> Void) -> Void {
        { [unowned self] delay, work in self.pending.append((self.now + delay, work)) }
    }

    var pendingCount: Int { pending.count }

    /// Moves the clock forward by `seconds`, running what falls due, in order.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let index = pending.indices.filter({ pending[$0].at <= target }).min(by: { pending[$0].at < pending[$1].at }) {
            let item = pending.remove(at: index)
            now = max(now, item.at)
            item.work()
        }
        now = target
    }
}

final class ReplayThrottleTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var fired: [TimeInterval] = []
    private var throttle: ReplayThrottle!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        fired = []
        throttle = ReplayThrottle(interval: 1, now: { [unowned self] in self.scheduler.now }, schedule: scheduler.schedule, handler: { [unowned self] in
            self.fired.append(self.scheduler.now)
        })
    }

    func testFirstCallIsDeliveredOnTheNextTurnNotSynchronously() {
        throttle.invoke()
        XCTAssertEqual(fired, [])
        scheduler.advance(by: 0)
        XCTAssertEqual(fired, [1000])
    }

    func testCallsInsideTheWindowCoalesceIntoOneTrailingDeliveryAtItsEnd() {
        // Binary fractions, so the times compare exactly.
        throttle.invoke()
        scheduler.advance(by: 0)
        scheduler.advance(by: 0.25)
        throttle.invoke()
        scheduler.advance(by: 0.25)
        throttle.invoke()
        throttle.invoke()
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: 0.25)
        XCTAssertEqual(fired, [1000])
        scheduler.advance(by: 0.25)
        XCTAssertEqual(fired, [1000, 1001])
    }

    func testNeverTwoDeliveriesLessThanOneSecondApart() {
        for _ in 0..<50 {
            throttle.invoke()
            scheduler.advance(by: 0.13)
        }
        scheduler.advance(by: 2)
        XCTAssertGreaterThan(fired.count, 3)
        for (previous, next) in zip(fired, fired.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - previous, 1 - 1e-9)
        }
    }

    func testNoCallNoDelivery() {
        throttle.invoke()
        scheduler.advance(by: 10)
        XCTAssertEqual(fired.count, 1)
    }

    func testCancelDropsThePendingDelivery() {
        throttle.invoke()
        throttle.cancel()
        scheduler.advance(by: 5)
        XCTAssertEqual(fired, [])
        throttle.invoke()
        scheduler.advance(by: 0)
        XCTAssertEqual(fired, [1005])
    }
}

final class ReplayCaptureBackoffTests: XCTestCase {
    private var now: TimeInterval = 0
    private var backoff: ReplayCaptureBackoff!

    override func setUp() {
        super.setUp()
        now = 0
        backoff = ReplayCaptureBackoff(baseInterval: 1, now: { [unowned self] in self.now })
    }

    private func unchanged(_ count: Int) {
        for _ in 0..<count { backoff.noteFrame(unchanged: true) }
    }

    func testCapturesEveryOpportunityUntilThreeUnchangedInARow() {
        unchanged(2)
        XCTAssertTrue(backoff.shouldCapture())
        backoff.noteFrame(unchanged: false)
        unchanged(2)
        XCTAssertFalse(backoff.isBackingOffNow)
        unchanged(1)
        XCTAssertTrue(backoff.isBackingOffNow)
        XCTAssertFalse(backoff.shouldCapture())
    }

    func testIntervalDoublesFromTheThirdUnchangedCaptureUpToEightSeconds() {
        XCTAssertEqual(backoff.currentIdleInterval, 1)
        var intervals: [TimeInterval] = []
        for _ in 0..<6 {
            backoff.noteFrame(unchanged: true)
            intervals.append(backoff.currentIdleInterval)
        }
        XCTAssertEqual(intervals, [1, 1, 2, 4, 8, 8])
    }

    func testCaptureTimesOnAStillScreen() {
        // An opportunity every 0.25 s; the first capture is the full
        // snapshot, every later one finds nothing new.
        var taken: [TimeInterval] = []
        while now < 26 {
            if backoff.shouldCapture() {
                backoff.noteFrame(unchanged: !taken.isEmpty)
                taken.append(now)
                now += 1 // the throttle: never two captures less than 1 s apart
            } else {
                now += 0.25
            }
        }
        let gaps = zip(taken, taken.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(gaps, [1, 1, 1, 2, 4, 8, 8])
    }

    func testBackedOffOpportunityIsTakenOnlyOnceTheIdleIntervalPassed() {
        unchanged(3) // idle interval 2 s, counted from the third unchanged capture
        now += 1.5
        XCTAssertFalse(backoff.shouldCapture())
        now += 0.5
        XCTAssertTrue(backoff.shouldCapture())
        // Taken: the next one waits a whole interval again.
        now += 1
        XCTAssertFalse(backoff.shouldCapture())
    }

    func testAChangedCaptureResetsToTheBaseInterval() {
        unchanged(8)
        XCTAssertEqual(backoff.currentIdleInterval, 8)
        backoff.noteFrame(unchanged: false)
        XCTAssertFalse(backoff.isBackingOffNow)
        XCTAssertTrue(backoff.shouldCapture())
        XCTAssertEqual(backoff.currentIdleInterval, 1)
    }

    func testANewStructureFingerprintIsCapturedAtOnceAndResetsTheCadence() {
        unchanged(6)
        XCTAssertFalse(backoff.shouldCapture(structure: { 1 })) // baseline
        now += 0.2
        XCTAssertFalse(backoff.shouldCapture(structure: { 1 }))
        XCTAssertTrue(backoff.shouldCapture(structure: { 2 }))
        // Even when that capture finds nothing to send, the cadence is 1 s again.
        backoff.noteFrame(unchanged: true)
        XCTAssertFalse(backoff.isBackingOffNow)
        XCTAssertEqual(backoff.currentIdleInterval, 1)
        XCTAssertTrue(backoff.shouldCapture(structure: { 2 }))
    }

    func testTheStructureIsNotWalkedWhileNotBackingOff() {
        var walks = 0
        XCTAssertTrue(backoff.shouldCapture(structure: { walks += 1; return 1 }))
        XCTAssertEqual(walks, 0)
    }
}
