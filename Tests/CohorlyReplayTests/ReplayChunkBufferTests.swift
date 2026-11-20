import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// Records what a chunk buffer delivers.
final class DeliveredChunks {
    struct Chunk {
        var events: [ReplayJSON]
        var sessionId: String
        var distinctId: String
        var generation: UInt64
    }

    var chunks: [Chunk] = []
    /// What the next deliveries answer.
    var admission = ReplayAdmission.queued
    var accept: Bool {
        get { admission == .queued }
        set { admission = newValue ? .queued : .refused }
    }

    var deliver: ReplayChunkBuffer.Deliver {
        { [unowned self] events, sessionId, distinctId, generation in
            self.chunks.append(Chunk(events: events, sessionId: sessionId, distinctId: distinctId, generation: generation))
            return self.admission
        }
    }
}

extension ReplayEventSink {
    /// `add` at generation 0.
    func add(_ group: [ReplayJSON], sessionId: String, distinctId: String) {
        add(group, sessionId: sessionId, distinctId: distinctId, generation: 0)
    }
}

func event(_ index: Int, payload: String = "x") -> ReplayJSON {
    .object(["type": .int(3), "timestamp": .int(index), "data": .object(["index": .int(index), "payload": .string(payload)])])
}

final class ReplayChunkBufferTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var delivered: DeliveredChunks!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        delivered = DeliveredChunks()
    }

    /// The production defaults but for the limits a test lowers.
    private func makeBuffer(maxBytes: Int = ReplayChunkBuffer.defaultMaxBytes, maxEvents: Int = 1000) -> ReplayChunkBuffer {
        ReplayChunkBuffer(schedule: scheduler.schedule, deliver: delivered.deliver, maxBytes: maxBytes, maxEvents: maxEvents)
    }

    func testDeliversTenSecondsAfterTheFirstEvent() {
        let buffer = makeBuffer()
        buffer.add([event(1)], sessionId: "a", distinctId: "u")
        scheduler.advance(by: 6)
        buffer.add([event(2)], sessionId: "a", distinctId: "u")
        scheduler.advance(by: 3.5)
        XCTAssertTrue(delivered.chunks.isEmpty)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(delivered.chunks.count, 1)
        XCTAssertEqual(delivered.chunks[0].events, [event(1), event(2)])
        // An old timer does not cut the next chunk early.
        buffer.add([event(3)], sessionId: "a", distinctId: "u")
        scheduler.advance(by: 9)
        XCTAssertEqual(delivered.chunks.count, 1)
        scheduler.advance(by: 1)
        XCTAssertEqual(delivered.chunks.count, 2)
    }

    func testFlushDeliversNowAndEmptyFlushDoesNothing() {
        let buffer = makeBuffer()
        buffer.flush()
        XCTAssertTrue(delivered.chunks.isEmpty)
        buffer.add([event(1)], sessionId: "a", distinctId: "u")
        buffer.flush()
        XCTAssertEqual(delivered.chunks.count, 1)
        scheduler.advance(by: 20)
        XCTAssertEqual(delivered.chunks.count, 1)
    }

    func testAnotherSessionDistinctIdOrGenerationStartsAnotherChunk() {
        let buffer = makeBuffer()
        buffer.add([event(1)], sessionId: "a", distinctId: "u")
        buffer.add([event(2)], sessionId: "b", distinctId: "u")
        buffer.add([event(3)], sessionId: "b", distinctId: "v")
        buffer.add([event(4)], sessionId: "b", distinctId: "v", generation: 7)
        buffer.flush()
        XCTAssertEqual(delivered.chunks.map(\.sessionId), ["a", "b", "b", "b"])
        XCTAssertEqual(delivered.chunks.map(\.distinctId), ["u", "u", "v", "v"])
        XCTAssertEqual(delivered.chunks.map(\.generation), [0, 0, 0, 7])
        XCTAssertEqual(delivered.chunks.map(\.events.count), [1, 1, 1, 1])
    }

    func testAGroupIsNeverSplitAndOneOverTheLimitGoesAlone() throws {
        let one = try JSONEncoder().encode(event(0, payload: String(repeating: "x", count: 100))).count
        let buffer = makeBuffer(maxBytes: one * 3 - 1)
        buffer.add([event(1, payload: String(repeating: "x", count: 100))], sessionId: "a", distinctId: "u")
        // Two more would pass the limit: the first chunk goes before them.
        let group = [event(2, payload: String(repeating: "x", count: 100)), event(3, payload: String(repeating: "x", count: 100))]
        buffer.add(group, sessionId: "a", distinctId: "u")
        XCTAssertEqual(delivered.chunks.count, 1)
        XCTAssertEqual(delivered.chunks[0].events.count, 1)
        // A group larger than the limit alone is delivered whole, at once.
        let big = (4...8).map { event($0, payload: String(repeating: "x", count: 100)) }
        buffer.add(big, sessionId: "a", distinctId: "u")
        XCTAssertEqual(delivered.chunks.map(\.events.count), [1, 2, 5])
    }

    func testTheEventLimitCutsBeforeTheGroup() {
        let buffer = makeBuffer(maxEvents: 3)
        buffer.add([event(1), event(2)], sessionId: "a", distinctId: "u")
        buffer.add([event(3), event(4)], sessionId: "a", distinctId: "u")
        buffer.flush()
        XCTAssertEqual(delivered.chunks.map(\.events.count), [2, 2])
    }

    func testDiscardDropsEverythingAndItsTimer() {
        let buffer = makeBuffer()
        buffer.add([event(1)], sessionId: "a", distinctId: "u")
        buffer.discard()
        scheduler.advance(by: 20)
        buffer.flush()
        XCTAssertTrue(delivered.chunks.isEmpty)
    }

    func testARefusedOrSnapshotLosingDeliveryIsReportedWithItsSession() {
        let buffer = makeBuffer()
        var reports: [String] = []
        buffer.onAdmission = { admission, session in reports.append("\(admission) \(session)") }
        buffer.add([event(1)], sessionId: "a", distinctId: "u")
        buffer.flush()
        delivered.admission = .refused
        buffer.add([event(2)], sessionId: "b", distinctId: "u")
        buffer.flush()
        delivered.admission = .snapshotDropped
        buffer.add([event(3)], sessionId: "c", distinctId: "u")
        buffer.flush()
        XCTAssertEqual(reports, ["refused b", "snapshotDropped c"])
    }
}

final class ReplayRecordingPipelineTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var delivered: DeliveredChunks!
    private var buffer: ReplayChunkBuffer!
    private var pipeline: ReplayRecordingPipeline!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        delivered = DeliveredChunks()
        buffer = ReplayChunkBuffer(schedule: scheduler.schedule, deliver: delivered.deliver)
        pipeline = ReplayRecordingPipeline(sink: buffer) { [unowned self] in self.dropped }
        buffer.onAdmission = { [unowned self] admission, session in self.pipeline.deliveryFailed(admission, sessionId: session) }
    }

    /// `ReplayChunkQueue.droppedChunks` as the pipeline reads it.
    private var dropped = 0

    private func touch(_ kind: ReplayEvents.TouchKind, session: String = "session-a", x: Int = 10, at timestamp: Int64) -> ReplayTouch {
        ReplayTouch(kind: kind, x: x, y: 20, timestamp: timestamp, sessionId: session, distinctId: "user-1")
    }

    private var allEvents: [ReplayJSON] { delivered.chunks.flatMap(\.events) }

    func testTouchesBeforeTheFirstFullSnapshotWaitAndFollowIt() throws {
        pipeline.touch(touch(.start, at: 1_799_999_999_000))
        pipeline.touch(touch(.end, at: 1_799_999_999_500))
        buffer.flush()
        XCTAssertTrue(delivered.chunks.isEmpty, "never before the snapshot")
        XCTAssertEqual(pipeline.pendingTouchCount, 2)

        XCTAssertTrue(pipeline.record(capture(sampleScreen())))
        buffer.flush()
        XCTAssertEqual(eventTypes(allEvents), [4, 2, 3, 3])
        // Timestamps never before the snapshot they land on.
        let touchTimes = try allEvents.suffix(2).map { try jsonObject($0)["timestamp"] as? Int }
        XCTAssertEqual(touchTimes, [1_800_000_000_000, 1_800_000_000_000])
        XCTAssertEqual(pipeline.pendingTouchCount, 0)

        // After it, touches go at once.
        pipeline.touch(touch(.start, at: 1_800_000_001_000))
        buffer.flush()
        XCTAssertEqual(eventTypes(allEvents), [4, 2, 3, 3, 3])
    }

    func testAMetaAndItsFullSnapshotAreInOneChunk() {
        _ = pipeline.record(capture(sampleScreen()))
        buffer.flush()
        XCTAssertEqual(delivered.chunks.count, 1)
        XCTAssertEqual(eventTypes(delivered.chunks[0].events), [4, 2])
    }

    func testAnUnchangedCaptureEmitsNothing() {
        XCTAssertTrue(pipeline.record(capture(sampleScreen())))
        XCTAssertFalse(pipeline.record(capture(sampleScreen())))
        XCTAssertTrue(pipeline.record(capture(sampleScreen(label: "Other"))))
    }

    func testANewSessionStartsWithAFullSnapshotInItsOwnChunk() {
        _ = pipeline.record(capture(sampleScreen()))
        _ = pipeline.record(capture(sampleScreen(), session: "session-b"))
        buffer.flush()
        XCTAssertEqual(delivered.chunks.map(\.sessionId), ["session-a", "session-b"])
        XCTAssertEqual(delivered.chunks.map { eventTypes($0.events) }, [[4, 2], [4, 2]])
    }

    func testADroppedChunkSeenWhenTheCaptureIsAdmittedMakesItFull() {
        _ = pipeline.record(capture(sampleScreen()))
        _ = pipeline.record(capture(sampleScreen(label: "a")))
        // Read at admission, not when the screen was read.
        dropped = 1
        _ = pipeline.record(capture(sampleScreen(label: "b")))
        _ = pipeline.record(capture(sampleScreen(label: "c")))
        buffer.flush()
        XCTAssertEqual(eventTypes(delivered.chunks.last?.events ?? []), [4, 2, 3, 4, 2, 3])
    }

    func testAFullSnapshotTooLargeForAChunkFallsBackToImagesWithoutPixelsUntilTheSessionChanges() throws {
        var photo = wireframe(10_000_007, x: 0, y: 300, width: 100, height: 100, type: "image")
        photo.base64 = "data:image/jpeg;base64,PIXELS"
        let screen = sampleScreen(extra: [photo])
        delivered.admission = .snapshotDropped
        _ = pipeline.record(capture(screen))
        buffer.flush()
        delivered.admission = .queued
        XCTAssertFalse(pipeline.status.hasFullSnapshot("session-a"), "nothing to build a Mutation on")

        _ = pipeline.record(capture(screen))
        buffer.flush()
        let retry = try XCTUnwrap(delivered.chunks.last)
        XCTAssertEqual(eventTypes(retry.events), [4, 2])
        let retryJSON = String(bytes: try JSONEncoder().encode(retry.events), encoding: .utf8) ?? ""
        XCTAssertFalse(retryJSON.contains("PIXELS"))
        XCTAssertTrue(retryJSON.contains("\"type\":\"image\""), "the image is still drawn, as a box")

        _ = pipeline.record(capture(screen, session: "session-b"))
        buffer.flush()
        let next = String(bytes: try JSONEncoder().encode(delivered.chunks.last?.events ?? []), encoding: .utf8) ?? ""
        XCTAssertTrue(next.contains("PIXELS"), "a new session has its pixels back")
    }

    func testARefusedChunkMakesTheNextCaptureFull() {
        _ = pipeline.record(capture(sampleScreen()))
        delivered.accept = false
        buffer.flush()
        delivered.accept = true
        _ = pipeline.record(capture(sampleScreen(label: "Changed")))
        buffer.flush()
        XCTAssertEqual(eventTypes(delivered.chunks.last?.events ?? []), [4, 2])
    }

    func testDiscardForgetsTheBufferTheScreenAndTheWaitingTouches() {
        _ = pipeline.record(capture(sampleScreen()))
        pipeline.touch(touch(.start, session: "session-b", at: 1))
        pipeline.discard()
        buffer.flush()
        XCTAssertTrue(delivered.chunks.isEmpty)
        XCTAssertEqual(pipeline.pendingTouchCount, 0)
        XCTAssertEqual(eventTypes(pipeline.status.events(for: capture(sampleScreen()))), [4, 2])
    }

    func testAtMostTwentyTouchesWaitAndTheNewestSurvive() throws {
        for index in 0..<25 { pipeline.touch(touch(.start, x: index, at: Int64(index))) }
        XCTAssertEqual(pipeline.pendingTouchCount, 20)
        _ = pipeline.record(capture(sampleScreen()))
        buffer.flush()
        XCTAssertEqual(eventTypes(allEvents), [4, 2] + Array(repeating: 3, count: 20))
        let xs = try allEvents.dropFirst(2).map { event -> Int in
            let data = try XCTUnwrap(try jsonObject(event)["data"] as? [String: Any])
            return try XCTUnwrap(data["x"] as? Int)
        }
        XCTAssertEqual(xs, Array(5..<25), "the five oldest were dropped, the rest kept in order")
    }
}
