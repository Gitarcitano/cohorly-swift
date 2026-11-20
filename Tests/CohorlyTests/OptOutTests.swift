import XCTest

@_spi(CohorlyReplay) @testable import Cohorly

/// Counts flag requests; never answers.
private final class CountingFlagsFetcher: CohorlyFlagsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
    func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? {
        lock.lock(); _count += 1; lock.unlock()
        return nil
    }
}

/// Fails its first request only once `release()` is called, so a test can
/// act while that request is on the wire. Later requests succeed.
private final class GatedTransport: CohorlyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func release() {
        lock.lock()
        released = true
        let gate = self.gate
        self.gate = nil
        lock.unlock()
        gate?.resume()
    }

    func post(apiHost: String, path: String, body: Data) async throws {
        lock.lock()
        _requests.append(RecordedRequest(apiHost: apiHost, path: path, body: body))
        let isFirst = _requests.count == 1
        lock.unlock()
        guard isFirst else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                gate = continuation
                lock.unlock()
            }
        }
        throw CohorlyTransportError.httpError(status: 500, retryAfter: nil)
    }
}

/// Holds every `/track` until `release()` (signalling `trackStarted` first);
/// other paths go through at once. Every request is recorded.
private final class TrackHoldingTransport: CohorlyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// True once a `/track` is on the wire (at most `timeout` seconds).
    func waitForTrack(timeout: TimeInterval = 2) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func release() { gate.signal() }

    func post(apiHost: String, path: String, body: Data) async throws {
        lock.lock()
        _requests.append(RecordedRequest(apiHost: apiHost, path: path, body: body))
        lock.unlock()
        guard path == "/track" else { return }
        started.signal()
        _ = gate.wait(timeout: .now() + 5)
    }
}

