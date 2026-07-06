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

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].path, "/track")

        let events = try! JSONDecoder().decode([TrackEvent].self, from: transport.requests[0].body)
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

        let payloads = try! JSONDecoder().decode([EngagePayload].self, from: transport.requests[0].body)
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

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].path, "/engage")
        let payloads = try! JSONDecoder().decode([EngagePayload].self, from: transport.requests[0].body)
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
        XCTAssertEqual(props["$lib_version"]?.stringValue, "0.1.0")
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
        // Total sessions incremented via engage $add.
        XCTAssertTrue(
            engagePayloads(transport).contains { $0.add?["$ae_total_app_sessions"]?.intValue == 1 })
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
}
