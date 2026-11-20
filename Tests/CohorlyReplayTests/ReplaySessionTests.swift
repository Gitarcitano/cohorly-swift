import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

final class ReplaySessionTests: XCTestCase {
    private let clock = MutableClock()
    private let storage = InMemoryStorage()
    private var draws = 0

    private let namespace = "ns1"

    private func makeStore(mode: ReplayMode = .session) -> ReplaySessionStore {
        ReplaySessionStore(storage: storage, clock: clock, namespace: namespace) { [unowned self] in
            self.draws += 1
            return mode
        }
    }

    private func minutes(_ value: Double) -> TimeInterval { value * 60 }
    private func hours(_ value: Double) -> TimeInterval { value * 3600 }

    // MARK: - Id

    func testSessionIdMatchesTheServerPattern() throws {
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")
        var seen = Set<String>()
        let store = makeStore()
        for _ in 0..<50 {
            let id = store.rotate().id
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(pattern.firstMatch(in: id, range: range), id)
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 50)
    }

    func testAStaleInitialIdentityNeverOverwritesANewerOne() {
        let store = makeStore()
        let version = store.currentIdentityVersion
        store.setDistinctId("user-new") // a notification landing after the snapshot was read
        store.setDistinctId("user-old", ifUnchangedSince: version)
        XCTAssertEqual(store.distinctId, "user-new")

        let fresh = store.currentIdentityVersion
        store.setDistinctId("user-latest", ifUnchangedSince: fresh)
        XCTAssertEqual(store.distinctId, "user-latest")
    }

    func testSessionIdValidation() {
        XCTAssertTrue(ReplaySessionId.isValid("a"))
        XCTAssertTrue(ReplaySessionId.isValid(String(repeating: "Z", count: 64)))
        XCTAssertTrue(ReplaySessionId.isValid("k3J_x-9"))
        XCTAssertFalse(ReplaySessionId.isValid(""))
        XCTAssertFalse(ReplaySessionId.isValid(String(repeating: "Z", count: 65)))
        XCTAssertFalse(ReplaySessionId.isValid("has space"))
        XCTAssertFalse(ReplaySessionId.isValid("../etc"))
    }

    // MARK: - Persistence

    func testANewStoreOnTheSameStorageContinuesTheSessionWithoutDrawingAgain() {
        let first = makeStore(mode: .error)
        let id = first.session.id
        XCTAssertEqual(first.takeSeq(sessionId: id), 0)
        XCTAssertEqual(first.takeSeq(sessionId: id), 1)
        XCTAssertEqual(draws, 1)

        clock.advance(by: minutes(10))
        let relaunched = makeStore(mode: .session)
        XCTAssertEqual(relaunched.session.id, id)
        XCTAssertEqual(relaunched.session.mode, .error)
        XCTAssertEqual(relaunched.takeSeq(sessionId: id), 2)
        XCTAssertEqual(draws, 1)
    }

    func testInvalidPersistedStateStartsANewSession() {
        // The clock is at 1_800_000_000_000 ms.
        let valid = #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"session","seq":3}"#
        let dayAndOneMs = 1_800_000_000_000 + 86_400_000 + 1
        let invalid = [
            "not json",
            #"{"id":"bad id!","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"session","seq":3}"#,
            #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"bogus","seq":3}"#,
            #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"session","seq":-1}"#,
            #"{"id":"abc","mode":"session","seq":3}"#,
            #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"session","seq":9223372036854775807}"#,
            #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"session","seq":1000000001}"#,
            #"{"id":"abc","started_at":-9223372036854775808,"last_activity_at":1800000000000,"mode":"session","seq":3}"#,
            #"{"id":"abc","started_at":-1,"last_activity_at":1800000000000,"mode":"session","seq":3}"#,
            #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"last_background_at":-9223372036854775808,"mode":"session","seq":3}"#,
            "{\"id\":\"abc\",\"started_at\":1800000000000,\"last_activity_at\":\(dayAndOneMs),\"mode\":\"session\",\"seq\":3}",
            "{\"id\":\"abc\",\"started_at\":\(dayAndOneMs),\"last_activity_at\":\(dayAndOneMs),\"mode\":\"session\",\"seq\":3}",
            #"{"id":"abc","started_at":1800000000001,"last_activity_at":1800000000000,"mode":"session","seq":3}"#,
            #"{"id":"abc","started_at":1800000000000,"last_activity_at":9223372036854775807,"mode":"session","seq":3}"#
        ]
        let key = ReplaySessionStore.storageKey(namespace)
        storage.setString(valid, forKey: key)
        XCTAssertEqual(makeStore().session.id, "abc")

        for raw in invalid {
            storage.setString(raw, forKey: key)
            let store = makeStore()
            XCTAssertNotEqual(store.session.id, "abc", raw)
            XCTAssertEqual(store.session.seq, 0, raw)
            // The new session works: no overflow on the next track or seq.
            XCTAssertEqual(store.sessionIdForEvent(), store.session.id, raw)
            XCTAssertEqual(store.takeSeq(sessionId: store.session.id), 0, raw)
        }
    }

