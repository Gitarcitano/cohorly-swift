import XCTest
@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyCrash

/// Records what `CohorlyCrash` writes. Like `CrashReporter`, it ignores user
/// info until started; `onStart` runs inside `start`, before that.
private final class FakeReporter: CrashUserInfoReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var _applied: [CrashUserInfo] = []
    var onStart: (() -> Void)?

    var applied: [CrashUserInfo] {
        lock.lock(); defer { lock.unlock() }
        return _applied
    }

    func start(_ decision: CrashLaunchDecision, lib: CrashLibInfo) -> Bool {
        onStart?()
        lock.lock()
        defer { lock.unlock() }
        started = true
        if case let .install(_, userInfo, _) = decision { _applied.append(userInfo) }
        return true
    }

    func updateUserInfo(_ userInfo: CrashUserInfo) {
        lock.lock()
        defer { lock.unlock() }
        if started { _applied.append(userInfo) }
    }
}

/// The Swift SDK side: the identity hook `CohorlyCrash` follows. KSCrash is
/// never installed here (that would hook the test process's signals).
final class CohorlyIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CohorlyCrash.resetForTesting()
    }

    override func tearDown() {
        CohorlyCrash.resetForTesting()
        super.tearDown()
    }

    private struct NoTransport: CohorlyTransport {
        func post(apiHost: String, path: String, body: Data) async throws {}
    }

    private struct NoFlags: CohorlyFlagsFetcher {
        func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? { nil }
    }

    private func makeCohorly() -> Cohorly {
        Cohorly(
            apiHost: "https://ingest.example.com",
            token: "tok_123",
            transport: NoTransport(),
            storage: InMemoryStorage(),
            flagsFetcher: NoFlags(),
            loadFeatureFlags: false
        )
    }

    func testLibVersionMatchesTheSwiftSDK() {
        XCTAssertEqual(CohorlyCrash.libVersion, DeviceInfo.libVersion)
    }

    func testCohorlyExposesTokenAndHostForTheCrashEndpoint() {
        let cohorly = makeCohorly()
        let endpoint = CrashEndpoint(token: cohorly.configuredToken, host: cohorly.configuredAPIHost)
        XCTAssertEqual(endpoint?.token, "tok_123")
        XCTAssertEqual(endpoint?.trackURL.absoluteString, "https://ingest.example.com/track")
    }

    func testIdentityNotificationFollowsIdentifyAndReset() {
        let cohorly = makeCohorly()
        var received: [[String: String]] = []
        let lock = NSLock()
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.identityDidChangeNotification, object: cohorly, queue: nil
        ) { note in
            lock.lock()
            received.append(note.userInfo as? [String: String] ?? [:])
            lock.unlock()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let deviceId = cohorly.currentDeviceId
        XCTAssertNil(cohorly.currentUserId)
        cohorly.identify("user-42")
        XCTAssertEqual(cohorly.currentUserId, "user-42") // queue.sync: identify has run
        cohorly.reset()
        let afterReset = cohorly.currentDistinctId

        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first, [
            Cohorly.IdentityKey.distinctId: "user-42",
            Cohorly.IdentityKey.deviceId: deviceId,
            Cohorly.IdentityKey.userId: "user-42"
        ])
        XCTAssertEqual(received.last, [
            Cohorly.IdentityKey.distinctId: afterReset,
            Cohorly.IdentityKey.deviceId: afterReset
        ])
    }

    func testSessionIdIsWrittenToKSCrashUserInfoUnderSessionIdKey() {
        var info = CrashUserInfo(release: "r", dist: nil, distinctId: "d", deviceId: "d", userId: nil)
        // Present with a nil value: KSCrash removes a session id left by an earlier install.
        XCTAssertTrue(info.entries.contains { $0.key == "session_id" && $0.value == nil })
        info.sessionId = "abc123"
        XCTAssertTrue(info.entries.contains { $0.key == "session_id" && $0.value == "abc123" })
    }

    func testReplaySessionChangeUpdatesTheCrashUserInfoKeepingIdentity() {
        CohorlyCrash.identityDidChange([
            Cohorly.IdentityKey.distinctId: "user-9",
            Cohorly.IdentityKey.deviceId: "device-9",
            Cohorly.IdentityKey.userId: "user-9"
        ])
        CohorlyCrash.replaySessionDidChange("session1")
        XCTAssertEqual(CohorlyCrash.currentUserInfo.sessionId, "session1")
        XCTAssertEqual(CohorlyCrash.currentUserInfo.distinctId, "user-9")

        CohorlyCrash.identityDidChange([
            Cohorly.IdentityKey.distinctId: "device-10",
            Cohorly.IdentityKey.deviceId: "device-10"
        ])
        XCTAssertEqual(CohorlyCrash.currentUserInfo.sessionId, "session1")
        CohorlyCrash.replaySessionDidChange(nil)
    }

    func testPublishedReplaySessionIsPostedForTheInstanceAndRemembered() {
        let cohorly = makeCohorly()
        XCTAssertNil(cohorly.currentReplaySessionId)
        var received: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: Cohorly.replaySessionDidChangeNotification, object: cohorly, queue: nil
        ) { note in
            if let id = note.userInfo?[Cohorly.ReplaySessionKey.sessionId] as? String { received.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        cohorly.publishReplaySession("s1")
        cohorly.publishReplaySession("s2")
        XCTAssertEqual(received, ["s1", "s2"])
        XCTAssertEqual(cohorly.currentReplaySessionId, "s2")
    }

    func testInstallReappliesTheNewestSessionOnceTheReporterStarted() throws {
        let reporter = FakeReporter()
        CohorlyCrash.resetForTesting(reporter: reporter)
        let cohorly = makeCohorly()
        cohorly.publishReplaySession("before")
        // A rotation while the reporter starts reaches nothing at that moment.
        reporter.onStart = { cohorly.publishReplaySession("during") }

        XCTAssertTrue(CohorlyCrash.install(cohorly: cohorly, release: "r"))
        let last = try XCTUnwrap(reporter.applied.last)
        XCTAssertEqual(last.sessionId, "during")
        XCTAssertEqual(last.release, "r")
        XCTAssertEqual(last.distinctId, cohorly.currentDistinctId)

        cohorly.publishReplaySession("after")
        XCTAssertEqual(reporter.applied.last?.sessionId, "after")
        cohorly.publishReplaySession(nil) // replay replaced or removed
        XCTAssertEqual(reporter.applied.count, 4)
        XCTAssertNil(try XCTUnwrap(reporter.applied.last).sessionId)
        XCTAssertNil(CohorlyCrash.currentUserInfo.sessionId)
    }

    func testConcurrentChangesLeaveTheNewestUserInfoWritten() throws {
        let reporter = FakeReporter()
        CohorlyCrash.resetForTesting(reporter: reporter)
        XCTAssertTrue(CohorlyCrash.install(cohorly: makeCohorly(), release: "r"))

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            if index % 2 == 0 {
                CohorlyCrash.replaySessionDidChange("s\(index)")
            } else {
                CohorlyCrash.identityDidChange([
                    Cohorly.IdentityKey.distinctId: "u\(index)",
                    Cohorly.IdentityKey.deviceId: "d\(index)"
                ])
            }
        }
        // Every change was written in the order it was made: the last write
        // is the state crashes of this launch must carry.
        XCTAssertEqual(reporter.applied.count, 402)
        XCTAssertEqual(try XCTUnwrap(reporter.applied.last), CohorlyCrash.currentUserInfo)
    }

    func testIdentityChangeUpdatesTheCrashUserInfoKeepingRelease() {
        CohorlyCrash.identityDidChange([
            Cohorly.IdentityKey.distinctId: "user-7",
            Cohorly.IdentityKey.deviceId: "device-7",
            Cohorly.IdentityKey.userId: "user-7"
        ])
        XCTAssertEqual(CohorlyCrash.currentUserInfo.distinctId, "user-7")
        XCTAssertEqual(CohorlyCrash.currentUserInfo.userId, "user-7")

        CohorlyCrash.identityDidChange([
            Cohorly.IdentityKey.distinctId: "device-8",
            Cohorly.IdentityKey.deviceId: "device-8"
        ])
        XCTAssertEqual(CohorlyCrash.currentUserInfo.deviceId, "device-8")
        XCTAssertNil(CohorlyCrash.currentUserInfo.userId)
        XCTAssertFalse(CohorlyCrash.isInstalled)
    }
}
