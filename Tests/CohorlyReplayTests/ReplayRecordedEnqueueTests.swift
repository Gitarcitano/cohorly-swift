import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// The chunk queue side of the recorder: chunks queued for a named session
/// (the recorder's buffer outlives a rotation) and the dropped-chunk count
/// that makes the recorder start over from a full snapshot.
final class ReplayRecordedEnqueueTests: XCTestCase {
    private var harness: ReplayHarness!

    override func setUp() {
        super.setUp()
        ReplayChunkQueue.resetProcessGone()
        harness = ReplayHarness()
    }

    override func tearDown() {
        CohorlyReplay.uninstall()
        harness = nil
        ReplayChunkQueue.resetProcessGone()
        super.tearDown()
    }

    func testEventsOfARotatedSessionNeverGoOutUnderTheNewId() async {
        harness.transport.reply([], fallback: .status(503))
        let (queue, sessions) = harness.makeQueue(distinctId: "user-a")
        let sessionA = sessions.session.id
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        _ = queue.pendingChunks
        let sessionB = sessions.rotate(distinctId: "user-b").id

        // The buffer of A, delivered after the rotation.
        XCTAssertEqual(queue.enqueue(events: rrwebEvents(2, start: 10), mode: .session, sessionId: sessionA, distinctId: "user-a"), .queued)
        queue.enqueue(events: rrwebEvents(1, start: 20), mode: .session)
        _ = queue.pendingChunks

        XCTAssertEqual(queue.pendingChunks.map(\.sessionId), [sessionA, sessionA, sessionB])
        XCTAssertEqual(queue.pendingChunks.map(\.seq), [0, 1, 0], "A continues its own seqs, B starts at 0")
        XCTAssertEqual(Set(harness.files()), ["\(sessionA)/0.json.gz", "\(sessionA)/1.json.gz", "\(sessionB)/0.json.gz"])

        harness.transport.reply([], fallback: .status(200))
        harness.clock.advance(by: 3600)
        await queue.flush()
        let chunks = harness.transport.chunks
        let late = chunks.first { eventIndexes($0) == [10, 11] }
        XCTAssertEqual(late?.sessionId, sessionA)
        XCTAssertEqual(late?.distinctId, "user-a")
        XCTAssertEqual(late?.seq, 1)
        XCTAssertFalse(chunks.contains { $0.sessionId == sessionB && eventIndexes($0).contains(10) })
    }

    func testANamedSessionThatIsLiveTakesTheLiveSeqs() {
        let (queue, sessions) = harness.makeQueue()
        let live = sessions.session.id
        harness.transport.hold()
        XCTAssertEqual(queue.enqueue(events: rrwebEvents(1), mode: .session, sessionId: live, distinctId: "user-1"), .queued)
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        XCTAssertEqual(queue.pendingChunks.map(\.seq), [0, 1])
        harness.transport.release()
    }

    func testNamedEnqueueIsRefusedWhenStoppedPausedOrInvalid() {
        let (queue, sessions) = harness.makeQueue()
        let live = sessions.session.id
        XCTAssertEqual(queue.enqueue(events: rrwebEvents(1), mode: .session, sessionId: "not valid!", distinctId: "u"), .refused)
        XCTAssertEqual(queue.enqueue(events: [], mode: .session, sessionId: live, distinctId: "u"), .refused)
        queue.stopAndDiscard()
        XCTAssertEqual(queue.enqueue(events: rrwebEvents(1), mode: .session, sessionId: live, distinctId: "u"), .refused)
    }

    func testDroppedChunksCountsEveryDropAfterTheQueueTookTheChunk() async {
        harness.transport.reply([.status(400)], fallback: .status(200))
        let (queue, _) = harness.makeQueue()
        XCTAssertEqual(queue.droppedChunks, 0)
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        XCTAssertEqual(queue.droppedChunks, 1, "a 4xx")

        harness.transport.reply([.status(413)])
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        XCTAssertEqual(queue.droppedChunks, 2, "a 413 on a single event")

        harness.writer.fail { _ in true }
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        XCTAssertEqual(queue.droppedChunks, 3, "a failed write")
        harness.writer.fail { _ in false }

        let huge = [ReplayJSON.object(["type": .int(3), "timestamp": .int(1_800_000_000_000),
                                      "data": .object(["payload": .string(String(repeating: "x", count: ReplayChunkQueue.maxChunkBytes))])])]
        queue.enqueue(events: huge, mode: .session)
        XCTAssertEqual(queue.droppedChunks, 4, "an event over the chunk limit")
    }