    func testSeqAtTheMaximumNeverOverflows() {
        let raw = #"{"id":"abc","started_at":1800000000000,"last_activity_at":1800000000000,"mode":"session","seq":1000000000}"#
        storage.setString(raw, forKey: ReplaySessionStore.storageKey(namespace))
        let store = makeStore()
        XCTAssertEqual(store.session.id, "abc")
        XCTAssertEqual(store.takeSeq(sessionId: "abc"), 1_000_000_000)
        XCTAssertEqual(store.takeSeq(sessionId: "abc", atLeast: Int.max), ReplaySessionState.maxSeq)
        XCTAssertEqual(store.session.seq, ReplaySessionState.maxSeq)
    }

    func testInvalidRetiredEntriesAreDropped() {
        storage.setString(
            #"[{"id":"ok","seq":4},{"id":"bad id","seq":1},{"id":"big","seq":9223372036854775807},{"id":"neg","seq":-3}]"#,
            forKey: ReplaySessionStore.retiredKey(namespace))
        let store = makeStore()
        XCTAssertEqual(store.takeSeq(sessionId: "ok"), 4)
        XCTAssertEqual(store.takeSeq(sessionId: "big"), 0)
        XCTAssertEqual(store.takeSeq(sessionId: "neg"), 0)
    }

    func testKeysAreSeparatePerNamespace() {
        let first = makeStore()
        let other = ReplaySessionStore(storage: storage, clock: clock, namespace: "ns2") { .error }
        XCTAssertNotEqual(first.session.id, other.session.id)
        XCTAssertNotNil(storage.string(forKey: ReplaySessionStore.storageKey("ns1")))
        XCTAssertNotNil(storage.string(forKey: ReplaySessionStore.storageKey("ns2")))
    }

    func testRelaunchAfterThirtyMinutesInTheBackgroundStartsANewSession() {
        let first = makeStore()
        let id = first.session.id
        first.didEnterBackground()

        clock.advance(by: minutes(29) + 59)
        XCTAssertEqual(makeStore().session.id, id)

        let second = makeStore()
        second.didEnterBackground()
        clock.advance(by: minutes(30))
        XCTAssertNotEqual(makeStore().session.id, id)
    }

    func testRelaunchOfAProcessThatDiedInTheForegroundUsesItsLastActivity() {
        let first = makeStore()
        let id = first.session.id
        clock.advance(by: minutes(5))
        _ = first.sessionIdForEvent()

        clock.advance(by: minutes(29) + 59)
        XCTAssertEqual(makeStore().session.id, id)
        clock.advance(by: minutes(30))
        XCTAssertNotEqual(makeStore().session.id, id)
    }

    // MARK: - Rotation

    func testBackgroundBelowThirtyMinutesKeepsTheSession() {
        let store = makeStore()
        let id = store.session.id
        store.didEnterBackground()
        clock.advance(by: minutes(29) + 59)
        store.willEnterForeground()
        XCTAssertEqual(store.sessionIdForEvent(), id)
        XCTAssertNil(store.session.lastBackgroundAt)
    }

    func testThirtyMinutesInTheBackgroundRotatesOnReturnToTheForeground() {
        let store = makeStore()
        let id = store.session.id
        var published: [String] = []
        store.onRotate = { session, _ in published.append(session.id) }
        store.didEnterBackground()
        clock.advance(by: minutes(30))
        XCTAssertEqual(store.session.id, id) // never in the background
        store.willEnterForeground()

        let newId = store.sessionIdForEvent()
        XCTAssertNotEqual(newId, id)
        XCTAssertEqual(published, [newId])
        XCTAssertEqual(store.session.seq, 0)
        XCTAssertEqual(draws, 2)
    }

