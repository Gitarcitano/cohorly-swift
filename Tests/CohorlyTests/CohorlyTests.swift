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
}