    func testDiskCapDropsCount() async {
        harness.transport.reply([], fallback: .status(503))
        let (queue, _) = harness.makeQueue(maxDiskBytes: 1)
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        _ = queue.pendingChunks
        XCTAssertGreaterThanOrEqual(queue.droppedChunks, 1)
    }

    func testRuntimeRefusesRecordedEventsOnceOptedOutOrStopped() throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let state = runtime.recordingState()
        XCTAssertEqual(state.mode, .session)
        XCTAssertEqual(state.sessionId, runtime.sessions.session.id)
        XCTAssertEqual(runtime.enqueueRecorded(rrwebEvents(1), mode: .session, sessionId: state.sessionId, distinctId: state.distinctId), .queued)

        cohorly.optOutTracking()
        XCTAssertTrue(cohorly.hasOptedOutTracking()) // the notification was posted
        XCTAssertEqual(runtime.recordingState().mode, .off)
        XCTAssertEqual(runtime.enqueueRecorded(rrwebEvents(1), mode: .session, sessionId: state.sessionId, distinctId: state.distinctId), .refused)

        cohorly.optInTracking()
        XCTAssertFalse(cohorly.hasOptedOutTracking())
        let after = runtime.recordingState()
        XCTAssertNotEqual(after.sessionId, state.sessionId, "opt-in starts a new session")
        runtime.stop()
        XCTAssertEqual(runtime.enqueueRecorded(rrwebEvents(1), mode: .session, sessionId: after.sessionId, distinctId: after.distinctId), .refused)
    }

    // MARK: - Retired sessions keep their seq

    func testALateBufferOfARetiredSessionWhoseChunksAllLeftTheDiskContinuesItsSeq() async {
        let (queue, sessions) = harness.makeQueue()
        let sessionA = sessions.session.id
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        _ = sessions.rotate()
        await queue.flush()
        XCTAssertEqual(harness.files(), [], "every chunk of A was accepted and deleted")

        XCTAssertEqual(queue.enqueue(events: rrwebEvents(1, start: 2), mode: .session, sessionId: sessionA, distinctId: "user-1"), .queued)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.filter { $0.sessionId == sessionA }.map(\.seq), [0, 1, 2])
    }

    func testABufferOfASessionNeitherLiveNorRememberedIsRefusedAndCounted() {
        let (queue, _) = harness.makeQueue()
        XCTAssertEqual(queue.enqueue(events: rrwebEvents(1), mode: .session, sessionId: "neverseen", distinctId: "u"), .refused)
        XCTAssertEqual(queue.droppedChunks, 1)
        _ = queue.pendingChunks
        XCTAssertEqual(harness.files(), [])
    }

    // MARK: - Meta + Full snapshot travel together

    private let meta = ReplayEvents.meta(width: 390, height: 844, href: "Screen", timestamp: 1_800_000_000_000)

    private func full(text: String = "Hello") -> ReplayJSON {
        ReplayEvents.fullSnapshot([wireframe(10_000_000, type: "text", text: text)], timestamp: 1_800_000_000_000)
    }

    func testAMetaThatWouldFillAChunkToTheByteGoesWithItsFullSnapshotIntoTheNext() async throws {
        let (queue, sessions) = harness.makeQueue()
        let overhead = ReplayChunkQueue.envelopeBytes(ReplayChunkHeader(
            sessionId: sessions.session.id, distinctId: "user-1", seq: ReplaySessionState.maxSeq,
            mode: .session, lib: "ios", libVersion: "9.9.9"))
        let encoder = JSONEncoder()
        let bare = try encoder.encode(try XCTUnwrap(rrwebEvents(1, payload: "").first)).count
        let metaBytes = try encoder.encode(meta).count
        // The filler and the Meta fill the first chunk to exactly 1 MB.
        let payload = String(repeating: "a", count: ReplayChunkQueue.maxChunkBytes - overhead - bare - 1 - metaBytes)
        let filler = rrwebEvents(1, payload: payload)[0]
        XCTAssertEqual(ReplayChunkQueue.parts(units: [[try encoder.encode(filler)], [try encoder.encode(meta)]], overhead: overhead).count, 1,
                       "alone, the Meta would fit in the first chunk")

        queue.enqueue(events: [filler, meta, full()], mode: .session)
        await queue.flush()
        let chunks = harness.transport.chunks
        XCTAssertEqual(chunks.map { eventTypes($0.events) }, [[3], [4, 2]])
        XCTAssertEqual(chunks.map(\.seq), [0, 1])
        for request in harness.transport.requests {
            XCTAssertLessThanOrEqual(try request.body.cohorlyGunzipped().count, ReplayChunkQueue.maxChunkBytes)
        }
    }

    func testA413SplitNeverSeparatesAMetaFromItsFullSnapshot() async {
        harness.transport.reply([.status(413)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: [rrwebEvents(1)[0], meta, full(), rrwebEvents(1, start: 3)[0]], mode: .session)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map { eventTypes($0.events) }, [[3, 4, 2, 3], [3, 4, 2], [3]])

        XCTAssertEqual(ReplayChunkQueue.splitPoint([meta, full()]), nil, "a lone pair cannot be split")
        XCTAssertEqual(ReplayChunkQueue.splitPoint([rrwebEvents(1)[0], meta, full()]), 1)
        XCTAssertEqual(ReplayChunkQueue.splitPoint(rrwebEvents(5)), 3)
    }

    func testA413OnALoneMetaAndFullSnapshotDropsBoth() async {
        harness.transport.reply([.status(413)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: [meta, full()], mode: .session)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.count, 1)
        XCTAssertEqual(queue.droppedChunks, 1)
        XCTAssertTrue(queue.pendingChunks.isEmpty)
    }

    func testAMetaAndFullSnapshotPairOverTheChunkLimitIsDroppedWhole() async {
        let (queue, sessions) = harness.makeQueue()
        let huge = full(text: String(repeating: "f", count: ReplayChunkQueue.maxChunkBytes))
        let admission = queue.enqueue(
            events: [meta, huge, rrwebEvents(1, start: 7)[0]], mode: .session, sessionId: sessions.session.id, distinctId: "user-1")
        XCTAssertEqual(admission, .snapshotDropped)
        XCTAssertEqual(queue.droppedChunks, 1, "the pair counts once")
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map { eventTypes($0.events) }, [[3]], "no Meta without its snapshot")
    }

    // MARK: - Drops after admission

    func testAWriteAdmittedBeforeAQuotaRefusalAndWrittenAfterItCountsAsDropped() async {
        harness.transport.hold()
        harness.transport.reply([.status(429, retryAfter: 120, body: #"{"error":"replay quota exceeded"}"#)])
        let (queue, sessions) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        let sent = await harness.transport.waitForRequests(1)
        XCTAssertTrue(sent)
        let transport = harness.transport
        queue.afterAdmitHook = { [queue] in
            // The quota answer lands between this chunk's admission and its write.
            transport.release()
            let deadline = Date().addingTimeInterval(2)
            while !queue.isQuotaPaused, Date() < deadline { usleep(1000) }
        }
        let admission = queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session, sessionId: sessions.session.id, distinctId: "user-1")
        queue.afterAdmitHook = nil
        XCTAssertEqual(admission, .queued)
        await queue.flush()
        XCTAssertTrue(queue.isQuotaPaused)
        XCTAssertEqual(queue.droppedChunks, 2, "the refused chunk and the one written after the pause began")
        XCTAssertEqual(harness.files(), [])
    }

    func testRecorderActivityRotatesAForegroundSessionAfterTwentyFourHours() throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let first = runtime.sessions.session.id
        // Only the recorder is active (touches, screen changes), every 10 minutes.
        for _ in 0..<(24 * 6 - 1) {
            harness.clock.advance(by: 600)
            runtime.noteActivity()
        }
        XCTAssertEqual(runtime.sessions.session.id, first, "23 h 50 min: same session")
        harness.clock.advance(by: 600)
        runtime.noteActivity()
        XCTAssertNotEqual(runtime.sessions.session.id, first, "24 h: a new session")
    }

    func testRecorderActivityAfterThirtyIdleMinutesInTheForegroundRotates() throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let first = runtime.sessions.session.id
        harness.clock.advance(by: 29 * 60 + 59)
        runtime.noteActivity()
        XCTAssertEqual(runtime.sessions.session.id, first)
        harness.clock.advance(by: 30 * 60)
        runtime.noteActivity()
        XCTAssertNotEqual(runtime.sessions.session.id, first)
    }
}
