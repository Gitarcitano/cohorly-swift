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

/// Deterministic clock for driving the flag-cache TTL in tests.
private final class FlagTestClock: CohorlyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

final class FeatureFlagsTests: XCTestCase {

    /// `loadFeatureFlags` defaults to false here so each test controls exactly
    /// when the first evaluation happens; the init-time load has its own test.
    private func makeClient(
        fetcher: CohorlyFlagsFetcher,
        storage: CohorlyStorage = InMemoryStorage(),
        loadFeatureFlags: Bool = false,
        flagPersistence: FlagPersistenceMode = .persistenceUntilNetworkSuccess,
        flagCacheTTL: TimeInterval = Cohorly.defaultFlagCacheTTL,
        clock: CohorlyClock = SystemClock()
    ) -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000",
            token: "test-token",
            transport: MockTransport(),
            storage: storage,
            flushInterval: 3600,
            flushAt: 100,
            clock: clock,
            flagsFetcher: fetcher,
            loadFeatureFlags: loadFeatureFlags,
            flagPersistence: flagPersistence,
            flagCacheTTL: flagCacheTTL
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

    // MARK: - Lookup policies and TTL

    func testNetworkOnlyNeverReadsNorWritesTheCache() async {
        let storage = InMemoryStorage()
        let seeder = makeClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), storage: storage)
        await seeder.reloadFeatureFlags()
        let seeded = storage.string(forKey: "cohorly.flags")

        // Offline startup under networkOnly: nothing is served and the
        // seeded cache is left untouched.
        let fetcher = MockFlagsFetcher(response: nil)
        let client = makeClient(
            fetcher: fetcher, storage: storage, flagPersistence: .networkOnly)
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .bool(false))
        XCTAssertEqual(storage.string(forKey: "cohorly.flags"), seeded)

        // A network success serves values this session but persists nothing.
        fetcher.setResponse(sampleFlags)
        await client.reloadFeatureFlags()
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        XCTAssertEqual(client.getFeatureFlagDetails("checkout-copy").source, .network)
        XCTAssertEqual(storage.string(forKey: "cohorly.flags"), seeded)
    }

    func testNetworkFirstServesTheCacheLikePersistenceUntilNetworkSuccess() async {
        let storage = InMemoryStorage()
        let seeder = makeClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), storage: storage)
        await seeder.reloadFeatureFlags()

        // Offline relaunch under networkFirst: synchronous getters cannot
        // await the network, so - like the sibling SDKs - the valid cache is
        // served immediately, identically to persistenceUntilNetworkSuccess.
        let fetcher = MockFlagsFetcher(response: nil)
        let client = makeClient(
            fetcher: fetcher, storage: storage, flagPersistence: .networkFirst)
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        XCTAssertEqual(client.getFeatureFlagDetails("checkout-copy").source, .persistence)

        // The first network success still takes over and re-persists.
        fetcher.setResponse(sampleFlags)
        await client.reloadFeatureFlags()
        XCTAssertEqual(client.getFeatureFlagDetails("checkout-copy").source, .network)
    }

    func testPersistenceTransitionsToNetworkAfterSuccess() async {
        let storage = InMemoryStorage()
        let seeder = makeClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), storage: storage)
        await seeder.reloadFeatureFlags()

        // Offline relaunch serves the persisted cache...
        let fetcher = MockFlagsFetcher(response: nil)
        let client = makeClient(fetcher: fetcher, storage: storage)
        XCTAssertEqual(client.getFeatureFlagDetails("checkout-copy").source, .persistence)

        // ...until the first network success takes over and re-persists.
        fetcher.setResponse(sampleFlags)
        await client.reloadFeatureFlags()
        var details = client.getFeatureFlagDetails("checkout-copy")
        XCTAssertEqual(details.source, .network)
        XCTAssertNil(details.persistedAt)

        // A later failure keeps the network values; the older cache is never
        // a downgrade target once the network has answered this session.
        fetcher.setResponse(nil)
        await client.reloadFeatureFlags()
        details = client.getFeatureFlagDetails("checkout-copy")
        XCTAssertEqual(details.source, .network)
        XCTAssertEqual(details.value, .string("bold"))
    }

    func testExpiredCacheIsServedUnderPunsButDroppedUnderNetworkFirst() async {
        let storage = InMemoryStorage()
        let clock = FlagTestClock()
        let seeder = makeClient(
            fetcher: MockFlagsFetcher(response: sampleFlags),
            storage: storage,
            clock: clock)
        await seeder.reloadFeatureFlags()

        // Past the TTL but inside the 7-day stale window: PUNS trades
        // freshness for availability, so the expired cache still serves
        // (source .persistence, real persistedAt, configured ttlMs).
        clock.advance(by: Cohorly.defaultFlagCacheTTL + 1)
        let punsClient = makeClient(
            fetcher: MockFlagsFetcher(response: nil), storage: storage, clock: clock)
        let details = punsClient.getFeatureFlagDetails("checkout-copy")
        XCTAssertEqual(details.value, .string("bold"))
        XCTAssertEqual(details.source, .persistence)
        XCTAssertEqual(
            details.persistedAt, Int(clock.now().timeIntervalSince1970 * 1000)
                - Int(Cohorly.defaultFlagCacheTTL * 1000) - 1000)
        XCTAssertEqual(details.ttlMs, Int(Cohorly.defaultFlagCacheTTL * 1000))

        // networkFirst is strict: the same expired cache is dropped instead.
        let firstClient = makeClient(
            fetcher: MockFlagsFetcher(response: nil),
            storage: storage,
            flagPersistence: .networkFirst,
            clock: clock)
        XCTAssertEqual(firstClient.getFeatureFlag("checkout-copy"), .bool(false))
        XCTAssertNil(storage.string(forKey: "cohorly.flags"))
    }

    func testCacheOlderThanSevenDaysIsDropped() async {
        let storage = InMemoryStorage()
        let clock = FlagTestClock()
        let seeder = makeClient(
            fetcher: MockFlagsFetcher(response: sampleFlags),
            storage: storage,
            clock: clock)
        await seeder.reloadFeatureFlags()

        // Past the 7-day stale window even PUNS refuses it.
        clock.advance(by: Cohorly.flagCacheMaxStale + 1)
        let client = makeClient(
            fetcher: MockFlagsFetcher(response: nil), storage: storage, clock: clock)
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .bool(false))
        XCTAssertNil(storage.string(forKey: "cohorly.flags"))
    }

    func testLegacyCacheWithoutTimestampIsServed() {
        let storage = InMemoryStorage()
        storage.setString("user-1", forKey: "cohorly.distinct_id")
        storage.setString("0", forKey: "cohorly.anonymous")
        // Written by a pre-TTL SDK: no stored_at means the age cannot be
        // proven, so the cache is served (graceful upgrade - pre-TTL
        // behavior served it indefinitely) until a successful reload
        // rewrites it in the stamped format.
        storage.setString(
            """
            {"distinct_id":"user-1","flags":{"checkout-copy":{"enabled":true,"variant":"bold","payload":null,"reason":"cohort"}}}
            """,
            forKey: "cohorly.flags")

        let client = makeClient(fetcher: MockFlagsFetcher(response: nil), storage: storage)

        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        let details = client.getFeatureFlagDetails("checkout-copy")
        XCTAssertEqual(details.source, .persistence)
        // Unprovable age: persistedAt stays absent, ttlMs is still reported.
        XCTAssertNil(details.persistedAt)
        XCTAssertEqual(details.ttlMs, Int(Cohorly.defaultFlagCacheTTL * 1000))
        // The v1 entry is kept on disk - a successful reload replaces it.
        XCTAssertNotNil(storage.string(forKey: "cohorly.flags"))
    }

    func testFutureStoredAtIsNormalizedToNow() {
        let storage = InMemoryStorage()
        storage.setString("user-1", forKey: "cohorly.distinct_id")
        storage.setString("0", forKey: "cohorly.anonymous")
        // Clock moved backwards after the write: a raw negative age would
        // satisfy every bound indefinitely, so the stamp is normalized to
        // now on adoption and the entry ages from here.
        let futureMs =
            Int(Date().timeIntervalSince1970 * 1000) + 365 * 24 * 60 * 60 * 1000
        let cache = "{\"distinct_id\":\"user-1\",\"flags\":{\"checkout-copy\":{\"enabled\":true,\"variant\":\"bold\",\"payload\":null,\"reason\":\"cohort\"}},\"stored_at\":\(futureMs)}"
        storage.setString(cache, forKey: "cohorly.flags")

        let client = makeClient(
            fetcher: MockFlagsFetcher(response: nil),
            storage: storage,
            flagPersistence: .networkFirst)
        XCTAssertEqual(
            client.getFeatureFlagDetails("checkout-copy").source, .persistence)
        let rewritten = storage.string(forKey: "cohorly.flags")
        XCTAssertNotNil(rewritten)
        XCTAssertFalse(rewritten?.contains("\"stored_at\":\(futureMs)") ?? true)
    }

    func testIdentifyDropsPreviousFlagsBeforeReload() async {
        let storage = InMemoryStorage()
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher, storage: storage)
        await client.reloadFeatureFlags()
        XCTAssertTrue(client.isFeatureEnabled("new-onboarding"))

        // The previous identity's flags must never leak to the new one:
        // memory and disk are cleared before the new id's reload lands.
        fetcher.setResponse(nil)
        client.identify("user-9")
        waitUntil { storage.string(forKey: "cohorly.flags") == nil }
        waitUntil { fetcher.requestedDistinctIds.contains("user-9") }
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .bool(false))
        XCTAssertFalse(client.isFeatureEnabled("new-onboarding"))
    }

    // MARK: - Details and explicit fallbacks

    func testFlagDetailsReportSourceAndTimestamps() async {
        let storage = InMemoryStorage()
        let clock = FlagTestClock()
        let seeder = makeClient(
            fetcher: MockFlagsFetcher(response: sampleFlags),
            storage: storage,
            clock: clock)
        await seeder.reloadFeatureFlags()

        // Network-served values report source .network and no cache metadata.
        let network = seeder.getFeatureFlagDetails("checkout-copy")
        XCTAssertEqual(network.value, .string("bold"))
        XCTAssertEqual(network.source, .network)
        XCTAssertNil(network.persistedAt)
        XCTAssertNil(network.ttlMs)

        // Persistence-served values carry when they were stored and the TTL.
        let cached = makeClient(
            fetcher: MockFlagsFetcher(response: nil), storage: storage, clock: clock)
        let persisted = cached.getFeatureFlagDetails("checkout-copy")
        XCTAssertEqual(persisted.value, .string("bold"))
        XCTAssertEqual(persisted.source, .persistence)
        XCTAssertEqual(
            persisted.persistedAt, Int(clock.now().timeIntervalSince1970 * 1000))
        XCTAssertEqual(persisted.ttlMs, Int(Cohorly.defaultFlagCacheTTL * 1000))

        // Unknown flags resolve to the caller's fallback, sourced .fallback.
        let missing = seeder.getFeatureFlagDetails("does-not-exist", fallback: "control")
        // A truthy fallback reports enabled = true, like Boolean("control").
        XCTAssertEqual(
            missing,
            FlagDetails(
                key: "does-not-exist",
                value: .string("control"),
                enabled: true,
                payload: nil,
                source: .fallback))
    }

    func testExplicitFallbacks() async {
        let client = makeClient(fetcher: MockFlagsFetcher(response: sampleFlags))
        await client.reloadFeatureFlags()

        XCTAssertEqual(
            client.getFeatureFlag("does-not-exist", fallback: "control"), .string("control"))
        XCTAssertTrue(client.isFeatureEnabled("does-not-exist", fallback: true))
        // Known flags ignore the fallback entirely.
        XCTAssertEqual(
            client.getFeatureFlag("checkout-copy", fallback: "control"), .string("bold"))
        XCTAssertFalse(client.isFeatureEnabled("legacy-nav", fallback: true))
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
        // Emissions are delivered on the serial notify queue - committed
        // before reloadFeatureFlags() returns, delivered right after.
        waitUntil { counter.calls == 1 }
        XCTAssertEqual(counter.lastCount, 3)

        // Subscribing after flags are loaded fires immediately.
        let late = Counter()
        client.onFeatureFlags { flags in late.record(flags.count) }
        XCTAssertEqual(late.calls, 1)

        unsubscribe()
        await client.reloadFeatureFlags()
        waitUntil { late.calls == 2 }
        XCTAssertEqual(counter.calls, 1)
    }

    func testFailedReloadDoesNotNotifyListeners() async {
        let fetcher = MockFlagsFetcher(response: nil)
        let client = makeClient(fetcher: fetcher)
        let counter = Counter()
        client.onFeatureFlags { flags in counter.record(flags.count) }

        await client.reloadFeatureFlags()
        XCTAssertEqual(counter.calls, 0)
    }

    func testIdentityClearsNotifyListenersWithAnEmptySet() async {
        let fetcher = MockFlagsFetcher(response: sampleFlags)
        let client = makeClient(fetcher: fetcher)
        await client.reloadFeatureFlags()

        let counter = Counter()
        client.onFeatureFlags { flags in counter.record(flags.count) }
        // Loaded already: the subscription itself fires once.
        XCTAssertEqual(counter.counts, [3])

        // identify() drops the served set first (empty emission), then the
        // new identity's reload repopulates it.
        client.identify("user-9")
        waitUntil { counter.calls == 3 }
        XCTAssertEqual(counter.counts, [3, 0, 3])

        // reset() likewise emits the empty set before the fresh anonymous
        // id's reload lands.
        client.reset()
        waitUntil { counter.calls == 5 }
        XCTAssertEqual(counter.counts, [3, 0, 3, 0, 3])
    }

    // MARK: - Exposure events

    private func makeExposureClient(
        fetcher: CohorlyFlagsFetcher,
        transport: MockTransport,
        sendExposureEvents: Bool = true,
        storage: CohorlyStorage = InMemoryStorage(),
        flagPersistence: FlagPersistenceMode = .persistenceUntilNetworkSuccess
    ) -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000",
            token: "test-token",
            transport: transport,
            storage: storage,
            flushInterval: 3600,
            flushAt: 1000,
            flagsFetcher: fetcher,
            loadFeatureFlags: false,
            sendExposureEvents: sendExposureEvents,
            flagPersistence: flagPersistence
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

    // MARK: - Exposure source

    func testNetworkExposureReportsNetworkSource() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()

        _ = client.getFeatureFlag("checkout-copy")
        await client.flush()

        XCTAssertEqual(
            exposures(transport).first?.properties["$feature_flag_source"],
            .string("network"))
    }

    func testPersistenceExposureReportsPersistenceSourceOnce() async {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        let seeder = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags),
            transport: MockTransport(),
            storage: storage)
        await seeder.reloadFeatureFlags()

        // Offline relaunch: the exposure reports source "persistence".
        let fetcher = MockFlagsFetcher(response: nil)
        let client = makeExposureClient(
            fetcher: fetcher, transport: transport, storage: storage)
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))

        // The same value arriving over the network does NOT re-report: dedupe
        // keys on (key, value), not on source.
        fetcher.setResponse(sampleFlags)
        await client.reloadFeatureFlags()
        XCTAssertEqual(client.getFeatureFlag("checkout-copy"), .string("bold"))
        await client.flush()

        let events = exposures(transport)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            events.first?.properties["$feature_flag_source"], .string("persistence"))
    }

    func testFallbackReadsDoNotExpose() async {
        let transport = MockTransport()
        let client = makeExposureClient(
            fetcher: MockFlagsFetcher(response: sampleFlags), transport: transport)
        await client.reloadFeatureFlags()

        // Reads that resolve to the fallback assign nothing, so they report
        // no exposure - through any of the flag getters.
        XCTAssertEqual(
            client.getFeatureFlag("does-not-exist", fallback: "control"),
            .string("control"))
        XCTAssertTrue(client.isFeatureEnabled("does-not-exist", fallback: true))
        XCTAssertEqual(
            client.getFeatureFlagDetails("does-not-exist").source, .fallback)
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
    private var _counts: [Int] = []

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var lastCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _lastCount
    }
    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _counts
    }
    func record(_ count: Int) {
        lock.lock(); _calls += 1; _lastCount = count; _counts.append(count); lock.unlock()
    }
}
