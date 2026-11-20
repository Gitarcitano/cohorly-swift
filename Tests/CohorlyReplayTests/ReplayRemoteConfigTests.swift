import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// `CohorlyReplayConfig.remoteConfig` (VEL-2234): the settings saved in the
/// dashboard, their cache, the pending session and the minimum duration.
final class ReplayRemoteConfigTests: XCTestCase {
    private var harness: ReplayHarness!

    override func setUp() {
        super.setUp()
        ReplayChunkQueue.resetProcessGone()
        ReplayRemoteConfigLoader.resetInFlight()
        harness = ReplayHarness()
    }

    override func tearDown() {
        harness.transport.releaseConfig()
        harness.transport.release()
        CohorlyReplay.uninstall()
        harness = nil
        ReplayRemoteConfigLoader.resetInFlight()
        ReplayChunkQueue.resetProcessGone()
        super.tearDown()
    }

    private var nowMs: Int64 { ReplaySessionStore.ms(harness.clock.now()) }
    private var configKey: String { ReplayRemoteConfigLoader.storageKey(ReplayHarness.namespace()) }

    /// Writes a cached copy as an earlier launch would have left it.
    private func plantConfig(_ config: String, fetchedAt: Int64) {
        harness.storage.setString(#"{"fetchedAt":\#(fetchedAt),"config":\#(config)}"#, forKey: configKey)
    }

    /// The cached copy as stored: when it was fetched and its sample rate.
    private func cachedCopy() -> (fetchedAt: Int64, sampleRate: Double?)? {
        guard let raw = harness.storage.string(forKey: configKey),
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let fetchedAt = (object["fetchedAt"] as? NSNumber)?.int64Value,
              let config = object["config"] as? [String: Any]
        else { return nil }
        return (fetchedAt, (config["sampleRate"] as? NSNumber)?.doubleValue)
    }

    private func answer(_ config: String) -> ScriptedReply {
        .status(200, body: #"{"config":\#(config)}"#)
    }

    private func parse(_ json: String) -> RemoteReplayConfig? {
        RemoteReplayConfig.parse(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    private func makeLoader(storage: CohorlyStorage? = nil) -> ReplayRemoteConfigLoader {
        let clock = harness.clock
        return ReplayRemoteConfigLoader(
            url: URL(string: "https://ingest.example.com/replay/config?token=tok_1")!,
            namespace: ReplayHarness.namespace(), storage: storage ?? harness.storage, clock: clock,
            transport: harness.transport, schedule: harness.configTimers.schedule,
            monotonicNow: { clock.now().timeIntervalSince1970 })
    }

    // MARK: - Parsing

    func testEachFieldIsReadOnItsOwnAndInvalidValuesCountAsNotSaved() throws {
        let valid = try XCTUnwrap(parse(#"{"sampleRate":1,"onErrorSampleRate":0,"minDurationMs":2500,"triggers":[{"type":"event"}],"other":3}"#))
        XCTAssertEqual(valid, RemoteReplayConfig(sampleRate: 1, onErrorSampleRate: 0, minDurationMs: 2500))

        let invalid = try XCTUnwrap(parse(#"{"sampleRate":"0.5","onErrorSampleRate":true,"minDurationMs":-1}"#))
        XCTAssertEqual(invalid, RemoteReplayConfig(), "a string, a boolean and a negative duration are not saved")

        let outOfRange = try XCTUnwrap(parse(#"{"sampleRate":1.5,"onErrorSampleRate":-0.1,"minDurationMs":null}"#))
        XCTAssertEqual(outOfRange, RemoteReplayConfig())

        let boolean = try XCTUnwrap(parse(#"{"sampleRate":true,"onErrorSampleRate":false}"#))
        XCTAssertNil(boolean.sampleRate, "a JSON true is never the rate 1")
        XCTAssertNil(boolean.onErrorSampleRate)

        XCTAssertEqual(parse(#"{"minDurationMs":45000}"#)?.minDurationMs, 30000, "capped at 30 s")
        XCTAssertNil(parse("[1]"))
    }

    func testASavedFieldWinsAndAnUnsavedOneKeepsTheCodeValue() {
        let code = CohorlyReplayConfig(sampleRate: 0.5, onErrorSampleRate: 1)
        let effective = ReplayEffectiveConfig(code: code, remote: RemoteReplayConfig(onErrorSampleRate: 0, minDurationMs: 2000))
        XCTAssertEqual(effective.sampleRate, 0.5)
        XCTAssertEqual(effective.onErrorSampleRate, 0)
        XCTAssertEqual(effective.minDurationMs, 2000)
        XCTAssertEqual(ReplayEffectiveConfig(code: code, remote: nil).minDurationMs, 0, "the code has no minimum duration")
    }

    func testTheRequestURLCarriesThePercentEncodedToken() {
        XCTAssertEqual(
            ReplayRemoteConfigLoader.configURL(host: "https://a.example.com/", token: "t/k+1 &=")?.absoluteString,
            "https://a.example.com/replay/config?token=t%2Fk%2B1%20%26%3D")
    }

    // MARK: - When a request is made

    func testOffSendsNoRequestAndDecidesWithTheCode() async throws {
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1))
        XCTAssertFalse(runtime.sessions.session.pending)
        XCTAssertEqual(runtime.sessions.session.mode, .session)
        runtime.sessions.rotate()
        XCTAssertEqual(harness.configTimers.pending(after: 3), 0, "no load was started")
        let requested = await eventually(timeout: 0.3) { !self.harness.transport.configRequests.isEmpty }
        XCTAssertFalse(requested)
    }

    func testAFreshCopyDecidesAtOnceWithoutARequest() async throws {
        plantConfig(#"{"sampleRate":0}"#, fetchedAt: nowMs - 10 * 60 * 1000)
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1, remoteConfig: true))
        XCTAssertFalse(runtime.sessions.session.pending)
        XCTAssertEqual(runtime.sessions.session.mode, .off, "the saved rate 0 wins over the code's 1")
        XCTAssertEqual(harness.configTimers.pending(after: 3), 0)
        let requested = await eventually(timeout: 0.3) { !self.harness.transport.configRequests.isEmpty }
        XCTAssertFalse(requested)
    }

    func testAnExpiredCopySendsARequestAndItsAnswerDecidesThePendingSession() async throws {
        plantConfig(#"{"sampleRate":0}"#, fetchedAt: nowMs - 3_600_000)
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":1,"minDurationMs":2000}"#)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        let born = runtime.sessions.session
        XCTAssertTrue(born.pending)
        harness.transport.releaseConfig()

        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(harness.transport.configRequests.map(\.absoluteString),
                       ["https://ingest.example.com/replay/config?token=tok_1"])
        let session = runtime.sessions.session
        XCTAssertEqual(session.id, born.id, "the pending session is decided, not replaced")
        XCTAssertEqual(session.mode, .session)
        XCTAssertEqual(session.minDurationMs, 2000)
        XCTAssertEqual(cachedCopy()?.fetchedAt, nowMs)
        XCTAssertEqual(cachedCopy()?.sampleRate, 1)
    }

    func testAFutureFetchedAtIsNoCopy() async throws {
        plantConfig(#"{"sampleRate":0}"#, fetchedAt: nowMs + 60_000)
        XCTAssertNil(makeLoader().stored(nowMs: nowMs))
        harness.transport.holdConfig()
        harness.transport.replyConfig([.networkError])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1, remoteConfig: true))
        XCTAssertTrue(runtime.sessions.session.pending)
        harness.transport.releaseConfig()
        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(harness.transport.configRequests.count, 1)
        XCTAssertEqual(runtime.sessions.session.mode, .session, "no copy to fall back on: the code's rate 1")
    }

    func testACopyOfAnotherProjectIsNotUsed() async throws {
        plantConfig(#"{"sampleRate":0}"#, fetchedAt: nowMs)
        harness.transport.holdConfig()
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(token: "tok_2"), sampleRate: 1, remoteConfig: true))
        XCTAssertTrue(runtime.sessions.session.pending, "tok_1's fresh copy does not decide tok_2's session")
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        XCTAssertEqual(harness.transport.configRequests.map(\.absoluteString),
                       ["https://ingest.example.com/replay/config?token=tok_2"])
    }

    // MARK: - No credentials

    func testTheRequestIsAPlainGetWithoutCredentials() async throws {
        _ = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1, remoteConfig: true))
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        let request = try XCTUnwrap(harness.transport.configURLRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTheConfigSessionStoresNoCookieCredentialOrAnswer() throws {
        let session = URLSessionReplayTransport.makeConfigSession()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(session.delegate is ReplayConfigSessionDelegate)
    }

    func testEveryCredentialChallengeIsCancelledAndOnlyServerTrustIsChecked() {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
                       NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault] {
            XCTAssertEqual(ReplayConfigSessionDelegate.disposition(for: method), .cancelAuthenticationChallenge, method)
        }
        XCTAssertEqual(ReplayConfigSessionDelegate.disposition(for: NSURLAuthenticationMethodServerTrust),
                       .performDefaultHandling)
    }

    // MARK: - Failures and the 3 s wait

    func testAFailureFallsBackToTheExpiredCopyAndWritesNothing() async throws {
        plantConfig(#"{"sampleRate":0}"#, fetchedAt: nowMs - 2 * 3_600_000)
        let before = harness.storage.string(forKey: configKey)
        harness.transport.replyConfig([.status(500)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1, remoteConfig: true))
        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(runtime.sessions.session.mode, .off, "the expired copy's rate 0, not the code's 1")
        XCTAssertEqual(harness.storage.string(forKey: configKey), before)
    }

    func testAFailureWithoutACopyFallsBackToTheCode() async throws {
        harness.transport.replyConfig([.status(200, body: "not json")])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1, remoteConfig: true))
        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(runtime.sessions.session.mode, .session)
        XCTAssertNil(harness.storage.string(forKey: configKey))
    }

    func testTheTimeoutDecidesWithTheExpiredCopyAndALateAnswerOnlyUpdatesTheCache() async throws {
        plantConfig(#"{"sampleRate":1}"#, fetchedAt: nowMs - 2 * 3_600_000)
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0}"#)])
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly, sampleRate: 0, remoteConfig: true))
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        XCTAssertTrue(runtime.sessions.session.pending)

        harness.configTimers.fire(after: 3)
        let session = runtime.sessions.session
        XCTAssertFalse(session.pending)
        XCTAssertEqual(session.mode, .session, "the expired copy's rate 1")

        harness.clock.advance(by: 5)
        harness.transport.releaseConfig()
        let cached = await eventually { self.cachedCopy()?.sampleRate == 0 }
        XCTAssertTrue(cached, "the late answer refreshes the cache")
        XCTAssertEqual(runtime.sessions.session, session, "the live session keeps its mode")
    }

    func testTheTimeoutWithoutACopyDecidesWithTheCode() async throws {
        harness.transport.holdConfig()
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, onErrorSampleRate: 1, remoteConfig: true))
        XCTAssertTrue(runtime.sessions.session.pending)
        harness.configTimers.fire(after: 3)
        XCTAssertEqual(runtime.sessions.session.mode, .error)
        XCTAssertEqual(runtime.sessions.session.minDurationMs, 0)
    }

    func testAnAnswerAfterTheAbortWritesNothing() async throws {
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0}"#)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 1, remoteConfig: true))
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        harness.configTimers.fire(after: 3)
        harness.configTimers.fire(after: 30)
        XCTAssertFalse(runtime.sessions.session.pending, "decided by the 3 s wait")
        harness.transport.releaseConfig()
        let written = await eventually(timeout: 0.3) { self.harness.storage.string(forKey: self.configKey) != nil }
        XCTAssertFalse(written, "an answer after the abort is dropped")
    }

    func testEveryKindOfFailureFallsBackToTheExpiredCopyAndWritesNothing() async {
        let failures: [ScriptedReply] = [
            .status(401), .status(500), .status(200, body: "not json"), .status(200, body: "{}"),
            .status(200, body: #"{"config":1}"#), .networkError
        ]
        for (index, failure) in failures.enumerated() {
            plantConfig(#"{"sampleRate":0.5}"#, fetchedAt: nowMs - 2 * 3_600_000)
            let before = harness.storage.string(forKey: configKey)
            harness.transport.replyConfig([failure])
            let results = Results()
            XCTAssertEqual(makeLoader().lookup { results.append($0) }, .loading)
            let finished = await eventually { results.count == 1 }
            XCTAssertTrue(finished, "failure \(index)")
            XCTAssertEqual(results.values, [RemoteReplayConfig(sampleRate: 0.5)], "failure \(index)")
            XCTAssertEqual(harness.storage.string(forKey: configKey), before, "failure \(index)")
        }
        XCTAssertEqual(harness.transport.configRequests.count, failures.count)
    }

    func testTheAbortCancelsTheRequest() async {
        harness.transport.holdConfig()
        let results = Results()
        XCTAssertEqual(makeLoader().lookup { results.append($0) }, .loading)
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        harness.configTimers.fire(after: 30)
        let cancelled = await eventually { self.harness.transport.configCancellations == 1 }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(results.values, [nil])
    }

    // MARK: - Deadlines follow the clock, not the timers

    func testALoadPastItsThreeSecondsGetsItsFallbackEvenBeforeItsTimerRuns() async {
        plantConfig(#"{"sampleRate":1}"#, fetchedAt: nowMs - 2 * 3_600_000)
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0}"#)])
        let results = Results()
        XCTAssertEqual(makeLoader().lookup { results.append($0) }, .loading)
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)

        harness.clock.advance(by: 3.5)
        harness.transport.releaseConfig()
        let finished = await eventually { results.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(results.values, [RemoteReplayConfig(sampleRate: 1)], "3.5 s waited: the expired copy, not the answer")
        XCTAssertEqual(cachedCopy()?.sampleRate, 0, "an answer within 30 s still refreshes the cache")
    }

    func testAnAnswerThirtySecondsAfterTheRequestBeganIsDroppedEvenBeforeTheAbortRuns() async {
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0}"#)])
        let results = Results()
        XCTAssertEqual(makeLoader().lookup { results.append($0) }, .loading)
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)

        harness.clock.advance(by: 31)
        harness.transport.releaseConfig()
        let finished = await eventually { results.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(results.values, [nil], "the answer decides nothing")
        XCTAssertNil(harness.storage.string(forKey: configKey), "and is never cached")
    }

    func testAJoinedLoadWaitsItsOwnThreeSeconds() async {
        plantConfig(#"{"sampleRate":1}"#, fetchedAt: nowMs - 2 * 3_600_000)
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0}"#)])
        let loader = makeLoader()
        let first = Results()
        let joined = Results()
        XCTAssertEqual(loader.lookup { first.append($0) }, .loading)
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        harness.clock.advance(by: 2.5)
        XCTAssertEqual(loader.lookup { joined.append($0) }, .loading)
        harness.clock.advance(by: 1)

        harness.transport.releaseConfig()
        let finished = await eventually { first.count == 1 && joined.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(first.values, [RemoteReplayConfig(sampleRate: 1)], "3.5 s since it began")
        XCTAssertEqual(joined.values, [RemoteReplayConfig(sampleRate: 0)], "1 s since it joined")
        XCTAssertEqual(harness.transport.configRequests.count, 1)
    }

    // MARK: - The cache

    func testAnAnswerNeverReplacesACopyWrittenAfterItsRequestBegan() async throws {
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0.75}"#)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)

        harness.clock.advance(by: 1)
        let newer = nowMs
        plantConfig(#"{"sampleRate":0.25}"#, fetchedAt: newer)
        harness.transport.releaseConfig()
        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(cachedCopy()?.fetchedAt, newer)
        XCTAssertEqual(cachedCopy()?.sampleRate, 0.25)
    }

    func testAtMostOneRequestIsInFlightAndConcurrentLoadsShareIt() async {
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":0.5}"#)])
        let results = Results()
        XCTAssertEqual(makeLoader().lookup { results.append($0) }, .loading)
        XCTAssertEqual(makeLoader().lookup { results.append($0) }, .loading, "another loader of the same project joins it")
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        harness.transport.releaseConfig()
        let both = await eventually { results.count == 2 }
        XCTAssertTrue(both)
        XCTAssertEqual(results.values, [RemoteReplayConfig(sampleRate: 0.5), RemoteReplayConfig(sampleRate: 0.5)])
        XCTAssertEqual(harness.transport.configRequests.count, 1)
    }

    func testAReinstallWhileARequestRunsJoinsIt() async throws {
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":1}"#)])
        _ = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        let again = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        XCTAssertTrue(again.sessions.session.pending)
        let second = await harness.transport.waitForConfigRequests(2, timeout: 0.3)
        XCTAssertFalse(second, "the new install joins the request in flight")

        harness.transport.releaseConfig()
        let decided = await eventually { !again.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(again.sessions.session.mode, .session)
        XCTAssertEqual(harness.transport.configRequests.count, 1)
    }

    /// The answer lands between a new session's cache read and its decision
    /// to start a request: with the two in one step it joins the request
    /// instead of starting a second one.
    func testAnAnswerLandingRightAfterTheCacheReadIsJoinedNotRequestedAgain() async {
        let storage = ReadHookStorage(watching: configKey)
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":1}"#)])
        let settings = ReplayRemoteSettings(
            code: CohorlyReplayConfig(sampleRate: 0, onErrorSampleRate: 0, remoteConfig: true),
            loader: makeLoader(storage: storage), random: { 0.5 })
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)

        let transport = harness.transport
        storage.afterNextRead {
            transport.releaseConfig()
            // Without the lock around read and join, the answer is written
            // (and its request is over) before the read returns.
            storage.waitForWrite(timeout: 0.5)
        }
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<ReplaySessionDecision, Never>) in
            DispatchQueue.global().async { continuation.resume(returning: settings.decideNewSession()) }
        }
        XCTAssertEqual(decision, .undecided)
        let settled = await eventually { settings.decisionForPending() != nil }
        XCTAssertTrue(settled)
        XCTAssertEqual(settings.decisionForPending()?.mode, .session, "the answer's rate 1")
        XCTAssertEqual(harness.transport.configRequests.count, 1)

        XCTAssertEqual(settings.decideNewSession(), ReplaySessionDecision(mode: .session), "the cached answer decides at once")
        XCTAssertEqual(harness.transport.configRequests.count, 1)
    }

    func testANewSessionWhileARequestRunsJoinsIt() async throws {
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":1}"#)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        let rotated = runtime.sessions.rotate()
        XCTAssertTrue(rotated.pending)

        harness.transport.releaseConfig()
        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(runtime.sessions.session.id, rotated.id)
        XCTAssertEqual(runtime.sessions.session.mode, .session)
        XCTAssertEqual(harness.transport.configRequests.count, 1)
    }

    // MARK: - The pending session

    func testAPendingSessionStampsItsIdAtOnceAndRecordsNothing() async throws {
        harness.transport.holdConfig()
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(harness.install(cohorly, sampleRate: 1, remoteConfig: true))
        let session = runtime.sessions.session
        XCTAssertTrue(session.pending)
        XCTAssertEqual(runtime.recordingState().mode, .off)

        cohorly.track("a")
        await cohorly.flush()
        guard case .string(let stamped)? = harness.track.events.first?.properties["$session_id"] else {
            return XCTFail("no $session_id while the settings load")
        }
        XCTAssertEqual(stamped, session.id)
    }

    func testCodeRatesOfZeroRecordWhenTheServerSendsOne() async throws {
        harness.transport.hold()
        harness.transport.replyConfig([answer(#"{"sampleRate":1}"#)])
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, onErrorSampleRate: 0, remoteConfig: true))
        let decided = await eventually { !runtime.sessions.session.pending }
        XCTAssertTrue(decided)
        XCTAssertEqual(runtime.recordingState().mode, .session)
        let live = runtime.sessions.live
        XCTAssertEqual(runtime.enqueueRecorded(rrwebEvents(1), mode: .session, sessionId: live.session.id, distinctId: live.distinctId), .queued)
        XCTAssertEqual(runtime.chunks.pendingChunks.map(\.sessionId), [live.session.id])
    }

    func testAPendingSessionPersistedAcrossAnExitIsDecidedAtTheNextBoot() throws {
        let id = "pendingsession0000000000000000aa"
        let at = nowMs - 60_000
        harness.storage.setString(
            #"{"id":"\#(id)","started_at":\#(at),"last_activity_at":\#(at),"mode":"off","seq":0,"pending":true,"min_duration_ms":0}"#,
            forKey: ReplaySessionStore.storageKey(ReplayHarness.namespace()))
        plantConfig(#"{"sampleRate":1,"minDurationMs":3000}"#, fetchedAt: nowMs - 60_000)

        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        let session = runtime.sessions.session
        XCTAssertEqual(session.id, id, "the session is continued")
        XCTAssertFalse(session.pending)
        XCTAssertEqual(session.mode, .session)
        XCTAssertEqual(session.minDurationMs, 3000)
    }

    func testAnOldSessionRecordIsReadAsDecided() throws {
        let raw = #"{"id":"oldsession","started_at":1800000000000,"last_activity_at":1800000001000,"mode":"session","seq":3}"#
        let state = try JSONDecoder().decode(ReplaySessionState.self, from: Data(raw.utf8))
        XCTAssertFalse(state.pending)
        XCTAssertEqual(state.mode, .session)
        XCTAssertEqual(state.minDurationMs, 0)
        XCTAssertEqual(state.seq, 3)

        harness.storage.setString(raw, forKey: ReplaySessionStore.storageKey(ReplayHarness.namespace()))
        harness.clock.advance(by: 1)
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        XCTAssertEqual(runtime.sessions.session.id, "oldsession")
        XCTAssertEqual(runtime.recordingState().mode, .session, "a remote load never touches a live session")
    }

    // MARK: - Minimum duration

    /// A runtime whose first session records in session mode, held until
    /// `minDurationMs`. Chunk sends wait for `transport.release()`, so
    /// `pendingChunks` holds every queued chunk.
    private func installHolding(minDurationMs: Int64) throws -> ReplayRuntime {
        harness.transport.hold()
        plantConfig(#"{"sampleRate":1,"minDurationMs":\#(minDurationMs)}"#, fetchedAt: nowMs)
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        XCTAssertEqual(runtime.sessions.session.minDurationMs, minDurationMs)
        return runtime
    }

    func testARecordingShorterThanTheMinimumNeverReachesTheTransport() async throws {
        let runtime = try installHolding(minDurationMs: 10_000)
        let live = runtime.sessions.live
        for start in [0, 4000, 9000] {
            let admission = runtime.enqueueRecorded(
                rrwebEvents(2, start: start), mode: .session, sessionId: live.session.id, distinctId: live.distinctId)
            XCTAssertEqual(admission, .queued)
        }
        XCTAssertEqual(runtime.chunks.pendingChunks.count, 0)
        XCTAssertEqual(runtime.sessions.session.seq, 0, "no seq is taken while held")

        runtime.sessions.rotate()
        let next = runtime.sessions.live
        _ = runtime.enqueueRecorded(rrwebEvents(1, start: 20_000), mode: .session, sessionId: next.session.id, distinctId: next.distinctId)
        harness.transport.release()
        await runtime.chunks.flush()
        XCTAssertFalse(harness.transport.chunks.contains { $0.sessionId == live.session.id })
    }

    func testARecordingThatReachesTheMinimumArrivesWholeFromSeqZero() async throws {
        let runtime = try installHolding(minDurationMs: 10_000)
        let live = runtime.sessions.live
        for start in [0, 4000, 10_000] {
            _ = runtime.enqueueRecorded(
                rrwebEvents(1, start: start), mode: .session, sessionId: live.session.id, distinctId: live.distinctId)
        }
        XCTAssertEqual(runtime.chunks.pendingChunks.map(\.seq), [0, 1, 2])
        _ = runtime.enqueueRecorded(rrwebEvents(1, start: 12_000), mode: .session, sessionId: live.session.id, distinctId: live.distinctId)
        XCTAssertEqual(runtime.chunks.pendingChunks.map(\.seq), [0, 1, 2, 3], "after the minimum, chunks go at once")

        harness.transport.release()
        await runtime.chunks.flush()
        let sent = harness.transport.chunks.filter { $0.sessionId == live.session.id }.sorted { $0.seq < $1.seq }
        XCTAssertEqual(sent.map { eventIndexes($0) }, [[0], [4000], [10_000], [12_000]])
    }

    func testErrorModeIsNeverHeld() throws {
        harness.transport.hold()
        plantConfig(#"{"sampleRate":0,"onErrorSampleRate":1,"minDurationMs":10000}"#, fetchedAt: nowMs)
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, remoteConfig: true))
        let live = runtime.sessions.live
        XCTAssertEqual(live.session.mode, .error)
        XCTAssertEqual(live.session.minDurationMs, 0)
        _ = runtime.enqueueRecorded(rrwebEvents(1), mode: .error, sessionId: live.session.id, distinctId: live.distinctId)
        XCTAssertEqual(runtime.chunks.pendingChunks.count, 1)
    }

    func testOverFiveMiBHeldIsSentAnyway() {
        let hold = ReplayMinDurationHold()
        let live = ReplayMinDurationHold.Session(minDurationMs: 10_000, alreadySent: false, ended: false)
        let payload = String(repeating: "x", count: 600_000)
        for index in 0..<8 {
            let outcome = hold.admit(rrwebEvents(1, start: index, payload: payload), sessionId: "s", distinctId: "u", session: live)
            XCTAssertEqual(outcome, .held, "\(index + 1) x 600 kB is under 5 MiB")
        }
        guard case .release(let held) = hold.admit(rrwebEvents(1, start: 8, payload: payload), sessionId: "s",
                                                   distinctId: "u", session: live) else {
            return XCTFail("past 5 MiB the hold must release")
        }
        XCTAssertEqual(held.flatMap { $0.events }.count, 9)
        XCTAssertEqual(hold.admit(rrwebEvents(1, start: 9), sessionId: "s", distinctId: "u", session: live), .pass)
    }

    func testASessionThatAlreadySentIsNotHeldAgain() {
        let hold = ReplayMinDurationHold()
        let continued = ReplayMinDurationHold.Session(minDurationMs: 10_000, alreadySent: true, ended: false)
        let noMinimum = ReplayMinDurationHold.Session(minDurationMs: 0, alreadySent: false, ended: false)
        XCTAssertEqual(hold.admit(rrwebEvents(1), sessionId: "s", distinctId: "u", session: continued), .pass)
        XCTAssertEqual(hold.admit(rrwebEvents(1), sessionId: "t", distinctId: "u", session: noMinimum), .pass)
    }

    func testASessionThatEndsShortIsDroppedForGood() {
        let hold = ReplayMinDurationHold()
        let live = ReplayMinDurationHold.Session(minDurationMs: 10_000, alreadySent: false, ended: false)
        let ended = ReplayMinDurationHold.Session(minDurationMs: 10_000, alreadySent: false, ended: true)
        XCTAssertEqual(hold.admit(rrwebEvents(1), sessionId: "a", distinctId: "u", session: live), .held)
        XCTAssertEqual(hold.admit(rrwebEvents(1), sessionId: "b", distinctId: "u", session: live), .held,
                       "a chunk of the live session b drops what a held")
        XCTAssertEqual(
            hold.admit(rrwebEvents(1, start: 0) + rrwebEvents(1, start: 20_000), sessionId: "a", distinctId: "u", session: ended),
            .drop, "a late chunk of a dropped session is dropped even when it would reach the minimum")
        XCTAssertEqual(hold.admit(rrwebEvents(2), sessionId: "c", distinctId: "u", session: ended), .drop,
                       "an ended session that is still short sends nothing")
        guard case .release(let held) = hold.admit(
            rrwebEvents(1, start: 0) + rrwebEvents(1, start: 12_000), sessionId: "d", distinctId: "u", session: ended) else {
            return XCTFail("an ended session whose flush reaches the minimum is sent")
        }
        XCTAssertEqual(held.flatMap { $0.events }.count, 2)
    }

    func testAShortRecordingFlushedAfterARotationNeverReachesTheTransport() async throws {
        let runtime = try installHolding(minDurationMs: 10_000)
        let old = runtime.sessions.live
        runtime.sessions.rotate()
        let next = runtime.sessions.live
        XCTAssertNotEqual(next.session.id, old.session.id)
        XCTAssertEqual(next.session.minDurationMs, 10_000)

        // The recorder flushes the old session's buffer under its own id after the rotation.
        XCTAssertEqual(runtime.enqueueRecorded(
            rrwebEvents(2, start: 0), mode: .session, sessionId: old.session.id, distinctId: old.distinctId), .queued)
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)

        for start in [20_000, 31_000] {
            _ = runtime.enqueueRecorded(
                rrwebEvents(1, start: start), mode: .session, sessionId: next.session.id, distinctId: next.distinctId)
        }
        XCTAssertEqual(runtime.chunks.pendingChunks.map(\.sessionId), [next.session.id, next.session.id])
        XCTAssertEqual(runtime.chunks.pendingChunks.map(\.seq), [0, 1])

        _ = runtime.enqueueRecorded(
            rrwebEvents(1, start: 40_000), mode: .session, sessionId: old.session.id, distinctId: old.distinctId)
        XCTAssertFalse(runtime.chunks.pendingChunks.contains { $0.sessionId == old.session.id })

        harness.transport.release()
        await runtime.chunks.flush()
        XCTAssertFalse(harness.transport.chunks.contains { $0.sessionId == old.session.id })
        XCTAssertEqual(runtime.sessions.takeSeq(sessionId: old.session.id), 0, "the short session took no seq")
    }

    func testAHeldRecordingPastFiveMiBIsQueuedFromSeqZero() throws {
        let runtime = try installHolding(minDurationMs: 10_000)
        let live = runtime.sessions.live
        let payload = String(repeating: "x", count: 600_000)
        for index in 0..<8 {
            _ = runtime.enqueueRecorded(rrwebEvents(1, start: index, payload: payload), mode: .session,
                                        sessionId: live.session.id, distinctId: live.distinctId)
        }
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)
        _ = runtime.enqueueRecorded(rrwebEvents(1, start: 8, payload: payload), mode: .session,
                                    sessionId: live.session.id, distinctId: live.distinctId)
        XCTAssertEqual(runtime.chunks.pendingChunks.map(\.seq), Array(0...8))
    }

    // MARK: - Sampling with the saved rates

    func testASavedSampleRateOfZeroKeepsTheCodeErrorRate() throws {
        plantConfig(#"{"sampleRate":0}"#, fetchedAt: nowMs)
        let runtime = try XCTUnwrap(harness.install(harness.makeCohorly(), sampleRate: 0, onErrorSampleRate: 1, remoteConfig: true))
        XCTAssertEqual(runtime.sessions.session.mode, .error)

        plantConfig(#"{"sampleRate":0,"onErrorSampleRate":0}"#, fetchedAt: nowMs)
        let rotated = runtime.sessions.rotate()
        XCTAssertFalse(rotated.pending)
        XCTAssertEqual(rotated.mode, .off)
    }

    // MARK: - The recorder

    @MainActor
    func testTheRecorderCapturesNothingUntilThePendingSessionIsDecided() async throws {
        let source = FakeSnapshotSource()
        let scheduler = ManualScheduler()
        var built: ReplayRecorder?
        var environment = harness.environment
        environment.makeRecorder = { runtime in
            let recorder = ReplayRecorder(
                host: runtime, source: source, touchSource: FakeTouchSource(), observesRunLoop: false,
                monotonicNow: { scheduler.now }, schedule: scheduler.schedule, chunkMaxAge: 3600,
                beginBackgroundTask: { _ in {} })
            built = recorder
            return recorder
        }
        harness.transport.holdConfig()
        harness.transport.replyConfig([answer(#"{"sampleRate":1}"#)])
        let runtime = try XCTUnwrap(CohorlyReplay.install(
            cohorly: harness.makeCohorly(),
            config: CohorlyReplayConfig(sampleRate: 0, onErrorSampleRate: 0, remoteConfig: true),
            environment: environment))
        let recorder = try XCTUnwrap(built)
        let requested = await harness.transport.waitForConfigRequests(1)
        XCTAssertTrue(requested)
        scheduler.advance(by: 5)
        recorder.drainWorker()
        XCTAssertEqual(source.captures, 0, "a pending session records nothing")
        XCTAssertTrue(runtime.chunks.pendingChunks.isEmpty)

        harness.transport.releaseConfig()
        // The decision asks for a full snapshot from the config's thread,
        // which reaches the throttle through the main queue.
        for _ in 0..<200 where source.captures == 0 {
            scheduler.advance(by: 0)
            recorder.drainWorker()
            if source.captures > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(runtime.sessions.session.mode, .session)
        XCTAssertGreaterThan(source.captures, 0, "the decided session starts recording")
    }
}

/// Completions collected across threads.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RemoteReplayConfig?] = []
    func append(_ value: RemoteReplayConfig?) {
        lock.lock(); collected.append(value); lock.unlock()
    }
    var values: [RemoteReplayConfig?] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }
    var count: Int { values.count }
}

/// Storage that runs a one-shot hook right after the config key is read,
/// and reports when that key is written.
private final class ReadHookStorage: CohorlyStorage, @unchecked Sendable {
    private let base = InMemoryStorage()
    private let watched: String
    private let lock = NSLock()
    private var hook: (() -> Void)?
    private let written = DispatchSemaphore(value: 0)

    init(watching key: String) { watched = key }

    func afterNextRead(_ hook: @escaping () -> Void) {
        lock.lock(); self.hook = hook; lock.unlock()
    }

    func waitForWrite(timeout: TimeInterval) {
        _ = written.wait(timeout: .now() + timeout)
    }

    func string(forKey key: String) -> String? {
        let value = base.string(forKey: key)
        guard key == watched else { return value }
        lock.lock()
        let hook = self.hook
        self.hook = nil
        lock.unlock()
        hook?()
        return value
    }

    func setString(_ value: String?, forKey key: String) {
        base.setString(value, forKey: key)
        if key == watched { written.signal() }
    }
}
