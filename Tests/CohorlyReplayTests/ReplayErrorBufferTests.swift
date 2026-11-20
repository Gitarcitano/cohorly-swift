import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// The error-mode buffer alone, on a manual clock: the events it holds are
/// those a recorder would add (Meta + FullSnapshot on each checkout, touches
/// as activity).
final class ReplayErrorBufferTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var delivered: [[ReplayJSON]] = []
    private var deliveredDistinctIds: [String] = []
    private var fullRequests = 0
    private var buffer: ReplayErrorBuffer!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        delivered = []
        deliveredDistinctIds = []
        fullRequests = 0
        buffer = makeBuffer()
    }

    private func makeBuffer(maxBytes: Int = ReplayErrorBuffer.defaultMaxBytes) -> ReplayErrorBuffer {
        let scheduler = self.scheduler!
        return ReplayErrorBuffer(
            schedule: scheduler.schedule,
            deliver: { [unowned self] events, _, distinctId, _ in
                self.delivered.append(events)
                self.deliveredDistinctIds.append(distinctId)
                return .queued
            },
            requestFullSnapshot: { [unowned self] in self.fullRequests += 1 },
            now: { Int64(scheduler.now * 1000) },
            maxBytes: maxBytes)
    }

    private var nowMs: Int64 { Int64(scheduler.now * 1000) }

    private func snapshot(_ label: String = "Hello", session: String = "session-a") {
        buffer.add([
            ReplayEvents.meta(width: 390, height: 844, href: "Screen", timestamp: nowMs),
            ReplayEvents.fullSnapshot(sampleScreen(label: label), timestamp: nowMs)
        ], sessionId: session, distinctId: "user-1", generation: 1)
    }

    private func activity(session: String = "session-a") {
        buffer.add([ReplayEvents.touch(.start, x: 1, y: 1, timestamp: nowMs)],
                   sessionId: session, distinctId: "user-1", generation: 1)
    }

    private func timestamps(_ events: [ReplayJSON]) -> [Int64] { events.compactMap(ReplayEvents.timestamp(of:)) }

    private func customTag(_ event: ReplayJSON?) throws -> String? {
        let object = try jsonObject(try XCTUnwrap(event))
        return (object["data"] as? [String: Any])?["tag"] as? String
    }

    func testNothingLeavesWithoutAnError() {
        snapshot()
        for second in 1...120 {
            scheduler.advance(by: 1)
            activity()
            // The recorder answers every checkout with a full snapshot.
            if fullRequests > 0, second % 30 == 0 { snapshot() }
        }
        buffer.flush()
        scheduler.advance(by: 600)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertGreaterThan(fullRequests, 0, "checkouts were asked for while there was activity")
    }

    func testAnErrorAfterAnIdentifyGoesUnderTheNewDistinctId() {
        snapshot()
        scheduler.advance(by: 2)
        activity()
        buffer.errorOccurred(sessionId: "session-a", distinctId: "user-2")
        XCTAssertEqual(deliveredDistinctIds, ["user-2"])
    }

    func testAnErrorWithNoKnownIdentityKeepsTheBufferedOne() {
        snapshot()
        scheduler.advance(by: 2)
        activity()
        buffer.errorOccurred(sessionId: "session-a", distinctId: nil)
        XCTAssertEqual(deliveredDistinctIds, ["user-1"])
    }

    func testAnErrorSendsFromAFullSnapshotToAnErrorMarkerAtTheErrorTime() throws {
        snapshot()
        scheduler.advance(by: 2)
        activity()
        scheduler.advance(by: 1)
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertEqual(delivered.count, 1)
        let events = delivered[0]
        XCTAssertEqual(eventTypes(events), [4, 2, 3, 5])
        XCTAssertEqual(try customTag(events.last), ReplayErrorBuffer.errorTag)
        XCTAssertEqual(timestamps(events).last, nowMs)
        XCTAssertEqual(fullRequests, 1, "buffering goes on from a new full snapshot")
        XCTAssertEqual(buffer.segmentCount, 0)
    }

    func testAnErrorOfAnotherSessionSendsNothing() {
        snapshot()
        activity()
        buffer.errorOccurred(sessionId: "session-b")
        XCTAssertTrue(delivered.isEmpty)
    }

    func testAnErrorBeforeTheFirstSnapshotGoesWithThatSnapshot() throws {
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(fullRequests, 1, "a full snapshot is asked for")
        scheduler.advance(by: 1)
        snapshot()
        XCTAssertEqual(delivered.count, 1)
        let events = delivered[0]
        XCTAssertEqual(eventTypes(events), [4, 2, 5])
        XCTAssertEqual(try customTag(events.last), ReplayErrorBuffer.errorTag)
    }

    func testAnErrorOfASessionWithNoSnapshotYetGoesAtThatSessionsFirstSnapshot() throws {
        snapshot("Screen A")
        activity()
        buffer.errorOccurred(sessionId: "session-b")
        XCTAssertEqual(fullRequests, 1, "a full snapshot is asked for")
        scheduler.advance(by: 1)
        activity()
        XCTAssertTrue(delivered.isEmpty, "session-b has no snapshot yet")

        snapshot("Screen B", session: "session-b")
        XCTAssertEqual(delivered.count, 1)
        let events = delivered[0]
        XCTAssertEqual(eventTypes(events), [4, 2, 5])
        XCTAssertEqual(try customTag(events.last), ReplayErrorBuffer.errorTag)
        let json = String(bytes: try JSONEncoder().encode(events), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("Screen B"))
        XCTAssertFalse(json.contains("Screen A"), "nothing of session-a goes")
    }

    func testAWaitingErrorIsDroppedWhenTheBufferMovesToAThirdSession() {
        snapshot()
        buffer.errorOccurred(sessionId: "session-b")
        snapshot(session: "session-c")
        snapshot(session: "session-b")
        scheduler.advance(by: 10)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testLeavingErrorModeDropsTheBufferAndStopsItsCheckouts() {
        let sessionSink = RecordingSink()
        let pipeline = ReplayRecordingPipeline(sinks: [.error: buffer, .session: sessionSink])
        var inError = capture(sampleScreen(label: "Error mode"), timestamp: nowMs)
        inError.mode = .error
        pipeline.record(inError)
        buffer.add([ReplayEvents.touch(.start, x: 1, y: 1, timestamp: nowMs)],
                   sessionId: "session-a", distinctId: "user-1", generation: inError.generation)
        XCTAssertEqual(buffer.segmentCount, 1)

        scheduler.advance(by: 1)
        var inSession = capture(sampleScreen(label: "Session mode"), timestamp: nowMs)
        inSession.mode = .session
        pipeline.record(inSession)
        XCTAssertEqual(buffer.segmentCount, 0)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertNil(buffer.sessionId)
        XCTAssertEqual(sessionSink.groups.count, 1)

        // The checkout timer armed in error mode finds nothing to ask for.
        let requests = fullRequests
        scheduler.advance(by: 120)
        XCTAssertEqual(fullRequests, requests)
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertTrue(delivered.isEmpty)
    }

    func testActivityOlderThanSixtySecondsIsNeverSentAndTheSendStartsAtAFullSnapshot() {
        let start = nowMs
        snapshot()
        scheduler.advance(by: 5)
        activity() // inside the first segment, 5 s in: older than 60 s at the error
        // No checkout arrives (the recorder was not asked in time).
        scheduler.advance(by: 65)
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertTrue(delivered.isEmpty, "the only segment holds activity older than the window")
        XCTAssertGreaterThan(fullRequests, 0, "a checkout was asked for")

        // The checkout arrives: the waiting send goes, from it.
        snapshot("After")
        activity()
        XCTAssertEqual(delivered.count, 1)
        let events = delivered[0]
        XCTAssertEqual(Array(eventTypes(events).prefix(2)), [4, 2])
        XCTAssertTrue(timestamps(events).allSatisfy { $0 >= nowMs - ReplayErrorBuffer.windowMs })
        XCTAssertFalse(timestamps(events).contains(start + 5000))
    }

    func testCheckoutsKeepTheSendInsideTheWindowAndAtLeastThirtySecondsLong() {
        snapshot("A")
        for second in 1...100 {
            scheduler.advance(by: 1)
            activity()
            if second % 30 == 0 { snapshot("Checkout \(second)") }
        }
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertEqual(delivered.count, 1)
        let events = delivered[0]
        let stamps = timestamps(events)
        XCTAssertEqual(Array(eventTypes(events).prefix(2)), [4, 2])
        // Starts at the newest checkout at least 30 s old (60 s), ends at 100 s.
        XCTAssertEqual(stamps.first, nowMs - 40_000)
        XCTAssertGreaterThanOrEqual(nowMs - (stamps.first ?? 0), ReplayErrorBuffer.minWindowMs)
        XCTAssertLessThanOrEqual(nowMs - (stamps.first ?? 0), ReplayErrorBuffer.windowMs)
    }

    func testAStillScreenSendsItsLastSnapshotStampedAtTheWindowStart() {
        snapshot()
        scheduler.advance(by: 90)
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertEqual(delivered.count, 1)
        let events = delivered[0]
        XCTAssertEqual(eventTypes(events), [4, 2, 5])
        XCTAssertEqual(Array(timestamps(events).prefix(2)), [nowMs - 60_000, nowMs - 60_000])
    }

    func testTwoErrorsTwoSecondsApartSendNowAndOnceTheGapIsOverWithTheNewEvents() throws {
        snapshot()
        activity()
        scheduler.advance(by: 10)
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertEqual(delivered.count, 1)

        // The recorder answers the request with a full snapshot, then more happens.
        snapshot("Next")
        scheduler.advance(by: 1)
        activity()
        let lateActivity = nowMs
        scheduler.advance(by: 1) // 2 s after the first error
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertEqual(delivered.count, 1, "inside the 5 s gap: waits")
        scheduler.advance(by: 1)
        buffer.errorOccurred(sessionId: "session-a") // a third error inside the gap goes with it
        scheduler.advance(by: 1.5)
        XCTAssertEqual(delivered.count, 1)
        scheduler.advance(by: 0.5) // 5 s after the first send
        XCTAssertEqual(delivered.count, 2, "one send for both errors")
        let second = delivered[1]
        XCTAssertEqual(Array(eventTypes(second).prefix(2)), [4, 2])
        XCTAssertTrue(timestamps(second).contains(lateActivity))
        XCTAssertEqual(try customTag(second.last), ReplayErrorBuffer.errorTag)
        XCTAssertEqual(timestamps(second).last, nowMs)

        // Nothing new since: another error sends nothing twice.
        scheduler.advance(by: 10)
        buffer.errorOccurred(sessionId: "session-a")
        scheduler.advance(by: 10)
        XCTAssertEqual(delivered.count, 2)
    }

    func testTheMemoryBoundDropsTheOldestSegmentsFirst() throws {
        let payload = String(repeating: "x", count: 2000)
        let encoder = JSONEncoder()
        let segmentBytes = try [
            ReplayEvents.meta(width: 390, height: 844, href: "Screen", timestamp: nowMs),
            ReplayEvents.fullSnapshot(sampleScreen(label: "A" + payload), timestamp: nowMs)
        ].reduce(0) { $0 + (try encoder.encode($1).count) }
        buffer = makeBuffer(maxBytes: segmentBytes * 3 - 1)
        for label in ["A", "B", "C", "D"] {
            snapshot(label + payload)
            scheduler.advance(by: 1)
        }
        XCTAssertEqual(buffer.segmentCount, 2)
        XCTAssertLessThanOrEqual(buffer.bytes, segmentBytes * 3 - 1)
        buffer.errorOccurred(sessionId: "session-a")
        let json = String(bytes: try encoder.encode(delivered.flatMap { $0 }), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("A" + payload))
        XCTAssertFalse(json.contains("B" + payload))
        XCTAssertTrue(json.contains("C" + payload))
        XCTAssertTrue(json.contains("D" + payload))
    }

    func testOneSegmentOverTheBoundAsksForACheckout() {
        buffer = makeBuffer(maxBytes: 100)
        snapshot()
        XCTAssertEqual(fullRequests, 1)
    }

    func testACheckoutIsAskedForEveryThirtySecondsOnlyWithActivity() {
        snapshot()
        scheduler.advance(by: 60)
        XCTAssertEqual(fullRequests, 0, "a still screen needs no checkout")
        activity()
        XCTAssertEqual(fullRequests, 1, "activity in a segment already 30 s old")
        snapshot()
        activity()
        scheduler.advance(by: 29)
        XCTAssertEqual(fullRequests, 1, "the new segment is not 30 s old")
        scheduler.advance(by: 2)
        XCTAssertEqual(fullRequests, 2, "the 30 s timer found it due")
    }

    func testAnotherSessionOrGenerationStartsOver() {
        snapshot()
        activity()
        snapshot(session: "session-b")
        buffer.errorOccurred(sessionId: "session-a")
        XCTAssertTrue(delivered.isEmpty)
        buffer.errorOccurred(sessionId: "session-b")
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(eventTypes(delivered[0]), [4, 2, 5])

        scheduler.advance(by: 10)
        snapshot(session: "session-b")
        activity(session: "session-b")
        buffer.add([ReplayEvents.touch(.end, x: 1, y: 1, timestamp: nowMs)],
                   sessionId: "session-b", distinctId: "user-1", generation: 2)
        buffer.errorOccurred(sessionId: "session-b")
        XCTAssertEqual(delivered.count, 1, "a touch of a new generation has no snapshot to build on")
    }

    func testDiscardDropsTheBufferAndAWaitingSend() {
        snapshot()
        activity()
        buffer.errorOccurred(sessionId: "session-a")
        snapshot()
        activity()
        buffer.errorOccurred(sessionId: "session-a") // waits for the gap
        buffer.discard()
        scheduler.advance(by: 10)
        XCTAssertEqual(delivered.count, 1)
    }
}