    func testNeverRotatesWhileInTheBackgroundEvenPastTwentyFourHours() {
        let store = makeStore()
        let id = store.session.id
        store.didEnterBackground()
        clock.advance(by: hours(25))
        XCTAssertEqual(store.sessionIdForEvent(), id)
        store.willEnterForeground()
        XCTAssertNotEqual(store.sessionIdForEvent(), id)
    }

    func testTwentyFourHoursInTheForegroundRotatesOnTheNextTrack() {
        let store = makeStore()
        let id = store.session.id
        // Active all along: a track every 20 minutes.
        for _ in 0..<(24 * 3 - 1) {
            clock.advance(by: minutes(20))
            XCTAssertEqual(store.sessionIdForEvent(), id)
        }
        clock.advance(by: minutes(19))
        XCTAssertEqual(store.sessionIdForEvent(), id)
        clock.advance(by: minutes(1))
        let newId = store.sessionIdForEvent()
        XCTAssertNotEqual(newId, id)
        XCTAssertEqual(store.sessionIdForEvent(), newId)
    }

    func testThirtyMinutesWithoutActivityInTheForegroundRotatesOnTheNextActivity() {
        let store = makeStore()
        let id = store.session.id
        clock.advance(by: minutes(29) + 59)
        XCTAssertEqual(store.noteActivity(), id)
        clock.advance(by: minutes(29) + 59)
        XCTAssertEqual(store.sessionIdForEvent(), id, "the activity before reset the idle time")
        clock.advance(by: minutes(30))
        let newId = store.noteActivity()
        XCTAssertNotEqual(newId, id)
        XCTAssertEqual(store.session.id, newId)
    }

    func testARetiredSessionKeepsItsSeqAfterItsLastChunkLeftTheDisk() {
        let store = makeStore()
        let old = store.session.id
        _ = store.reserve(sessionId: old, distinctId: "u") { _, _ in 3 }
        store.pin(sessionId: old)
        store.rotate()
        store.forget(sessionId: old)
        let context = store.reserve(sessionId: old, distinctId: "u") { _, _ in 1 }
        XCTAssertEqual(context?.firstSeq, 3)
        XCTAssertNil(store.reserve(sessionId: "neverseen", distinctId: "u") { _, _ in 1 }, "an unknown session is refused")
    }

    func testTwentyFourHoursRotatesOnReturnToTheForegroundAfterAShortBackground() {
        let store = makeStore()
        let id = store.session.id
        clock.advance(by: hours(23) + minutes(59))
        store.didEnterBackground()
        clock.advance(by: minutes(1))
        store.willEnterForeground()
        XCTAssertNotEqual(store.session.id, id)
    }

