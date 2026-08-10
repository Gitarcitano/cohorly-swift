import XCTest

@testable import Cohorly

/// Stub flags fetcher: records every request body and replies with a
/// programmable JSON string (`nil` simulates a failed evaluation).
private final class MockFlagsFetcher: CohorlyFlagsFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [Data] = []
    private var _response: String?

    /// Hook run inside `fetchFlags`, before the response is returned. Lets a
    /// test mutate client state while a request is "in flight".
    var beforeReturn: (() -> Void)?

    init(response: String? = nil) {
        self._response = response
    }

    var requests: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var requestedDistinctIds: [String] {
        requests.compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["distinct_id"] as? String
        }
    }

    func setResponse(_ response: String?) {
        lock.lock(); _response = response; lock.unlock()
    }

    func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? {
        lock.lock()
        _requests.append(body)
        let response = _response
        let hook = beforeReturn
        lock.unlock()
        XCTAssertEqual(path, "/flags/evaluate")
        hook?()
        return response?.data(using: .utf8)
    }
}

private let sampleFlags = """
    {"flags":{
      "new-onboarding":{"enabled":true,"variant":null,"payload":null,"reason":"rollout"},
      "checkout-copy":{"enabled":true,"variant":"bold","payload":{"cta":"Buy now"},"reason":"cohort"},
      "legacy-nav":{"enabled":false,"variant":null,"payload":null,"reason":"default"}
    }}
    """

final class FeatureFlagsTests: XCTestCase {

