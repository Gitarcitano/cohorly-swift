import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

final class CohorlyReplayInstallTests: XCTestCase {
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

    private func sessionIds(_ cohorly: Cohorly) async -> [String?] {
        await cohorly.flush()
        return harness.track.events.map { event in
            if case .string(let id)? = event.properties["$session_id"] { return id }
            return nil
        }
    }

    // MARK: - $session_id on track()

    func testWithoutInstallNoEventHasASessionId() async {
        let cohorly = harness.makeCohorly()
        cohorly.track("a")
        cohorly.track("$exception")
        let ids = await sessionIds(cohorly)
        XCTAssertEqual(ids, [nil, nil])
    }

    func testWithInstallEveryEventCarriesTheSessionIdAndAnExplicitOneWins() async throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let id = runtime.sessions.session.id
        cohorly.track("a")
        cohorly.track("$exception", properties: ["$exception_level": "error"])
        cohorly.track("b", properties: ["$session_id": "caller"])
        let ids = await sessionIds(cohorly)
        XCTAssertEqual(ids, [id, id, "caller"])
        XCTAssertTrue(CohorlyReplay.isInstalled)
    }

    func testInstallingReplayNeverTurnsScreenViewsOn() async throws {
        let cohorly = harness.makeCohorly()
        _ = try XCTUnwrap(harness.install(cohorly))
        XCTAssertNil(cohorly.screenViewTracker)
        await cohorly.flush()
        XCTAssertTrue(harness.track.events.filter { $0.event == "$screen" }.isEmpty)
    }

    func testRatesOfZeroStillStampTheSessionId() async throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly, sampleRate: 0, onErrorSampleRate: 0))
        XCTAssertEqual(runtime.sessions.session.mode, .off)
        cohorly.track("a")
        let ids = await sessionIds(cohorly)
        XCTAssertEqual(ids, [runtime.sessions.session.id])
    }

    func testInstallNeedsATokenAndAnHTTPHost() {
        XCTAssertNil(harness.install(harness.makeCohorly(token: nil)))
        XCTAssertFalse(CohorlyReplay.isInstalled)
        XCTAssertNil(CohorlyReplay.replayEndpoint(host: "ftp://example.com"))
        XCTAssertEqual(CohorlyReplay.replayEndpoint(host: "https://a.example.com//")?.absoluteString,
                       "https://a.example.com/replay")
    }

    func testResetRotatesAtOnce() async throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let before = runtime.sessions.session.id
        cohorly.track("a")
        await cohorly.flush()
        cohorly.reset()
        cohorly.track("b")
        let ids = await sessionIds(cohorly)
        XCTAssertEqual(ids.first, before)
        XCTAssertNotNil(ids.last ?? nil)
        XCTAssertNotEqual(ids.last, before)
        XCTAssertEqual(ids.last, runtime.sessions.session.id)
    }

    func testReturnToTheForegroundAfterThirtyMinutesRotates() async throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let before = runtime.sessions.session.id
        harness.lifecycle.send(.didEnterBackground)
        harness.clock.advance(by: 30 * 60)
        cohorly.track("in-background")
        _ = cohorly.currentDistinctId // the background track has run
        harness.lifecycle.send(.willEnterForeground)
        cohorly.track("back")
        let ids = await sessionIds(cohorly)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, before) // never rotates in the background
        XCTAssertNotEqual(ids.last, before)
        XCTAssertEqual(ids.last, runtime.sessions.session.id)
    }

    func testARelaunchContinuesTheSessionAndItsDraw() throws {
        let random = ScriptedRandom([0.2])
        harness = ReplayHarness(random: random)
        let first = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0.5))
        XCTAssertEqual(first.sessions.session.mode, .session)
        let id = first.sessions.session.id
        let draws = random.callCount
        CohorlyReplay.uninstall()

        harness.clock.advance(by: 60)
        let relaunched = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0.5))
        XCTAssertEqual(relaunched.sessions.session.id, id)
        XCTAssertEqual(relaunched.sessions.session.mode, .session)
        XCTAssertEqual(random.callCount, draws)
    }

    // MARK: - Session change notification (CohorlyCrash)

    func testEverySessionIsPublishedTheFirstIncluded() throws {
        let cohorly = harness.makeCohorly()
        let published = LockedStrings()
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.replaySessionDidChangeNotification, object: cohorly, queue: nil
        ) { note in
            if let id = note.userInfo?[Cohorly.ReplaySessionKey.sessionId] as? String { published.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let runtime = try XCTUnwrap(harness.install(cohorly))
        let first = runtime.sessions.session.id
        cohorly.reset()
        _ = cohorly.currentDistinctId // reset() has run
        let second = runtime.sessions.session.id

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(published.values, [first, second])
        XCTAssertEqual(cohorly.currentReplaySessionId, second)
    }

    // MARK: - Chunks through the runtime

    func testChunksCarryTheCurrentDistinctIdWhenQueued() async throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        cohorly.identify("user-7")
        _ = cohorly.currentDistinctId
        runtime.enqueue(events: rrwebEvents(1), mode: .session)
        await runtime.chunks.flush()
        XCTAssertEqual(harness.transport.chunks.first?.distinctId, "user-7")
        XCTAssertEqual(harness.transport.chunks.first?.lib, "ios")
        XCTAssertEqual(harness.transport.chunks.first?.libVersion, Cohorly.sdkVersion)
    }

    func testAReplay429NeverDelaysTrack() async throws {
        harness.transport.reply([], fallback: .status(429, retryAfter: 600, body: #"{"error":"rate limited"}"#))
        let cohorly = harness.makeCohorly(flushAt: 1)
        let runtime = try XCTUnwrap(harness.install(cohorly))
        runtime.enqueue(events: rrwebEvents(1), mode: .session)
        await runtime.chunks.flush()
        XCTAssertNotNil(runtime.chunks.currentBackoffUntil)

        cohorly.track("a") // size trigger, not forced: must not be held back
        let deadline = Date().addingTimeInterval(2)
        while harness.track.requestCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(harness.track.requestCount, 1)
    }

    func testEffectiveModeBuffersLikeErrorModeDuringTheQuotaPause() async throws {
        harness.transport.reply([.status(429, retryAfter: 60, body: #"{"error":"replay quota exceeded"}"#)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1))
        XCTAssertEqual(runtime.effectiveMode, .session)
        runtime.enqueue(events: rrwebEvents(1), mode: .session)
        await runtime.chunks.flush()
        XCTAssertEqual(runtime.effectiveMode, .error)
        harness.clock.advance(by: 60)
        XCTAssertEqual(runtime.effectiveMode, .session)
    }

    // MARK: - Opt-out

    func testOptOutStopsReplayAndDeletesItsQueueAndOptInResumesWithANewSession() async throws {
        harness.transport.reply([], fallback: .status(500))
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let before = runtime.sessions.session.id
        runtime.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        runtime.enqueue(events: rrwebEvents(1, start: 1), mode: .error)
        XCTAssertEqual(runtime.chunks.pendingChunks.count, 2)

        cohorly.optOutTracking()
        XCTAssertTrue(cohorly.hasOptedOutTracking()) // the notification was posted
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.queueRoot.path))
        XCTAssertEqual(runtime.effectiveMode, .off)

        let sentBefore = harness.transport.requests.count
        runtime.enqueue(events: rrwebEvents(1, start: 2), mode: .error)
        await runtime.chunks.flush()
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)
        XCTAssertEqual(harness.files(), [])
        XCTAssertEqual(harness.transport.requests.count, sentBefore)

        harness.transport.reply([], fallback: .status(200))
        cohorly.optInTracking()
        XCTAssertFalse(cohorly.hasOptedOutTracking())
        XCTAssertNotEqual(runtime.sessions.session.id, before)
        XCTAssertEqual(runtime.effectiveMode, runtime.sessions.session.mode)
        runtime.enqueue(events: rrwebEvents(1, start: 3), mode: .session)
        await runtime.chunks.flush()
        XCTAssertEqual(harness.transport.chunks.last.map { eventIndexes($0) }, [3])
        XCTAssertEqual(harness.transport.chunks.last?.sessionId, runtime.sessions.session.id)
    }

    func testInstallingWhileOptedOutDeletesWhatAnEarlierLaunchQueued() async throws {
        harness.transport.reply([], fallback: .status(500))
        let (queue, _) = harness.makeQueue()
        queue.enqueue(events: rrwebEvents(1), mode: .session)
        XCTAssertEqual(queue.pendingChunks.count, 1)
        XCTAssertEqual(harness.files().count, 1)
        queue.shutdown()

        let cohorly = harness.makeCohorly()
        cohorly.optOutTracking()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)
        XCTAssertEqual(harness.files(), [])
        XCTAssertEqual(runtime.effectiveMode, .off)
        runtime.enqueue(events: rrwebEvents(1), mode: .session)
        await runtime.chunks.flush()
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)
    }

    // MARK: - Concurrency

    func testNoDeadlockBetweenTheSDKQueueAndTheReplayQueue() async throws {
        let cohorly = harness.makeCohorly(flushAt: 50)
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let lifecycle = harness.lifecycle
        let clock = harness.clock
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.replaySessionDidChangeNotification, object: cohorly, queue: nil
        ) { _ in
            // A session observer that reads the instance back must not hang it.
            _ = cohorly.currentReplaySessionId
            _ = runtime.sessions.session
            _ = runtime.effectiveMode
            runtime.enqueue(events: rrwebEvents(1), mode: .error)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let done = expectation(description: "every call returned")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 200) { index in
                switch index % 5 {
                case 0: cohorly.track("e\(index)")
                case 1: runtime.enqueue(events: rrwebEvents(1, start: index), mode: .session)
                case 2: lifecycle.send(index % 2 == 0 ? .didEnterBackground : .willEnterForeground)
                case 3: if index % 20 == 3 { cohorly.reset() } else { _ = runtime.sessions.sessionIdForEvent() }
                default: clock.advance(by: 60)
                }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)

        cohorly.track("final")
        await cohorly.flush()
        await runtime.chunks.flush()
        // reset() may have dropped earlier events, never the last one.
        let events = harness.track.events
        let last = try XCTUnwrap(events.last)
        XCTAssertEqual(last.event, "final")
        XCTAssertEqual(last.properties["$session_id"], .string(runtime.sessions.session.id))
        XCTAssertTrue(events.allSatisfy { $0.properties["$session_id"] != nil })
        XCTAssertFalse(harness.transport.requests.isEmpty)
    }

    func testASessionObserverMayReadAndRotateTheStoreWithoutDeadlock() async throws {
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        let seen = LockedStrings()
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.replaySessionDidChangeNotification, object: cohorly, queue: nil
        ) { note in
            guard let id = note.userInfo?[Cohorly.ReplaySessionKey.sessionId] as? String else { return }
            seen.append(id)
            _ = runtime.sessions.session
            _ = runtime.effectiveMode
            // A second rotation from inside the first one's notification.
            if seen.values.count == 1 { runtime.sessions.rotate() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = runtime.sessions.session.id
        let done = expectation(description: "rotation returned")
        DispatchQueue.global().async {
            runtime.sessions.rotate()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)

        let current = runtime.sessions.session.id
        XCTAssertNotEqual(current, first)
        XCTAssertEqual(Set(seen.values).count, 2)
        XCTAssertFalse(seen.values.contains(first))
        // The newest session is the last one posted and the one remembered.
        XCTAssertEqual(seen.values.last, current)
        XCTAssertEqual(cohorly.currentReplaySessionId, current)
    }

    // MARK: - Projects, reinstall, 404

    func testTwoProjectsNeverShareChunksOrTheQuotaPause() async throws {
        let quota = ScriptedReply.status(429, retryAfter: 600, body: #"{"error":"replay quota exceeded"}"#)
        harness.transport.reply([quota], fallback: .status(500))
        let first = harness.makeCohorly(token: "tok_1")
        let runtime1 = try XCTUnwrap(harness.install(first))
        runtime1.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        await runtime1.chunks.flush()
        runtime1.enqueue(events: rrwebEvents(1, start: 1), mode: .error) // stays on disk (500)
        await runtime1.chunks.flush()
        XCTAssertTrue(runtime1.chunks.isQuotaPaused)
        XCTAssertEqual(runtime1.chunks.pendingChunks.count, 1)
        CohorlyReplay.uninstall()

        let transport2 = FakeReplayTransport()
        var environment = harness.environment
        environment.transport = transport2
        let second = harness.makeCohorly(token: "tok_2")
        let runtime2 = try XCTUnwrap(CohorlyReplay.install(
            cohorly: second, config: CohorlyReplayConfig(sampleRate: 1), environment: environment))
        XCTAssertNotEqual(runtime2.namespace, runtime1.namespace)
        XCTAssertFalse(runtime2.chunks.isQuotaPaused)
        XCTAssertEqual(runtime2.effectiveMode, .session)
        XCTAssertTrue(runtime2.chunks.pendingChunks.isEmpty)
        runtime2.enqueue(events: rrwebEvents(1, start: 2), mode: .session)
        await runtime2.chunks.flush()

        XCTAssertEqual(transport2.chunks.flatMap { eventIndexes($0) }, [2])
        XCTAssertEqual(Set(transport2.requests.map { $0.headers["X-Cohorly-Token"] }), ["tok_2"])
        // The first project's chunk is still there, in its own directory, and
        // no path or key carries a token in the clear.
        let files = harness.allFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.allSatisfy { $0.hasPrefix(runtime1.namespace + "/") })
        XCTAssertFalse(files.contains { $0.contains("tok_") })
        XCTAssertNotNil(harness.storage.string(forKey: ReplayChunkQueue.quotaKey(runtime1.namespace)))
        XCTAssertNil(harness.storage.string(forKey: ReplayChunkQueue.quotaKey(runtime2.namespace)))
        XCTAssertEqual(runtime1.namespace.count, 16)
        XCTAssertTrue(runtime1.namespace.allSatisfy { $0.isHexDigit })
    }

    func testReinstallStopsTheOldRuntimeBeforeTheNewOneReadsTheDisk() async throws {
        harness.transport.hold()
        let cohorly = harness.makeCohorly()
        let old = try XCTUnwrap(harness.install(cohorly))
        old.enqueue(events: rrwebEvents(1, start: 0), mode: .session) // sent, held
        old.enqueue(events: rrwebEvents(1, start: 1), mode: .session) // waits on disk
        XCTAssertEqual(old.chunks.pendingChunks.map(\.seq), [0, 1])
        let sent = await harness.transport.waitForRequests(1)
        XCTAssertTrue(sent)

        let new = try XCTUnwrap(harness.install(cohorly))
        XCTAssertEqual(new.chunks.pendingChunks.map(\.seq), [0, 1])

        // The old runtime writes nothing any more.
        let filesBefore = harness.files()
        old.enqueue(events: rrwebEvents(1, start: 9), mode: .session)
        _ = old.chunks.pendingChunks
        XCTAssertEqual(harness.files(), filesBefore)
        XCTAssertNil(old.chunks.pendingChunks.first { $0.seq > 1 })

        new.enqueue(events: rrwebEvents(1, start: 2), mode: .session)
        XCTAssertEqual(new.chunks.pendingChunks.map(\.seq), [0, 1, 2])
        harness.transport.release()
        await new.chunks.flush()

        let chunks = harness.transport.chunks
        XCTAssertFalse(chunks.flatMap { eventIndexes($0) }.contains(9))
        XCTAssertEqual(Set(chunks.map(\.seq)), [0, 1, 2])
        XCTAssertEqual(Set(chunks.filter { $0.seq == 2 }.flatMap { eventIndexes($0) }), [2])
        XCTAssertTrue(new.chunks.pendingChunks.isEmpty)
        XCTAssertEqual(harness.files(), [])
    }

    func testReplacingTheRuntimeClearsTheSessionPublishedOnTheOldInstance() throws {
        let first = harness.makeCohorly()
        try XCTUnwrap(harness.install(first))
        XCTAssertNotNil(first.currentReplaySessionId)

        let second = harness.makeCohorly(token: "tok_2")
        let runtime = try XCTUnwrap(harness.install(second))
        XCTAssertNil(first.currentReplaySessionId)
        XCTAssertEqual(second.currentReplaySessionId, runtime.sessions.session.id)
    }

    func testA404TurnsReplayOffForTheRestOfTheProcessReinstallIncluded() async throws {
        harness.transport.hold()
        harness.transport.reply([.status(404)])
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        XCTAssertEqual(runtime.effectiveMode, .session)
        runtime.enqueue(events: rrwebEvents(1, start: 0), mode: .session)
        runtime.enqueue(events: rrwebEvents(1, start: 1), mode: .session)
        XCTAssertEqual(runtime.chunks.pendingChunks.count, 2) // both queued before the 404
        harness.transport.release()
        await runtime.chunks.flush()
        XCTAssertEqual(harness.transport.requests.count, 1)
        XCTAssertEqual(runtime.effectiveMode, .off)

        CohorlyReplay.uninstall()
        let again = try XCTUnwrap(harness.install(cohorly))
        XCTAssertEqual(again.effectiveMode, .off)
        XCTAssertTrue(again.chunks.isGone)
        again.enqueue(events: rrwebEvents(1, start: 2), mode: .error)
        await again.chunks.flush()
        XCTAssertEqual(harness.transport.requests.count, 1)
        XCTAssertEqual(harness.files().count, 2)
    }

    // MARK: - Chunk context

    func testAChunkKeepsTheSessionAndUserOfTheMomentItWasQueued() async throws {
        harness.transport.hold()
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly))
        cohorly.identify("user-1")
        _ = cohorly.currentDistinctId
        let oldSession = runtime.sessions.session.id
        runtime.enqueue(events: rrwebEvents(1, start: 0), mode: .session)

        cohorly.reset()
        let anon = cohorly.currentDistinctId // reset() and its rotation have run
        let newSession = runtime.sessions.session.id
        XCTAssertNotEqual(newSession, oldSession)
        runtime.enqueue(events: rrwebEvents(1, start: 1), mode: .session)

        harness.transport.release()
        await runtime.chunks.flush()
        let chunks = harness.transport.chunks
        let before = try XCTUnwrap(chunks.first { eventIndexes($0) == [0] })
        let after = try XCTUnwrap(chunks.first { eventIndexes($0) == [1] })
        XCTAssertEqual(before.sessionId, oldSession)
        XCTAssertEqual(before.distinctId, "user-1")
        XCTAssertEqual(before.seq, 0)
        XCTAssertEqual(after.sessionId, newSession)
        XCTAssertEqual(after.distinctId, anon)
        XCTAssertEqual(after.seq, 0)
    }
}

final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) {
        lock.lock(); items.append(item); lock.unlock()
    }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
