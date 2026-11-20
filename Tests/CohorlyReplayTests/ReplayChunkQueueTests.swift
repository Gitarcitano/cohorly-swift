import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

final class ReplayChunkQueueTests: XCTestCase {
    private var harness: ReplayHarness!

    override func setUp() {
        super.setUp()
        ReplayChunkQueue.resetProcessGone()
        harness = ReplayHarness()
    }

    override func tearDown() {
        harness = nil
        ReplayChunkQueue.resetProcessGone()
        super.tearDown()
    }

    private func seqs(_ queue: ReplayChunkQueue) -> [Int] { queue.pendingChunks.map(\.seq) }

    // MARK: - Wire format

    func testSendsAGzippedSectionTwoChunkWithTheReplayHeaders() async throws {
        let (queue, sessions) = harness.makeQueue(distinctId: "user-42")
        queue.enqueue(events: rrwebEvents(2), mode: .session)
        await queue.flush()

        let request = try XCTUnwrap(harness.transport.requests.first)
        XCTAssertEqual(harness.transport.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://ingest.example.com/replay")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Content-Encoding"], "gzip")
        XCTAssertEqual(request.headers["X-Cohorly-Token"], "tok_1")
        XCTAssertEqual(Array(request.body.prefix(2)), [0x1f, 0x8b]) // gzip magic

        let json = try request.body.cohorlyGunzipped()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["session_id", "distinct_id", "seq", "mode", "lib", "lib_version", "events"])
        XCTAssertEqual(object["session_id"] as? String, sessions.session.id)
        XCTAssertEqual(object["distinct_id"] as? String, "user-42")
        XCTAssertEqual(object["seq"] as? Int, 0)
        XCTAssertEqual(object["mode"] as? String, "session")
        XCTAssertEqual(object["lib"] as? String, "ios")
        XCTAssertEqual(object["lib_version"] as? String, "9.9.9")
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1]["timestamp"] as? Int, 1_800_000_000_001)
        XCTAssertEqual(events[1]["type"] as? Int, 3)

        XCTAssertTrue(queue.pendingChunks.isEmpty)
        XCTAssertEqual(harness.files(), [])
    }

    func testSeqIncreasesPerSessionAndFilesAreNamedBySessionAndSeq() async {
        harness.transport.reply([], fallback: .status(503))
        let (queue, sessions) = harness.makeQueue()
        let first = sessions.session.id
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        queue.enqueue(events: rrwebEvents(1), mode: .error)
        _ = queue.pendingChunks // both queued before the rotation
        let second = sessions.rotate().id
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        queue.enqueue(events: rrwebEvents(1), mode: .session)

        XCTAssertEqual(queue.pendingChunks.map(\.sessionId), [first, first, second, second])
        XCTAssertEqual(seqs(queue), [0, 1, 0, 1])
        XCTAssertEqual(harness.files(), [
            "\(first)/0.json.gz", "\(first)/1.json.gz", "\(second)/0.json.gz", "\(second)/1.json.gz"
        ].sorted())
    }

    func testTheQueueSurvivesARelaunchAndSeqContinues() async {
        harness.transport.reply([], fallback: .status(500))
        let (queue, sessions) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 2), mode: .session)
        XCTAssertEqual(seqs(queue), [0, 1, 2])
        queue.shutdown()

        let transport = FakeReplayTransport()
        let (relaunched, relaunchedSessions) = harness.makeQueue(transport: transport)
        XCTAssertEqual(relaunchedSessions.session.id, sessions.session.id)
        relaunched.enqueue(events: rrwebEvents(1, start: 3), mode: .session)
        await relaunched.flush()

        XCTAssertEqual(transport.chunks.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(transport.chunks.flatMap { eventIndexes($0) }, [0, 1, 2, 3])
        XCTAssertTrue(relaunched.pendingChunks.isEmpty)
    }

    func testAChunkOverOneMegabyteIsSplitBeforeTheDisk() async throws {
        let big = String(repeating: "a", count: 300_000)
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(4, payload: big), mode: .session)
        await queue.flush()

        let requests = harness.transport.requests
        XCTAssertEqual(requests.map { eventIndexes($0.chunk) }, [[0, 1, 2], [3]])
        XCTAssertEqual(requests.compactMap(\.chunk).map(\.seq), [0, 1])
        for request in requests {
            XCTAssertLessThanOrEqual(try request.body.cohorlyGunzipped().count, ReplayChunkQueue.maxChunkBytes)
        }
    }

    func testTheOneMegabyteLimitCountsTheWholeChunkEnvelopeIncluded() async throws {
        // Two events that fit in 1 MB by themselves, but not with a long
        // distinct id in the envelope.
        let bare = try JSONEncoder().encode(try XCTUnwrap(rrwebEvents(1, payload: "").first)).count
        let payload = String(repeating: "a", count: 495_000 - bare)
        let (queue, _) = harness.makeQueue(distinctId: String(repeating: "u", count: 10_000))
        queue.enqueue(events: rrwebEvents(2, payload: payload), mode: .session)
        await queue.flush()

        let requests = harness.transport.requests
        XCTAssertEqual(requests.map { eventIndexes($0.chunk) }, [[0], [1]])
        for request in requests {
            XCTAssertLessThanOrEqual(try request.body.cohorlyGunzipped().count, ReplayChunkQueue.maxChunkBytes)
        }
    }

    func testAnEventWhoseChunkAloneIsOverOneMegabyteIsDropped() async {
        let (queue, _) = harness.makeQueue()
        var events = rrwebEvents(3)
        events[1] = rrwebEvents(1, start: 1, payload: String(repeating: "b", count: ReplayChunkQueue.maxChunkBytes))[0]
        queue.enqueue(events: events, mode: .session)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map { eventIndexes($0) }, [[0, 2]])
        XCTAssertEqual(harness.transport.chunks.map(\.seq), [0])
    }

    func testAChunkHoldsAtMostOneThousandEvents() async {
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(2500), mode: .session)
        await queue.flush()
        let chunks = harness.transport.chunks
        XCTAssertEqual(chunks.map(\.seq), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.events.count), [1000, 1000, 500])
        XCTAssertEqual(chunks.flatMap { eventIndexes($0) }, Array(0..<2500))
    }

    // MARK: - Disk bound

    func testEqualEventsAlwaysEncodeToTheSameBytes() {
        // Each call builds new dictionaries, whose key order may differ.
        let first = ReplayChunkQueue.units(rrwebEvents(200))
        for _ in 0..<5 {
            XCTAssertEqual(ReplayChunkQueue.units(rrwebEvents(200)), first)
        }
    }

    func testTheDiskBoundDropsTheOldestChunks() {
        harness.transport.reply([], fallback: .status(500))
        let (measure, _) = harness.makeQueue()
        measure.enqueue(events: rrwebEvents(3000), mode: .session)
        let sizes = measure.pendingChunks.map(\.bytes)
        XCTAssertEqual(sizes.count, 3)
        measure.shutdown()

        // Room for two: loading the three chunks drops the oldest.
        let bound = sizes[1] + sizes[2] + sizes[0] / 2
        let (relaunched, _) = harness.makeQueue(maxDiskBytes: bound)
        XCTAssertEqual(seqs(relaunched), [1, 2])
        XCTAssertEqual(harness.files().count, 2)
        relaunched.shutdown()

        // Same bound when they are queued: the oldest of the new ones goes.
        let fresh = ReplayHarness()
        fresh.transport.reply([], fallback: .status(500))
        let (queue, _) = fresh.makeQueue(maxDiskBytes: bound)
        queue.enqueue(events: rrwebEvents(3000), mode: .session)
        XCTAssertEqual(seqs(queue), [1, 2])
    }

    func testAFileThatCannotBeDeletedStillCountsAgainstTheBound() async throws {
        harness.transport.reply([], fallback: .status(500))
        let (measure, measureSessions) = harness.makeQueue()
        measure.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        measure.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        await measure.flush() // the first was sent once, now backing off
        let old = measure.pendingChunks
        XCTAssertEqual(old.map(\.seq), [0, 1])
        measure.shutdown()

        let dir = try XCTUnwrap(old.first).url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        // Room for the two old chunks only. They cannot be removed (one may
        // also be in flight), so they still count and the new chunk goes.
        let oldBytes = old.reduce(0) { $0 + $1.bytes }
        let (queue, sessions) = harness.makeQueue(maxDiskBytes: oldBytes + 1)
        XCTAssertEqual(sessions.session.id, measureSessions.session.id)
        sessions.rotate()
        queue.enqueue(events: rrwebEvents(50), mode: .session)
        let pending = queue.pendingChunks
        XCTAssertEqual(pending.map { $0.url.resolvingSymlinksInPath().path }, old.map { $0.url.resolvingSymlinksInPath().path })
        XCTAssertLessThanOrEqual(pending.reduce(0) { $0 + $1.bytes }, oldBytes + 1)
    }

    func testAFailedWriteLosesTheChunkWithoutCrashing() async throws {
        // The root is a regular file: no directory can be created under it.
        try FileManager.default.createDirectory(
            at: harness.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: harness.root)
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        XCTAssertTrue(queue.pendingChunks.isEmpty)
        XCTAssertTrue(harness.transport.requests.isEmpty)
    }

    func testLoadContinuesSeqPastTheFilesOnDiskAndNeverOverwritesAFile() throws {
        harness.transport.reply([], fallback: .status(500))
        let (first, sessions) = harness.makeQueue()
        let id = sessions.session.id
        first.shutdown()
        try harness.plantChunk(sessionId: id, seq: 5)

        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        XCTAssertEqual(seqs(queue), [5, 6])

        // A file the queue did not load (another writer) is skipped, not replaced.
        try harness.plantChunk(sessionId: id, seq: 7, events: rrwebEvents(1, start: 70))
        queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        XCTAssertEqual(seqs(queue), [5, 6, 8])
        let planted = try Data(contentsOf: harness.queueRoot.appendingPathComponent("\(id)/7.json.gz")).cohorlyGunzipped()
        let body = try JSONDecoder().decode(ReplayChunkBody.self, from: planted)
        XCTAssertEqual(eventIndexes(body), [70])
    }

    func testFilesWithAnInvalidSeqAreDeletedOnLoad() throws {
        try harness.plantChunk(sessionId: "abc", seq: 3)
        for name in ["abc.json.gz", "-1.json.gz", "1000000001.json.gz", "99999999999999999999.json.gz", "4.json", "+5.json.gz"] {
            try harness.plantChunk(sessionId: "abc", seq: 0, name: name)
        }
        harness.transport.reply([], fallback: .status(500))
        let (queue, _) = harness.makeQueue()
        XCTAssertEqual(queue.pendingChunks.map(\.seq), [3])
        let left = try FileManager.default.contentsOfDirectory(
            atPath: harness.queueRoot.appendingPathComponent("abc").path)
        XCTAssertEqual(left, ["3.json.gz"])
    }

    func testAHaltBeforeTheSendStartsSendsNothing() async throws {
        let reached = Gate()
        let go = Gate()
        harness.beforeSendHook = {
            reached.open()
            go.wait()
        }
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        XCTAssertTrue(reached.wait()) // the send task exists and has not checked yet

        queue.stopAndDiscard() // opt-out purge
        XCTAssertTrue(queue.pendingChunks.isEmpty) // the purge ran
        go.open()

        let sent = await harness.transport.waitForRequests(1, timeout: 0.3)
        XCTAssertFalse(sent)
        XCTAssertTrue(harness.transport.requests.isEmpty)
    }

    // MARK: - Responses

    func testA429KeepsTheChunkAndHonorsRetryAfter() async {
        harness.transport.reply([.status(429, retryAfter: 42, body: #"{"status":0,"error":"rate limited"}"#)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        XCTAssertEqual(seqs(queue), [0])
        XCTAssertEqual(queue.currentBackoffUntil, harness.clock.now().addingTimeInterval(42))

        harness.clock.advance(by: 41)
        await queue.flush()
        XCTAssertEqual(harness.transport.requests.count, 1)

        harness.clock.advance(by: 1)
        await queue.flush()
        XCTAssertEqual(harness.transport.requests.count, 2)
        XCTAssertTrue(queue.pendingChunks.isEmpty)
    }

    func testRetryableFailuresBackOffExponentiallyWithTheirOwnCounter() async {
        // random 0.5 = no jitter: 2 s, then 4 s, then 8 s.
        harness.transport.reply([.status(500), .status(408), .networkError, .status(503, retryAfter: 0)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            await queue.flush()
            let until = queue.currentBackoffUntil ?? harness.clock.now()
            delays.append(until.timeIntervalSince(harness.clock.now()))
            harness.clock.advance(by: delays.last ?? 0)
        }
        XCTAssertEqual(delays, [2, 4, 8, 16])
        XCTAssertEqual(seqs(queue), [0])

        await queue.flush()
        XCTAssertTrue(queue.pendingChunks.isEmpty)
        XCTAssertNil(queue.currentBackoffUntil)
    }

    func testA401KeepsTheChunkAtTheMaximumBackoff() async {
        harness.transport.reply([.status(401, retryAfter: 5)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        XCTAssertEqual(seqs(queue), [0])
        XCTAssertEqual(queue.currentBackoffUntil, harness.clock.now().addingTimeInterval(600))
    }

    func testA413SplitsTheChunkAndTheSecondHalfTakesANewSeq() async {
        harness.transport.reply([.status(413)])
        let (queue, sessions) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(5), mode: .error)
        await queue.flush()

        let chunks = harness.transport.chunks
        XCTAssertEqual(chunks.map(\.seq), [0, 0, 1])
        XCTAssertEqual(chunks.map { eventIndexes($0) }, [[0, 1, 2, 3, 4], [0, 1, 2], [3, 4]])
        XCTAssertEqual(Set(chunks.map(\.sessionId)), [sessions.session.id])
        XCTAssertEqual(chunks.map(\.mode), [.error, .error, .error])
        XCTAssertNil(queue.currentBackoffUntil)

        queue.enqueue(events: rrwebEvents(1), mode: .error)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.last?.seq, 2)
    }

    func testA413SplitWhoseSecondHalfCannotBeWrittenKeepsTheOriginalAndRetries() async throws {
        harness.transport.reply([.status(413)])
        let (queue, sessions) = harness.makeQueue()
        harness.writer.fail { $0.lastPathComponent != "0.json.gz" }
        queue.enqueue(events: rrwebEvents(4), mode: .session)
        await queue.flush()

        XCTAssertEqual(seqs(queue), [0])
        XCTAssertEqual(harness.files(), ["\(sessions.session.id)/0.json.gz"])
        let until = try XCTUnwrap(queue.currentBackoffUntil)

        harness.writer.fail { _ in false }
        harness.clock.advance(by: until.timeIntervalSince(harness.clock.now()))
        await queue.flush()
        let chunks = harness.transport.chunks
        XCTAssertEqual(chunks.map(\.seq), [0, 0])
        XCTAssertEqual(chunks.map { eventIndexes($0) }, [[0, 1, 2, 3], [0, 1, 2, 3]])
        XCTAssertTrue(queue.pendingChunks.isEmpty)
    }

    func testA413SplitWhoseFirstHalfCannotBeWrittenKeepsTheOriginalAndNoSecondHalf() async throws {
        harness.transport.hold()
        harness.transport.reply([.status(413)])
        let (queue, sessions) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(4), mode: .session)
        XCTAssertEqual(seqs(queue), [0]) // written before the original is replaced
        harness.writer.fail { $0.lastPathComponent == "0.json.gz" }
        harness.transport.release()
        await queue.flush()

        XCTAssertEqual(seqs(queue), [0])
        XCTAssertEqual(harness.files(), ["\(sessions.session.id)/0.json.gz"])
        let until = try XCTUnwrap(queue.currentBackoffUntil)

        harness.writer.fail { _ in false }
        harness.clock.advance(by: until.timeIntervalSince(harness.clock.now()))
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map { eventIndexes($0) }, [[0, 1, 2, 3], [0, 1, 2, 3]])
        XCTAssertTrue(queue.pendingChunks.isEmpty)
    }

    func testA413OnASingleEventChunkDropsIt() async {
        harness.transport.reply([.status(413)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map(\.seq), [0, 1])
        XCTAssertTrue(queue.pendingChunks.isEmpty)
    }

    func testOtherClientErrorsDropTheChunk() async {
        harness.transport.reply([.status(400), .status(422), .status(403)])
        let (queue, _) = harness.makeQueue()
        for index in 0..<4 { queue.enqueue(events: rrwebEvents(1, start: index), mode: .session) }
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map(\.seq), [0, 1, 2, 3])
        XCTAssertTrue(queue.pendingChunks.isEmpty)
        XCTAssertNil(queue.currentBackoffUntil)
    }

    func testA404StopsReplayForThisLaunchAndKeepsTheFiles() async {
        harness.transport.hold()
        harness.transport.reply([.status(404)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        XCTAssertEqual(seqs(queue), [0, 1]) // both queued before the 404 comes back
        harness.transport.release()
        await queue.flush()
        XCTAssertTrue(queue.isGone)
        XCTAssertEqual(harness.transport.requests.count, 1)

        queue.enqueue(events: rrwebEvents(1, start: 2), mode: .error)
        await queue.flush()
        XCTAssertEqual(seqs(queue), [0, 1])
        XCTAssertEqual(harness.files().count, 2)
        XCTAssertEqual(harness.transport.requests.count, 1)
        queue.shutdown()

        // The 404 holds for the rest of the process: a new queue sends nothing.
        let sameProcess = FakeReplayTransport()
        let (again, _) = harness.makeQueue(transport: sameProcess)
        XCTAssertTrue(again.isGoneNow)
        await again.flush()
        XCTAssertTrue(sameProcess.requests.isEmpty)
        again.shutdown()

        // The next launch sends what was kept.
        ReplayChunkQueue.resetProcessGone()
        let transport = FakeReplayTransport()
        let (relaunched, _) = harness.makeQueue(transport: transport)
        await relaunched.flush()
        XCTAssertEqual(transport.chunks.flatMap { eventIndexes($0) }, [0, 1])
    }

    func testAQuotaRefusalPausesSessionModeDropsThatSessionsChunksAndKeepsErrorChunks() async {
        harness.transport.hold()
        harness.transport.reply([.status(429, retryAfter: 120, body: #"{"status":0,"error":"replay quota exceeded"}"#)])
        let (queue, sessions) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 2), mode: .error)
        XCTAssertEqual(seqs(queue), [0, 1, 2])
        harness.transport.release()
        await queue.flush()

        XCTAssertEqual(harness.transport.chunks.map(\.seq), [0, 2])
        XCTAssertTrue(queue.pendingChunks.isEmpty)
        XCTAssertTrue(queue.isQuotaPaused)
        let until = ReplaySessionStore.ms(harness.clock.now()) + 120_000
        XCTAssertEqual(harness.storage.string(forKey: ReplayChunkQueue.quotaKey(ReplayHarness.namespace())), String(until))

        queue.enqueue(events: rrwebEvents(1, start: 3), mode: .session)
        queue.enqueue(events: rrwebEvents(1, start: 4), mode: .error)
        await queue.flush()
        XCTAssertEqual(harness.transport.chunks.map(\.seq), [0, 2, 3])
        XCTAssertEqual(harness.transport.chunks.last.map { eventIndexes($0) }, [4])
        XCTAssertEqual(harness.transport.chunks.last?.sessionId, sessions.session.id)
        queue.shutdown()

        // Persisted: a relaunch is still paused until Retry-After has passed.
        let (relaunched, _) = harness.makeQueue()
        XCTAssertTrue(relaunched.isQuotaPaused)
        harness.clock.advance(by: 120)
        XCTAssertFalse(relaunched.isQuotaPaused)
        relaunched.enqueue(events: rrwebEvents(1, start: 5), mode: .session)
        await relaunched.flush()
        XCTAssertEqual(harness.transport.chunks.last.map { eventIndexes($0) }, [5])
    }

    func testAQuotaRefusalWithoutRetryAfterPausesForOneHour() async {
        harness.transport.reply([.status(429, body: #"{"error":"replay quota exceeded"}"#)])
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        await queue.flush()
        harness.clock.advance(by: 3599)
        XCTAssertTrue(queue.isQuotaPaused)
        harness.clock.advance(by: 1)
        XCTAssertFalse(queue.isQuotaPaused)
    }

    func testClassification() {
        func outcome(_ status: Int, _ body: String = "", retryAfter: TimeInterval? = nil) -> ReplayChunkQueue.Outcome {
            ReplayChunkQueue.classify(ReplayHTTPResponse(status: status, retryAfter: retryAfter, body: Data(body.utf8)))
        }
        XCTAssertEqual(outcome(200), .ok)
        XCTAssertEqual(outcome(204), .ok)
        XCTAssertEqual(outcome(429, #"{"error":"rate limited"}"#, retryAfter: 3), .retry(retryAfter: 3))
        XCTAssertEqual(outcome(429, "not json"), .retry(retryAfter: nil))
        XCTAssertEqual(outcome(429, #"{"error":"replay quota exceeded"}"#, retryAfter: 9), .quota(retryAfter: 9))
        XCTAssertEqual(outcome(408), .retry(retryAfter: nil))
        XCTAssertEqual(outcome(500), .retry(retryAfter: nil))
        XCTAssertEqual(outcome(503, retryAfter: 7), .retry(retryAfter: 7))
        XCTAssertEqual(outcome(401), .retryAtMax)
        XCTAssertEqual(outcome(413), .split)
        XCTAssertEqual(outcome(404), .gone)
        XCTAssertEqual(outcome(400), .drop)
        XCTAssertEqual(outcome(409), .drop)
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(URLSessionReplayTransport.parseRetryAfter(" 30 "), 30)
        XCTAssertEqual(URLSessionReplayTransport.parseRetryAfter("-4"), 0)
        XCTAssertNil(URLSessionReplayTransport.parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(URLSessionReplayTransport.parseRetryAfter(nil))
    }
}