final class OptOutTests: XCTestCase {
    private func makeClient(
        storage: CohorlyStorage = InMemoryStorage(),
        transport: CohorlyTransport = MockTransport(),
        flagsFetcher: CohorlyFlagsFetcher = CountingFlagsFetcher(),
        flushAt: Int = 100
    ) -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000",
            token: "tok",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: flushAt,
            flagsFetcher: flagsFetcher,
            loadFeatureFlags: false
        )
    }

    private func names(_ requests: [RecordedRequest]) -> [String] {
        requests.filter { $0.path == "/track" }.flatMap { request in
            ((try? JSONDecoder().decode([TrackEvent].self, from: request.body)) ?? []).map(\.event)
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for condition")
    }

    func testOptOutDropsQueuedDataAndTrackAndPeopleBecomeNoOps() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        let client = makeClient(storage: storage, transport: transport)
        client.track("before")
        client.people.set(["plan": "pro"])

        client.optOutTracking()
        XCTAssertTrue(client.hasOptedOutTracking())
        XCTAssertEqual(storage.string(forKey: "cohorly.event_queue"), "[]")
        XCTAssertEqual(storage.string(forKey: "cohorly.engage_queue"), "[]")

        client.track("during")
        client.people.set(["plan": "team"])
        client.people.increment(["logins": 1])
        await client.flush()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(storage.string(forKey: "cohorly.event_queue"), "[]")
    }

    func testOptOutIsPersistedAndDropsWhatAnEarlierLaunchLeftQueued() async {
        let storage = InMemoryStorage()
        let first = makeClient(storage: storage)
        first.track("left-behind")
        XCTAssertFalse(first.hasOptedOutTracking())
        XCTAssertNotEqual(storage.string(forKey: "cohorly.event_queue"), "[]")
        storage.setString("1", forKey: "cohorly.opt_out")

        let transport = MockTransport()
        let relaunched = makeClient(storage: storage, transport: transport)
        XCTAssertTrue(relaunched.hasOptedOutTracking())
        relaunched.track("after-relaunch")
        await relaunched.flush()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(storage.string(forKey: "cohorly.event_queue"), "[]")
    }

    func testOptOutFlagSurvivesARelaunchAndOptInClearsIt() {
        let storage = InMemoryStorage()
        makeClient(storage: storage).optOutTracking()
        let relaunched = makeClient(storage: storage)
        XCTAssertTrue(relaunched.hasOptedOutTracking())

        relaunched.optInTracking()
        XCTAssertFalse(relaunched.hasOptedOutTracking())
        XCTAssertNil(storage.string(forKey: "cohorly.opt_out"))
        XCTAssertFalse(makeClient(storage: storage).hasOptedOutTracking())
    }

    func testOptInSendsAgainWithoutBringingBackWhatWasDiscarded() async {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        client.track("discarded")
        client.optOutTracking()
        client.track("ignored")
        client.optInTracking()
        client.track("kept")
        await client.flush()

        XCTAssertEqual(names(transport.requests), ["kept"])
    }

    func testIdentifyWhileOptedOutSwitchesIdentityButPostsNoAlias() {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        client.optOutTracking()
        client.identify("user-1")
        XCTAssertEqual(client.currentDistinctId, "user-1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(transport.requests.filter { $0.path == "/alias" }.isEmpty)
    }

    func testNoFlagsRequestWhileOptedOut() async {
        let fetcher = CountingFlagsFetcher()
        let client = makeClient(flagsFetcher: fetcher)
        client.optOutTracking()
        await client.reloadFeatureFlags()
        XCTAssertEqual(fetcher.count, 0)

        client.optInTracking()
        await client.reloadFeatureFlags()
        XCTAssertEqual(fetcher.count, 1)
    }

    func testASendThatFailsAfterTheOptOutNeitherRequeuesNorBacksOff() {
        let transport = GatedTransport()
        let storage = InMemoryStorage()
        let client = makeClient(storage: storage, transport: transport, flushAt: 1)
        client.track("old") // size trigger: this request stays on the wire
        waitUntil { transport.requests.count == 1 }

        client.optOutTracking()
        client.optInTracking()
        transport.release() // ... and fails with a 500 after the opt-out
        _ = client.hasOptedOutTracking()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(storage.string(forKey: "cohorly.event_queue"), "[]")

        // No backoff: the size-triggered (non-forced) flush goes out at once.
        client.track("new")
        waitUntil { transport.requests.count == 2 }
        XCTAssertEqual(names([transport.requests[1]]), ["new"])
    }

    func testOptOutNotificationCarriesTheNewState() {
        let client = makeClient()
        var states: [Bool] = []
        let lock = NSLock()
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.trackingOptOutDidChangeNotification, object: client, queue: nil
        ) { note in
            lock.lock()
            if let value = note.userInfo?[Cohorly.optedOutKey] as? Bool { states.append(value) }
            lock.unlock()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        client.optOutTracking()
        client.optInTracking()
        client.optInTracking() // already in: nothing posted
        _ = client.hasOptedOutTracking()

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(states, [true, false])
    }
}