    /// `loadFeatureFlags` defaults to false here so each test controls exactly
    /// when the first evaluation happens; the init-time load has its own test.
    private func makeClient(
        fetcher: CohorlyFlagsFetcher,
        storage: CohorlyStorage = InMemoryStorage(),
        loadFeatureFlags: Bool = false
    ) -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000",
            token: "test-token",
            transport: MockTransport(),
            storage: storage,
            flushInterval: 3600,
            flushAt: 100,
            flagsFetcher: fetcher,
            loadFeatureFlags: loadFeatureFlags
        )
    }

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

    // MARK: - Accessors

    func testReloadPopulatesAccessors() async {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher)

        // Unknown / unloaded flags read as false, never nil.
        XCTAssertEqual(client.getFeatureFlag("new-onboarding"), .bool(false))
        XCTAssertFalse(client.isFeatureEnabled("new-onboarding"))

        await client.reloadFeatureFlags()

        XCTAssertEqual(client.getFeatureFlag("new-onboarding"), .bool(true))
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        XCTAssertEqual(client.getFeatureFlag("legacy-nav"), .bool(false))
        XCTAssertEqual(client.getFeatureFlag("does-not-exist"), .bool(false))

        XCTAssertTrue(client.isFeatureEnabled("checkout-copy"))
        XCTAssertFalse(client.isFeatureEnabled("legacy-nav"))
        XCTAssertFalse(client.isFeatureEnabled("does-not-exist"))

        XCTAssertEqual(
            client.getFeatureFlagPayload("checkout-copy"),
            .object(["cta": .string("Buy now")]))
        XCTAssertNil(client.getFeatureFlagPayload("new-onboarding"))
        XCTAssertNil(client.getFeatureFlagPayload("does-not-exist"))
    }

    func testRequestBodyCarriesDistinctIdAndToken() async throws {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher)

        await client.reloadFeatureFlags()

        let data = try XCTUnwrap(fetcher.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["distinct_id"] as? String, client.currentDistinctId)
        XCTAssertEqual(body["token"] as? String, "test-token")
    }

    func testInitTriggersFirstEvaluation() {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher, loadFeatureFlags: true)

        waitUntil { client.isFeatureEnabled("new-onboarding") }
        XCTAssertEqual(fetcher.requestedDistinctIds, [client.currentDistinctId])
    }

    func testMalformedEntryIsSkippedNotFatal() async {
        // "broken" has a non-boolean `enabled` and "bare" omits enabled/reason
        // entirely: the first is skipped, the second decodes with defaults,
        // and the healthy entry always survives.
        let fetcher = MockFlagsFetcher(response: """
            {"flags":{
              "healthy":{"enabled":true,"variant":null,"payload":null,"reason":"rollout"},
              "broken":{"enabled":"yes","variant":null,"payload":null,"reason":"rollout"},
              "bare":{"variant":"b"}
            }}
            """)
        let client = makeClient(fetcher: fetcher)

        await client.reloadFeatureFlags()

        XCTAssertTrue(client.isFeatureEnabled("healthy"))
        XCTAssertEqual(client.getFeatureFlag("broken"), .bool(false))
        XCTAssertEqual(client.getFeatureFlag("bare"), .string("b"))
        XCTAssertFalse(client.isFeatureEnabled("bare"))
    }

    // MARK: - Persistence

    func testFlagsAreServedFromCacheOnRelaunch() async {
        let storage = InMemoryStorage()
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher, storage: storage)
        await client.reloadFeatureFlags()

        // Same storage = same distinct id: the relaunched client serves the
        // cache immediately, without any network call.
        let relaunched = makeClient(fetcher: MockFlagsFetcher(response: nil), storage: storage)
        XCTAssertEqual(relaunched.getFeatureFlag("checkout-copy"), .string("bold"))
        XCTAssertTrue(relaunched.isFeatureEnabled("new-onboarding"))
    }

    func testCacheForAnotherIdentityIsDiscarded() {
        let storage = InMemoryStorage()
        storage.setString("someone-else", forKey: "cohorly.distinct_id")
        storage.setString("0", forKey: "cohorly.anonymous")
        storage.setString(
            """
            {"distinct_id":"a-different-user","flags":{"checkout-copy":{"enabled":true,"variant":"bold","payload":null,"reason":"cohort"}}}
            """,
            forKey: "cohorly.flags")

        let client = makeClient(fetcher: MockFlagsFetcher(response: nil), storage: storage)

        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .bool(false))
        XCTAssertNil(storage.string(forKey: "cohorly.flags"))
    }

    // MARK: - Failure handling

    func testFailedReloadKeepsStaleFlags() async {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher)
        await client.reloadFeatureFlags()

        fetcher.setResponse(nil)
        await client.reloadFeatureFlags()
        XCTAssertTrue(client.isFeatureEnabled("new-onboarding"))

        fetcher.setResponse("not json at all")
        await client.reloadFeatureFlags()
        XCTAssertTrue(client.isFeatureEnabled("new-onboarding"))
    }

    // MARK: - Identity

    func testIdentifyReloadsFlagsForTheNewId() async {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher)

        client.identify("user-42")
        waitUntil { fetcher.requestedDistinctIds.contains("user-42") }
        waitUntil { client.isFeatureEnabled("new-onboarding") }
    }

    func testResetDropsFlagsBeforeRefreshing() async {
        let storage = InMemoryStorage()
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher, storage: storage)
        await client.reloadFeatureFlags()
        XCTAssertTrue(client.isFeatureEnabled("new-onboarding"))

        // The previous identity's flags must never leak to the new anonymous
        // id, so they are gone the moment reset() has been applied.
        fetcher.setResponse(nil)
        client.reset()
        waitUntil { storage.string(forKey: "cohorly.flags") == nil }
        XCTAssertFalse(client.isFeatureEnabled("new-onboarding"))
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .bool(false))
    }

    func testStaleResponseAfterIdentityChangeIsDiscarded() async {
        let storage = InMemoryStorage()
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher, storage: storage)
        let anonymousId = client.currentDistinctId

        // Change identity while the request is in flight: by the time it comes
        // back it describes a previous identity, so it must not be cached.
        fetcher.beforeReturn = { [weak fetcher] in
            fetcher?.beforeReturn = nil  // the nested reload must return normally
            client.identify("user-7")
            _ = client.currentDistinctId
        }
        await client.reloadFeatureFlags()

        waitUntil { storage.string(forKey: "cohorly.flags")?.contains("user-7") == true }
        XCTAssertFalse(storage.string(forKey: "cohorly.flags")?.contains(anonymousId) == true)
    }

    // MARK: - Listeners

    func testOnFeatureFlagsFiresOnReloadAndOnSubscribeWhenLoaded() async {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher)

        let counter = Counter()
        let unsubscribe = client.onFeatureFlags { flags in
            counter.record(flags.count)
        }
        // Nothing loaded yet: no immediate call.
        XCTAssertEqual(counter.calls, 0)

        await client.reloadFeatureFlags()
        XCTAssertEqual(counter.calls, 1)
        XCTAssertEqual(counter.lastCount, 3)

        // Subscribing after flags are loaded fires immediately.
        let late = Counter()
        client.onFeatureFlags { flags in late.record(flags.count) }
        XCTAssertEqual(late.calls, 1)

        unsubscribe()
        await client.reloadFeatureFlags()
        XCTAssertEqual(counter.calls, 1)
        XCTAssertEqual(late.calls, 2)
    }

    func testFailedReloadDoesNotNotifyListeners() async {
        let fetcher = MockFlagsFetcher(response: nil)
        let client = makeClient(fetcher: fetcher)
        let counter = Counter()
        client.onFeatureFlags { flags in counter.record(flags.count) }

        await client.reloadFeatureFlags()
        XCTAssertEqual(counter.calls, 0)
    }

    // MARK: - Exposure events

    private func makeExposureClient(
        fetcher: CohorlyFlagsFetcher,
        transport: MockTransport,
        sendExposureEvents: Bool = true
    ) -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000",
            token: "test-token",
            transport: transport,
            storage: InMemoryStorage(),
            flushInterval: 3600,
            flushAt: 1000,
            flagsFetcher: fetcher,
            loadFeatureFlags: false,
            sendExposureEvents: sendExposureEvents
        )
    }

    /// Every event handed to `/track` so far, in order.
    private func trackedEvents(_ transport: MockTransport) -> [TrackEvent] {
        transport.requests
            .filter { $0.path == "/track" }
            .flatMap { (try? JSONDecoder().decode([TrackEvent].self, from: $0.body)) ?? [] }
    }

    private func exposures(_ transport: MockTransport) -> [TrackEvent] {
        trackedEvents(transport).filter { $0.event == "$feature_flag_called" }
    }

    func testExposureIsTrackedOncePerValue() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()

        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        // Repeated reads, including via the other accessor, stay silent.
        _ = client.getFeatureFlag("checkout-copy")
        XCTAssertTrue(client.isFeatureEnabled("checkout-copy"))
        await client.flush()

        let events = exposures(transport)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.properties["$feature_flag"], .string("checkout-copy"))
        XCTAssertEqual(events.first?.properties["$feature_flag_response"], .string("bold"))
    }

    func testExposureReportsEnabledBooleanForPlainFlags() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()

        XCTAssertFalse(client.isFeatureEnabled("legacy-nav"))
        XCTAssertTrue(client.isFeatureEnabled("new-onboarding"))
        await client.flush()

        let events = exposures(transport)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].properties["$feature_flag"], .string("legacy-nav"))
        XCTAssertEqual(events[0].properties["$feature_flag_response"], .bool(false))
        XCTAssertEqual(events[1].properties["$feature_flag"], .string("new-onboarding"))
        XCTAssertEqual(events[1].properties["$feature_flag_response"], .bool(true))
    }

    func testExposureRefiresWhenTheValueChanges() async {
        let transport = MockTransport()
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeExposureClient(fetcher: fetcher, transport: transport)
        await client.reloadFeatureFlags()
        _ = client.getFeatureFlag("checkout-copy")

        fetcher.setResponse(
            """
            {"flags":{"checkout-copy":{"enabled":true,"variant":"calm","reason":"cohort"}}}
            """)
        await client.reloadFeatureFlags()
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("calm"))
        await client.flush()

        let events = exposures(transport)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].properties["$feature_flag"], .string("checkout-copy"))
        XCTAssertEqual(events[1].properties["$feature_flag_response"], .string("calm"))
    }

    func testExposureDedupeIsClearedByIdentify() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()
        _ = client.getFeatureFlag("checkout-copy")

        client.identify("user-42")
        waitUntil { client.currentDistinctId == "user-42" }
        waitUntil { client.currentFeatureFlags().count == 3 }

        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        await client.flush()
        XCTAssertEqual(exposures(transport).count, 2)
    }

    func testExposureDedupeIsClearedByReset() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()
        _ = client.getFeatureFlag("checkout-copy")
        await client.flush()
        XCTAssertEqual(exposures(transport).count, 1)

        // reset() drops the queue too, so the count starts over from here.
        client.reset()
        waitUntil { client.currentFeatureFlags().count == 3 }

        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        await client.flush()
        XCTAssertEqual(exposures(transport).count, 2)
    }

    func testExposureCanBeDisabled() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags),
            transport: transport,
            sendExposureEvents: false)
        await client.reloadFeatureFlags()

        _ = client.getFeatureFlag("checkout-copy")
        XCTAssertTrue(client.isFeatureEnabled("new-onboarding"))
        client.track("marker")
        await client.flush()

        XCTAssertEqual(trackedEvents(transport).map(\.event), ["marker"])
    }

    func testSilentReads() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()

        // Payload reads, bulk reads and unknown keys never report an exposure.
        _ = client.getFeatureFlagPayload("checkout-copy")
        _ = client.currentFeatureFlags()
        XCTAssertEqual(client.getFeatureFlag("does-not-exist"), .bool(false))
        XCTAssertFalse(client.isFeatureEnabled("does-not-exist"))
        client.track("marker")
        await client.flush()

        XCTAssertEqual(trackedEvents(transport).map(\.event), ["marker"])
    }
}

/// Thread-safe call recorder for listener assertions.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _lastCount = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var lastCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _lastCount
    }
    func record(_ count: Int) {
        lock.lock(); _calls += 1; _lastCount = count; lock.unlock()
    }
}
