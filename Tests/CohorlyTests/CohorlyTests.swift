import XCTest

@testable import Cohorly

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }
}

/// Deterministic clock for driving automatic-event session math in tests.
private final class MutableClock: CohorlyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

final class CohorlyTests: XCTestCase {

    private func waitUntil(
        timeout: TimeInterval = 2, _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for condition")
    }

    // MARK: - Payload shape

    func testTrackPayloadShape() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )

        client.identify("user-123")
        client.track("Button Clicked", properties: ["button": "signup"])
        await client.flush()

        // identify() also fires a best-effort /alias post (see the "identify()
        // aliasing" tests below); isolate the /track call this test cares about.
        let trackRequests = transport.requests.filter { $0.path == "/track" }
        XCTAssertEqual(trackRequests.count, 1)

        let events = try! JSONDecoder().decode([TrackEvent].self, from: trackRequests[0].body)
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.event, "Button Clicked")
        XCTAssertEqual(event.properties["button"]?.stringValue, "signup")
        XCTAssertEqual(event.properties["distinct_id"]?.stringValue, "user-123")
        XCTAssertEqual(event.properties["$lib"]?.stringValue, "ios")
        XCTAssertNotNil(event.properties["time"]?.intValue)
        XCTAssertNotNil(event.properties["$insert_id"]?.stringValue)
    }

    func testInsertIdIsUniquePerEvent() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 100
        )
        client.track("a")
        client.track("b")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertNotEqual(events[0].properties["$insert_id"]?.stringValue, events[1].properties["$insert_id"]?.stringValue)
    }

    // MARK: - Batching

    func testFlushesAutomaticallyAtFlushAt() {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 3
        )
        client.track("e1")
        client.track("e2")
        waitUntil(timeout: 0.5) { transport.requests.count == 0 }
        client.track("e3")

        waitUntil { transport.requests.count == 1 }
        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertEqual(events.count, 3)
    }

    func testFlushesAutomaticallyOnInterval() {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 0.3,
            flushAt: 20
        )
        client.track("e1")
        waitUntil(timeout: 2) { transport.requests.count == 1 }
    }

    func testRetriesQueuedEventsOnSendFailure() async {
        let transport = MockTransport(failuresRemaining: 1)
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("e1")
        await client.flush()
        XCTAssertEqual(transport.requests.count, 1)

        await client.flush()
        XCTAssertEqual(transport.requests.count, 2)
        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[1].body)
        XCTAssertEqual(events.first?.event, "e1")
    }

    func testQueueIsPersistedToStorage() {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100
        )
        client.track("queued-event")
        waitUntil { storage.string(forKey: "cohorly.event_queue") != nil }
        let raw = storage.string(forKey: "cohorly.event_queue")!
        let events = try! JSONDecoder().decode([TrackEvent].self, from: raw.data(using: .utf8)!)
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - Identity

    func testIdentifySwitchesDistinctId() {
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: MockTransport(),
            storage: InMemoryStorage()
        )
        client.identify("user-42")
        waitUntil { client.currentDistinctId == "user-42" }
    }

    func testQueuePersistsAcrossInstancesViaSharedStorage() {
        let storage = InMemoryStorage()
        let client1 = Cohorly(
            apiHost: "http://localhost:4000", transport: MockTransport(), storage: storage)
        client1.identify("user-99")
        waitUntil { client1.currentDistinctId == "user-99" }

        let client2 = Cohorly(
            apiHost: "http://localhost:4000", transport: MockTransport(), storage: storage)
        XCTAssertEqual(client2.currentDistinctId, "user-99")
    }

    func testResetAssignsFreshAnonymousId() {
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: MockTransport(),
            storage: InMemoryStorage()
        )
        client.identify("user-1")
        waitUntil { client.currentDistinctId == "user-1" }
        let before = client.currentDistinctId
        client.reset()
        waitUntil { client.currentDistinctId != before }
        XCTAssertNotEqual(client.currentDistinctId, "user-1")
    }

    // MARK: - identify() aliasing

    func testIdentifyWhileAnonymousPostsAliasOnce() {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            token: "proj_abc123",
            transport: transport,
            storage: InMemoryStorage()
        )
        let anonId = client.currentDistinctId
        client.identify("user-42")
        waitUntil { client.currentDistinctId == "user-42" }

        waitUntil { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests[0].path, "/alias")
        let payload = try! JSONDecoder().decode(AliasPayload.self, from: transport.requests[0].body)
        XCTAssertEqual(payload.alias, anonId)
        XCTAssertEqual(payload.distinctId, "user-42")
        XCTAssertEqual(payload.token, "proj_abc123")

        // Still just the one request - no double-posting.
        waitUntil(timeout: 0.3) { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testIdentifyWhenAlreadyIdentifiedPostsNothing() {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage()
        )
        client.identify("user-1")
        waitUntil { client.currentDistinctId == "user-1" }
        waitUntil { transport.requests.count == 1 }

        client.identify("user-2")
        waitUntil { client.currentDistinctId == "user-2" }

        waitUntil(timeout: 0.3) { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testIdentifyWithSameIdPostsNothing() {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage()
        )
        let anonId = client.currentDistinctId
        client.identify(anonId)
        waitUntil(timeout: 0.3) { true }

        XCTAssertEqual(transport.requests.count, 0)
        // Still anonymous: a same-id identify() is a true no-op, not a
        // backdoor way to flip the anonymous flag on the current id.
        XCTAssertEqual(client.currentDistinctId, anonId)
    }

    func testResetThenIdentifyAliasesNewAnonymousId() {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage()
        )
        let oldAnonId = client.currentDistinctId
        client.identify("user-1")
        waitUntil { client.currentDistinctId == "user-1" }
        waitUntil { transport.requests.count == 1 }

        client.reset()
        waitUntil { client.currentDistinctId != "user-1" }
        let newAnonId = client.currentDistinctId
        XCTAssertNotEqual(newAnonId, oldAnonId)

        client.identify("user-2")
        waitUntil { client.currentDistinctId == "user-2" }
        waitUntil { transport.requests.count == 2 }

        let payload = try! JSONDecoder().decode(AliasPayload.self, from: transport.requests[1].body)
        XCTAssertEqual(payload.alias, newAnonId)
        XCTAssertEqual(payload.distinctId, "user-2")
    }

    func testAliasFailureDoesNotBlockIdentitySwitch() {
        let transport = MockTransport(failuresRemaining: 1, failureStatus: 500)
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage()
        )
        client.identify("user-99")

        // The identity switch takes effect regardless of the /alias outcome.
        waitUntil { client.currentDistinctId == "user-99" }
        waitUntil { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests[0].path, "/alias")

        // Never retried: still just the one attempt after settling.
        waitUntil(timeout: 0.3) { transport.requests.count == 1 }
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Token

    func testTokenIsStampedOnTrackedEventProperties() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            token: "proj_abc123",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("Signed Up")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertEqual(events[0].properties["token"]?.stringValue, "proj_abc123")
    }

    func testTokenIsIncludedOnEngagePayloads() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            token: "proj_abc123",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.identify("user-9")
        waitUntil { client.currentDistinctId == "user-9" }
        client.people.set(["plan": "pro"])
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /engage.
        let payloads = engagePayloads(transport)
        XCTAssertEqual(payloads[0].token, "proj_abc123")
    }

    func testTokenIsOmittedWhenNotConfigured() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("No Token Event")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertNil(events[0].properties["token"])
    }

    // MARK: - People / engage

    func testPeopleSetSendsToEngage() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.identify("user-9")
        waitUntil { client.currentDistinctId == "user-9" }
        client.people.set(["plan": "pro"])
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /engage.
        let engageRequests = transport.requests.filter { $0.path == "/engage" }
        XCTAssertEqual(engageRequests.count, 1)
        let payloads = try! JSONDecoder().decode([EngagePayload].self, from: engageRequests[0].body)
        XCTAssertEqual(payloads[0].distinctId, "user-9")
        XCTAssertEqual(payloads[0].set?["plan"]?.stringValue, "pro")
    }

    // MARK: - Retry contract

    private func decodedEvents(_ data: Data) -> [TrackEvent] {
        (try? JSONDecoder().decode([TrackEvent].self, from: data)) ?? []
    }

    private func persistedQueue(_ storage: CohorlyStorage) -> [TrackEvent] {
        guard let raw = storage.string(forKey: "cohorly.event_queue"),
            let data = raw.data(using: .utf8)
        else { return [] }
        return decodedEvents(data)
    }

    private func persistedEngageQueue(_ storage: CohorlyStorage) -> [EngagePayload] {
        guard let raw = storage.string(forKey: "cohorly.engage_queue"),
            let data = raw.data(using: .utf8)
        else { return [] }
        return (try? JSONDecoder().decode([EngagePayload].self, from: data)) ?? []
    }

    func testKeepsQueueIntactOn429() async {
        let transport = MockTransport(
            failuresRemaining: 5, failureStatus: 429, failureRetryAfter: 60)
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 20
        )
        client.track("a")
        client.track("b")
        await client.flush()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(persistedQueue(storage).count, 2)
    }

    func testDropsBatchPermanentlyOn400() async {
        let transport = MockTransport(failuresRemaining: 1, failureStatus: 400)
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 20
        )
        client.track("a")
        client.track("b")
        await client.flush()
        XCTAssertEqual(transport.requests.count, 1)

        // Nothing left to send: batch was dropped, not re-queued.
        await client.flush()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(persistedQueue(storage).isEmpty)
    }

    func testHalvesBatchSizeOn413() async {
        let transport = MockTransport(failuresRemaining: 3, failureStatus: 413)
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 8
        )
        ["a", "b", "c", "d"].forEach { client.track($0) } // queue=4, below flushAt 8

        await client.flush() // batch 4, 413 -> halve 8->4
        XCTAssertEqual(persistedQueue(storage).count, 4) // nothing dropped
        await client.flush() // batch 4, 413 -> halve 4->2
        await client.flush() // batch 2, 413 -> halve 2->1
        await client.flush() // batch 1, success

        let sizes = transport.requests.map { decodedEvents($0.body).count }
        XCTAssertEqual(sizes, [4, 4, 2, 1])
    }

    func testBackoffSkipsAutoFlushButManualForces() async {
        let transport = MockTransport(
            failuresRemaining: 10, failureStatus: 429, failureRetryAfter: 60)
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("a") // size trigger -> auto flush attempt fails, sets backoff
        waitUntil { transport.requests.count == 1 }

        client.track("b") // size trigger -> auto flush blocked by backoff
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(transport.requests.count, 1)

        await client.flush() // manual flush forces an attempt despite backoff
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: - reset() vs an in-flight flush

    /// Keeps a request in flight for `delay` seconds and then fails, so a test
    /// can call `reset()` while a flush is genuinely pending.
    private final class DelayedFailingTransport: CohorlyTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requestCount = 0
        private let delay: TimeInterval

        init(delay: TimeInterval) { self.delay = delay }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _requestCount
        }

        func post(apiHost: String, path: String, body: Data) async throws {
            lock.lock()
            _requestCount += 1
            lock.unlock()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            throw CohorlyTransportError.httpError(status: 500, retryAfter: nil)
        }
    }

    func testResetDropsInFlightBatchInsteadOfRequeueing() async {
        let transport = DelayedFailingTransport(delay: 0.3)
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100  // no size trigger: the manual flush below is the only one
        )
        client.identify("user-a")
        client.track("private-a")
        client.people.set(["email": "a@example.com"])

        let flush = Task { await client.flush() }
        let deadline = Date().addingTimeInterval(2)
        while transport.requestCount == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(transport.requestCount, 0, "flush never started")

        client.reset()  // log out while the request is still in flight
        await flush.value

        // The requests failed (500), but their batches belong to the identity
        // the app asked to forget: they must not come back into the queue or
        // onto disk.
        XCTAssertTrue(persistedQueue(storage).isEmpty)
        XCTAssertTrue(persistedEngageQueue(storage).isEmpty)

        let sentBefore = transport.requestCount
        await client.flush()
        XCTAssertEqual(transport.requestCount, sentBefore, "forgotten batch was re-sent")
    }

    func testCapsQueueDroppingOldest() {
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: MockTransport(),
            storage: storage,
            flushInterval: 3600,
            flushAt: 100_000, // never auto-flush
            maxQueueSize: 3
        )
        ["a", "b", "c", "d", "e"].forEach { client.track($0) }
        waitUntil { self.persistedQueue(storage).count == 3 }

        XCTAssertEqual(persistedQueue(storage).map { $0.event }, ["c", "d", "e"])
    }

    // MARK: - Default device props

    func testDefaultDevicePropsPresentOnEvents() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("x")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        let props = events[0].properties
        XCTAssertEqual(props["$manufacturer"]?.stringValue, "Apple")
        XCTAssertEqual(props["$lib_version"]?.stringValue, "0.9.0")
        XCTAssertEqual(props["$lib"]?.stringValue, "ios")
        XCTAssertNotNil(props["$os"]?.stringValue)
        XCTAssertNotNil(props["$model"]?.stringValue)
    }

    // MARK: - Automatic events

    private func trackEvents(_ transport: MockTransport) -> [TrackEvent] {
        transport.requests.filter { $0.path == "/track" }.flatMap { decodedEvents($0.body) }
    }

    private func engagePayloads(_ transport: MockTransport) -> [EngagePayload] {
        transport.requests.filter { $0.path == "/engage" }.flatMap {
            (try? JSONDecoder().decode([EngagePayload].self, from: $0.body)) ?? []
        }
    }

    func testFirstOpenFiresOnceEver() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100
        )
        let ae = AutomaticEvents(client: client, storage: storage, clock: MutableClock())
        ae.start(currentVersion: "1.0")
        await client.flush()

        XCTAssertEqual(trackEvents(transport).filter { $0.event == "$ae_first_open" }.count, 1)
        // $ae_first_app_open_date is set once via engage.
        XCTAssertTrue(
            engagePayloads(transport).contains { $0.setOnce?["$ae_first_app_open_date"] != nil })

        // A second start against the same storage must not fire it again.
        let ae2 = AutomaticEvents(client: client, storage: storage, clock: MutableClock())
        ae2.start(currentVersion: "1.0")
        await client.flush()
        XCTAssertEqual(trackEvents(transport).filter { $0.event == "$ae_first_open" }.count, 1)
    }

    func testUpdatedFiresOnVersionChange() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        // Pre-seed so first-open is skipped and last version is "1.0".
        storage.setString("1", forKey: "cohorly.ae.did_first_open")
        storage.setString("1.0", forKey: "cohorly.ae.last_version")
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100
        )
        let ae = AutomaticEvents(client: client, storage: storage, clock: MutableClock())
        ae.start(currentVersion: "2.0")
        await client.flush()

        let updated = trackEvents(transport).filter { $0.event == "$ae_updated" }
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.properties["$ae_updated_version"]?.stringValue, "2.0")
    }

    func testUpdatedDoesNotFireOnSameVersion() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        storage.setString("1", forKey: "cohorly.ae.did_first_open")
        storage.setString("3.1", forKey: "cohorly.ae.last_version")
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100
        )
        let ae = AutomaticEvents(client: client, storage: storage, clock: MutableClock())
        ae.start(currentVersion: "3.1")
        await client.flush()

        XCTAssertTrue(trackEvents(transport).allSatisfy { $0.event != "$ae_updated" })
    }

    func testSessionLengthTrackedWhenAtLeastTenSeconds() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        storage.setString("1", forKey: "cohorly.ae.did_first_open")
        let clock = MutableClock()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100
        )
        let ae = AutomaticEvents(client: client, storage: storage, clock: clock)
        ae.beginSession()
        clock.advance(by: 15)
        ae.endSession()
        await client.flush()

        let sessions = trackEvents(transport).filter { $0.event == "$ae_session" }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.properties["$ae_session_length"]?.intValue, 15)
        // Both counters land in a single engage $add op: session count and the
        // cumulative session-length total.
        let addOps = engagePayloads(transport).compactMap { $0.add }
        XCTAssertTrue(addOps.contains {
            $0["$ae_total_app_sessions"]?.intValue == 1
                && $0["$ae_total_app_session_length"]?.intValue == 15
        })
    }

    func testShortSessionNotTracked() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        let clock = MutableClock()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 100
        )
        let ae = AutomaticEvents(client: client, storage: storage, clock: clock)
        ae.beginSession()
        clock.advance(by: 5)
        ae.endSession()
        await client.flush()

        XCTAssertTrue(trackEvents(transport).allSatisfy { $0.event != "$ae_session" })
    }

    // MARK: - Timed events

    func testTimeEventAttachesDurationOnNextTrack() async {
        let transport = MockTransport()
        let clock = MutableClock()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1,
            clock: clock
        )
        client.timeEvent("Level Completed")
        clock.advance(by: 7.5)
        client.track("Level Completed")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertEqual(events[0].properties["$duration"]?.doubleValue, 7.5)
    }

    func testDurationRoundsToThreeDecimals() async {
        let transport = MockTransport()
        let clock = MutableClock()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1,
            clock: clock
        )
        client.timeEvent("X")
        clock.advance(by: 1.23456)
        client.track("X")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertEqual(events[0].properties["$duration"]?.doubleValue, 1.235)
    }

    func testDurationOmittedWithoutTimeEvent() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("plain")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertNil(events[0].properties["$duration"])
    }

    func testTimedEventClearedAfterTrackAndByClear() async {
        let transport = MockTransport()
        let clock = MutableClock()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 2,
            clock: clock
        )
        // Timer clears on first track: a second track of the same event has no duration.
        client.timeEvent("Once")
        clock.advance(by: 3)
        client.track("Once")
        client.track("Once")
        await client.flush()
        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertEqual(events[0].properties["$duration"]?.doubleValue, 3)
        XCTAssertNil(events[1].properties["$duration"])

        // clearTimedEvent cancels a pending timer.
        client.timeEvent("Cancelled")
        client.clearTimedEvent("Cancelled")
        clock.advance(by: 5)
        client.timeEvent("Kept")
        clock.advance(by: 5)
        client.track("Cancelled")
        client.track("Kept")
        await client.flush()
        let more = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[1].body)
        XCTAssertNil(more.first { $0.event == "Cancelled" }?.properties["$duration"])
        XCTAssertEqual(more.first { $0.event == "Kept" }?.properties["$duration"]?.doubleValue, 5)
    }

    // MARK: - Default profile properties

    func testPeopleSetMergesDefaultProfilePropsWithUserKeysWinning() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.identify("user-9")
        waitUntil { client.currentDistinctId == "user-9" }
        // Supply a value that collides with a default key: the user value must win.
        client.people.set(["plan": "pro", "$ios_lib_version": "override"])
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /engage.
        let payloads = engagePayloads(transport)
        let set = payloads[0].set
        XCTAssertEqual(set?["plan"]?.stringValue, "pro")
        // Default parity props are merged in.
        XCTAssertEqual(set?["$swift_lib_version"]?.stringValue, "0.9.0")
        XCTAssertNotNil(set?["$ios_device_model"]?.stringValue)
        // User key overrides the default.
        XCTAssertEqual(set?["$ios_lib_version"]?.stringValue, "override")
    }

    // MARK: - Device id / user id stamping

    func testDeviceIdStampedAndEqualsAnonDistinctIdOnFreshInstall() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        let device = client.currentDeviceId
        // Fresh install: device id equals the anonymous distinct id.
        XCTAssertEqual(device, client.currentDistinctId)

        client.track("x")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertEqual(events[0].properties["$device_id"]?.stringValue, device)
    }

    func testUserIdOmittedWhileAnonymous() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.track("x")
        await client.flush()

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
        XCTAssertNil(events[0].properties["$user_id"])
        XCTAssertNotNil(events[0].properties["$device_id"])
    }

    func testDeviceIdSurvivesIdentifyAndUserIdStampedOnceIdentified() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        let deviceBefore = client.currentDeviceId
        client.identify("user-77")
        waitUntil { client.currentDistinctId == "user-77" }
        // Device id is unchanged by identify().
        XCTAssertEqual(client.currentDeviceId, deviceBefore)

        client.track("x")
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /track.
        let events = trackEvents(transport)
        XCTAssertEqual(events[0].properties["$device_id"]?.stringValue, deviceBefore)
        XCTAssertEqual(events[0].properties["$user_id"]?.stringValue, "user-77")
    }

    func testCallerSuppliedDeviceIdAndUserIdWin() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.identify("user-1")
        waitUntil { client.currentDistinctId == "user-1" }
        client.track("x", properties: ["$device_id": "custom-device", "$user_id": "custom-user"])
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /track.
        let events = trackEvents(transport)
        XCTAssertEqual(events[0].properties["$device_id"]?.stringValue, "custom-device")
        XCTAssertEqual(events[0].properties["$user_id"]?.stringValue, "custom-user")
    }

    func testResetMintsNewDeviceIdClearsTimersAndReanonymizes() async {
        let transport = MockTransport()
        let clock = MutableClock()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1,
            clock: clock
        )
        client.identify("user-1")
        waitUntil { client.currentDistinctId == "user-1" }
        let deviceBefore = client.currentDeviceId

        // Start a timer that reset() must cancel.
        client.timeEvent("Pending")
        client.reset()
        waitUntil { client.currentDeviceId != deviceBefore }

        // Fresh anon device id equals the new anon distinct id.
        XCTAssertEqual(client.currentDeviceId, client.currentDistinctId)

        // Timer was cleared: no $duration attached and back to anonymous ($user_id absent).
        clock.advance(by: 9)
        client.track("Pending")
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /track.
        let events = trackEvents(transport)
        XCTAssertNil(events[0].properties["$duration"])
        XCTAssertNil(events[0].properties["$user_id"])
        XCTAssertEqual(events[0].properties["$device_id"]?.stringValue, client.currentDeviceId)
    }

    func testMigratingInstallWithoutAnonymousFlagIsTreatedAsAnonymous() {
        // Pre-seed a stored distinct id with no anonymous flag (install predating
        // the flag) -> treated as anonymous: device id reuses the distinct id and
        // no false $user_id is stamped. Identified users self-heal on identify().
        let storage = InMemoryStorage()
        storage.setString("legacy-user", forKey: "cohorly.distinct_id")
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: MockTransport(),
            storage: storage
        )
        XCTAssertEqual(client.currentDistinctId, "legacy-user")
        XCTAssertEqual(client.currentDeviceId, "legacy-user")
        // Device id is persisted for stability across relaunches.
        XCTAssertEqual(storage.string(forKey: "cohorly.device_id"), client.currentDeviceId)
    }

    func testMigratingIdentifiedInstallMintsFreshDeviceId() {
        // Pre-seed a stored distinct id with the anonymous flag persisted as "0"
        // (identified) -> a fresh device id (not the distinct id) is minted.
        let storage = InMemoryStorage()
        storage.setString("legacy-user", forKey: "cohorly.distinct_id")
        storage.setString("0", forKey: "cohorly.anonymous")
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: MockTransport(),
            storage: storage
        )
        XCTAssertEqual(client.currentDistinctId, "legacy-user")
        XCTAssertNotEqual(client.currentDeviceId, "legacy-user")
        XCTAssertEqual(storage.string(forKey: "cohorly.device_id"), client.currentDeviceId)
    }

    func testPeopleSetOnceMergesDefaultProfileProps() async {
        let transport = MockTransport()
        let client = Cohorly(
            apiHost: "http://localhost:4000",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1
        )
        client.identify("user-7")
        waitUntil { client.currentDistinctId == "user-7" }
        client.people.setOnce(["signup_source": "web"])
        await client.flush()

        // identify() also fires a best-effort /alias post; isolate /engage.
        let payloads = engagePayloads(transport)
        let setOnce = payloads[0].setOnce
        XCTAssertEqual(setOnce?["signup_source"]?.stringValue, "web")
        XCTAssertEqual(setOnce?["$ios_lib_version"]?.stringValue, "0.9.0")
    }
}