    func testRetiredSessionKeepsItsOwnSeqAcrossARelaunch() {
        let store = makeStore()
        let old = store.session.id
        XCTAssertEqual(store.takeSeq(sessionId: old), 0)
        XCTAssertEqual(store.takeSeq(sessionId: old), 1)
        let new = store.rotate().id
        XCTAssertEqual(store.takeSeq(sessionId: new), 0)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.takeSeq(sessionId: old), 2)
        XCTAssertEqual(relaunched.takeSeq(sessionId: "unknownsession", atLeast: 7), 7)
        XCTAssertEqual(relaunched.takeSeq(sessionId: new), 1)
    }

    func testARetiredSessionWithChunksOnDiskIsNeverTrimmed() {
        let store = makeStore()
        let pinned = store.session.id
        XCTAssertEqual(store.takeSeq(sessionId: pinned), 0)
        store.pin(sessionId: pinned)
        for _ in 0..<(ReplaySessionStore.maxRetired + 10) { store.rotate() }
        XCTAssertEqual(store.takeSeq(sessionId: pinned), 1)

        // Once its chunks are gone it may be trimmed like any other.
        store.forget(sessionId: pinned)
        for _ in 0..<(ReplaySessionStore.maxRetired + 1) { store.rotate() }
        XCTAssertEqual(store.takeSeq(sessionId: pinned), 0)
    }

    func testReconcileMovesTheNextSeqPastTheFilesOnDisk() {
        let store = makeStore()
        let id = store.session.id
        store.reconcile(sessionId: id, next: 8)
        XCTAssertEqual(store.takeSeq(sessionId: id), 8)
        store.reconcile(sessionId: id, next: 3) // never backwards
        XCTAssertEqual(store.takeSeq(sessionId: id), 9)
        store.reconcile(sessionId: "gone", next: 5)
        XCTAssertEqual(store.takeSeq(sessionId: "gone"), 5)
    }

    func testReserveTakesSessionDistinctIdAndSeqsTogether() {
        let store = makeStore()
        store.setDistinctId("user-1")
        let first = store.reserve { _, _ in 3 }
        XCTAssertEqual(first, ReplayChunkContext(sessionId: store.session.id, distinctId: "user-1", firstSeq: 0))
        let old = store.session.id
        store.rotate(distinctId: "anon-2")
        let second = store.reserve { sessionId, distinctId in
            XCTAssertNotEqual(sessionId, old)
            XCTAssertEqual(distinctId, "anon-2")
            return 1
        }
        XCTAssertEqual(second.firstSeq, 0)
        XCTAssertEqual(store.reserve { _, _ in 1 }.firstSeq, 1)
        XCTAssertEqual(store.takeSeq(sessionId: old), 3)
    }

    func testAClosedStoreWritesNothing() {
        let store = makeStore()
        let key = ReplaySessionStore.storageKey(namespace)
        let before = storage.string(forKey: key)
        store.close()
        store.rotate()
        _ = store.takeSeq(sessionId: store.session.id)
        XCTAssertEqual(storage.string(forKey: key), before)
    }

    // MARK: - Sampling

    func testSamplingDecision() {
        func decide(_ sample: Double, _ onError: Double, _ draws: [Double]) -> ReplayMode {
            let random = ScriptedRandom(draws, fallback: 0.999_999)
            return decideReplayMode(sampleRate: sample, onErrorSampleRate: onError, random: random.next)
        }
        XCTAssertEqual(decide(0, 0, [0]), .off)
        XCTAssertEqual(decide(0, 1, [0.999]), .error)
        XCTAssertEqual(decide(1, 0, [0.999_999]), .session)
        XCTAssertEqual(decide(0.5, 0, [0.499]), .session)
        XCTAssertEqual(decide(0.5, 0, [0.5]), .off)
        XCTAssertEqual(decide(0.5, 0.5, [0.7, 0.2]), .error)
        XCTAssertEqual(decide(0.5, 0.5, [0.7, 0.6]), .off)
    }

    func testSampleRateZeroNeverRecordsAWholeSessionAndOneAlways() {
        for value in stride(from: 0.0, to: 1.0, by: 0.05) {
            let zero = ScriptedRandom([], fallback: value)
            XCTAssertNotEqual(decideReplayMode(sampleRate: 0, onErrorSampleRate: 0, random: zero.next), .session)
            let one = ScriptedRandom([], fallback: value)
            XCTAssertEqual(decideReplayMode(sampleRate: 1, onErrorSampleRate: 0, random: one.next), .session)
        }
    }

    func testANewSessionDrawsAgain() {
        let random = ScriptedRandom([0.1, 0.9, 0.9])
        let store = ReplaySessionStore(storage: storage, clock: clock, namespace: namespace) {
            decideReplayMode(sampleRate: 0.5, onErrorSampleRate: 0.5, random: random.next)
        }
        XCTAssertEqual(store.session.mode, .session)
        XCTAssertEqual(store.rotate().mode, .off)
    }

    func testConfigClampsRates() {
        let config = CohorlyReplayConfig(sampleRate: 2, onErrorSampleRate: -1)
        XCTAssertEqual(config.sampleRate, 1)
        XCTAssertEqual(config.onErrorSampleRate, 0)
        XCTAssertEqual(CohorlyReplayConfig(sampleRate: .nan, onErrorSampleRate: .infinity).sampleRate, 0)
        XCTAssertEqual(CohorlyReplayConfig(sampleRate: .nan, onErrorSampleRate: .infinity).onErrorSampleRate, 0)
        let defaults = CohorlyReplayConfig()
        XCTAssertEqual(defaults.sampleRate, 0)
        XCTAssertEqual(defaults.onErrorSampleRate, 0)
        XCTAssertTrue(defaults.maskAllImages)
        XCTAssertEqual(CohorlyReplayConfig(sampleRate: 0.25, onErrorSampleRate: 0.75).sampleRate, 0.25)
    }
}