final class ReplayHooksTests: XCTestCase {
    private func makeClient(transport: CohorlyTransport = MockTransport()) -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 100,
            loadFeatureFlags: false
        )
    }

    private func events(_ transport: MockTransport) -> [TrackEvent] {
        transport.requests.filter { $0.path == "/track" }.flatMap {
            (try? JSONDecoder().decode([TrackEvent].self, from: $0.body)) ?? []
        }
    }

    func testNoSessionIdWithoutAProvider() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        client.track("a")
        await client.flush()
        let sent = try XCTUnwrap(events(transport).first)
        XCTAssertEqual(sent.event, "a")
        XCTAssertNil(sent.properties["$session_id"])
    }

    func testProviderStampsEveryEventAndAnExplicitValueWins() async {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        let asked = LockedList<String>()
        client.setSessionIdProvider { event in
            asked.append(event)
            return "sess1"
        }
        client.track("a")
        client.track("$exception", properties: ["$exception_level": "error"])
        client.track("b", properties: ["$session_id": "mine"])
        await client.flush()

        let sent = events(transport)
        XCTAssertEqual(sent.map { $0.properties["$session_id"] }, [.string("sess1"), .string("sess1"), .string("mine")])
        // Asked for the explicit one too: the call counts the activity.
        XCTAssertEqual(asked.values, ["a", "$exception", "b"])

        client.setSessionIdProvider(nil)
        client.track("c")
        await client.flush()
        XCTAssertNil(events(transport).last?.properties["$session_id"])
    }

    func testObserverSeesNameAndFinalPropertiesOfQueuedEventsOnly() async {
        let client = makeClient(transport: MockTransport())
        client.setSessionIdProvider { _ in "sess1" }
        let seen = LockedList<(String, Properties)>()
        let remove = client.addTrackedEventObserver { name, properties in seen.append((name, properties)) }

        client.track("$exception", properties: ["$exception_level": "fatal"])
        client.optOutTracking()
        client.track("dropped")
        client.optInTracking()
        remove()
        client.track("after-remove")
        await client.flush()

        XCTAssertEqual(seen.values.map { $0.0 }, ["$exception"])
        XCTAssertEqual(seen.values.first?.1["$session_id"], .string("sess1"))
        XCTAssertEqual(seen.values.first?.1["$exception_level"], .string("fatal"))
        XCTAssertNotNil(seen.values.first?.1["$insert_id"])
    }

    func testAnOptOutWhileTrackIsOnTheWireStopsTheEngageOfTheSameFlush() async throws {
        let transport = TrackHoldingTransport()
        let client = makeClient(transport: transport)
        client.track("a")
        client.people.set(["plan": "pro"])
        let flush = Task { await client.flush() }
        XCTAssertTrue(transport.waitForTrack())

        client.optOutTracking()
        XCTAssertTrue(client.hasOptedOutTracking()) // applied on the SDK queue
        transport.release()
        await flush.value

        XCTAssertEqual(transport.requests.map(\.path), ["/track"])
    }

    func testResetCarriesTheNewDistinctId() {
        let client = makeClient()
        let received = LockedList<String>()
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.didResetNotification, object: client, queue: nil
        ) { note in
            if let id = note.userInfo?[Cohorly.IdentityKey.distinctId] as? String { received.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        client.identify("user-1")
        client.reset()
        let newId = client.currentDistinctId // waits for the reset on the SDK queue
        XCTAssertEqual(received.values, [newId])
        XCTAssertNotEqual(received.values.first, "user-1")
    }

    func testResetPostsTheResetNotificationBeforeTheNextTrackIsBuilt() async {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        let current = LockedList<String>()
        current.append("before-reset")
        client.setSessionIdProvider { _ in current.values.last }
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.didResetNotification, object: client, queue: nil
        ) { _ in current.append("after-reset") }
        defer { NotificationCenter.default.removeObserver(observer) }

        client.track("a")
        client.reset()
        client.track("b")
        await client.flush()

        XCTAssertEqual(events(transport).map { $0.properties["$session_id"] }, [.string("after-reset")])
    }
}

final class BackoffTests: XCTestCase {
    func testDoublesFromTwoSecondsUpToTheCap() {
        let backoff = CohorlyBackoff(maxDelay: 30)
        let noJitter = { 0.5 }
        XCTAssertEqual(backoff.delay(failures: 1, random: noJitter), 2)
        XCTAssertEqual(backoff.delay(failures: 2, random: noJitter), 4)
        XCTAssertEqual(backoff.delay(failures: 4, random: noJitter), 16)
        XCTAssertEqual(backoff.delay(failures: 5, random: noJitter), 30)
        XCTAssertEqual(backoff.delay(failures: 500, random: noJitter), 30)
    }

    func testJitterIsTwentyPercentEitherWay() {
        let backoff = CohorlyBackoff(maxDelay: 600)
        XCTAssertEqual(backoff.delay(failures: 3, random: { 0 }), 6.4, accuracy: 1e-9)
        XCTAssertEqual(backoff.delay(failures: 3, random: { 0.999_999 }), 9.6, accuracy: 1e-4)
    }

    func testRetryAfterAboveZeroWinsAndIsCapped() {
        let backoff = CohorlyBackoff(maxDelay: 60)
        XCTAssertEqual(backoff.delay(failures: 1, retryAfter: 17, random: { 0.5 }), 17)
        XCTAssertEqual(backoff.delay(failures: 1, retryAfter: 3600, random: { 0.5 }), 60)
        XCTAssertEqual(backoff.delay(failures: 2, retryAfter: 0, random: { 0.5 }), 4)
    }
}

final class LockedList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
    }
    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
