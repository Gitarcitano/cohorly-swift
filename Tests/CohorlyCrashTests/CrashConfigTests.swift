import XCTest
@testable import CohorlyCrash

final class CrashConfigTests: XCTestCase {
    private let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.shop",
        "CFBundleShortVersionString": "3.8.1",
        "CFBundleVersion": "415",
        "CohorlyProjectToken": "tok_123",
        "CohorlyApiHost": "https://ingest.example.com/"
    ]

    private func stored(
        enabled: Any = true,
        metricKit: Any? = nil,
        release: String? = "com.example.shop@3.8.1+415",
        dist: String? = "update-7"
    ) -> String {
        var dict: [String: Any] = [
            "enabled": enabled,
            "distinctId": "user-42",
            "deviceId": "device-1"
        ]
        if let metricKit { dict["metricKit"] = metricKit }
        dict["release"] = release ?? NSNull()
        dict["dist"] = dist ?? NSNull()
        return String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    // MARK: parse

    func testParsesTheContractShape() {
        let config = CrashConfig.parse(stored())
        XCTAssertEqual(config, CrashConfig(
            enabled: true, release: "com.example.shop@3.8.1+415", dist: "update-7",
            distinctId: "user-42", deviceId: "device-1"
        ))
    }

    func testNullsAndWrongTypesAreDropped() {
        let config = CrashConfig.parse(#"{"enabled":true,"release":null,"dist":42,"distinctId":"a","deviceId":["x"]}"#)
        XCTAssertEqual(config, CrashConfig(enabled: true, release: nil, dist: nil, distinctId: "a", deviceId: nil))
    }

    func testOnlyABooleanTrueEnables() {
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":1}"#)?.enabled, false)
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":"true"}"#)?.enabled, false)
        XCTAssertEqual(CrashConfig.parse(#"{}"#)?.enabled, false)
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true}"#)?.enabled, true)
    }

    func testAbsentMetricKitFollowsEnabled() {
        // A config written by @cohorly/react-native 1.4.0 has no `metricKit`.
        XCTAssertEqual(CrashConfig.parse(stored(enabled: true))?.metricKit, true)
        XCTAssertEqual(CrashConfig.parse(stored(enabled: false))?.metricKit, false)
        XCTAssertEqual(CrashConfig.parse(#"{}"#)?.metricKit, false)
    }

    func testOnlyABooleanTrueEnablesMetricKit() {
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true,"metricKit":1}"#)?.metricKit, false)
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true,"metricKit":"true"}"#)?.metricKit, false)
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true,"metricKit":null}"#)?.metricKit, false)
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true,"metricKit":false}"#)?.metricKit, false)
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":false,"metricKit":true}"#)?.metricKit, true)
    }

    func testInvalidOrAbsentIsNil() {
        XCTAssertNil(CrashConfig.parse(nil))
        XCTAssertNil(CrashConfig.parse(""))
        XCTAssertNil(CrashConfig.parse("{not json"))
        XCTAssertNil(CrashConfig.parse("[true]"))
        XCTAssertNil(CrashConfig.parse("true"))
    }

    func testJSONRoundTrip() {
        let config = CrashConfig(enabled: true, release: nil, dist: nil, distinctId: "a", deviceId: "b")
        XCTAssertEqual(CrashConfig.parse(config.jsonString()), config)
        for (enabled, metricKit) in [(false, true), (true, false), (false, false), (true, true)] {
            let config = CrashConfig(
                enabled: enabled, metricKit: metricKit, release: "r", dist: "d", distinctId: "a", deviceId: "b", build: "415"
            )
            let parsed = CrashConfig.parse(config.jsonString())
            XCTAssertEqual(parsed?.enabled, enabled)
            XCTAssertEqual(parsed?.metricKit, metricKit)
            XCTAssertEqual(parsed, config)
        }
    }

    // MARK: decision

    func testInstallsOnlyWhenTheStoredConfigIsEnabled() {
        guard case let .install(endpoint, userInfo, metricKit) = CrashLaunchDecision.decide(storedConfig: stored(), infoDictionary: info) else {
            return XCTFail("expected install")
        }
        XCTAssertTrue(metricKit, "a 1.4.0 config with enabled:true keeps MetricKit")
        XCTAssertEqual(endpoint.token, "tok_123")
        XCTAssertEqual(endpoint.trackURL.absoluteString, "https://ingest.example.com/track")
        XCTAssertEqual(userInfo, CrashUserInfo(
            release: "com.example.shop@3.8.1+415", dist: "update-7",
            distinctId: "user-42", deviceId: "device-1", userId: "user-42"
        ))
    }

    func testAbsentInvalidOrDisabledConfigDisables() {
        XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: nil, infoDictionary: info), .disable)
        XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: "garbage", infoDictionary: info), .disable)
        XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: stored(enabled: false), infoDictionary: info), .disable)
        XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: stored(enabled: "yes"), infoDictionary: info), .disable)
        XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: stored(enabled: false, metricKit: false), infoDictionary: info), .disable)
        XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: stored(enabled: false, metricKit: 1), infoDictionary: info), .disable)
    }

    func testMetricKitWithoutEnabledIsMetricKitOnly() {
        let decision = CrashLaunchDecision.decide(storedConfig: stored(enabled: false, metricKit: true), infoDictionary: info)
        guard case let .metricKitOnly(endpoint, userInfo) = decision else {
            return XCTFail("expected metricKitOnly, got \(decision)")
        }
        XCTAssertEqual(endpoint.trackURL.absoluteString, "https://ingest.example.com/track")
        XCTAssertEqual(userInfo.deviceId, "device-1")
        XCTAssertEqual(userInfo.distinctId, "user-42")
    }

    func testEnabledWithMetricKitOffInstallsWithoutMetricKit() {
        let decision = CrashLaunchDecision.decide(storedConfig: stored(enabled: true, metricKit: false), infoDictionary: info)
        guard case let .install(_, _, metricKit) = decision else {
            return XCTFail("expected install, got \(decision)")
        }
        XCTAssertFalse(metricKit)
    }

    func testMissingTokenOrHostInstallsNothing() {
        var noToken = info
        noToken.removeValue(forKey: "CohorlyProjectToken")
        var noHost = info
        noHost.removeValue(forKey: "CohorlyApiHost")
        var badHost = info
        badHost["CohorlyApiHost"] = "ingest.example.com"
        for dict in [noToken, noHost, badHost] {
            XCTAssertEqual(CrashLaunchDecision.decide(storedConfig: stored(), infoDictionary: dict), .misconfigured)
            XCTAssertEqual(
                CrashLaunchDecision.decide(storedConfig: stored(enabled: false, metricKit: true), infoDictionary: dict),
                .misconfigured
            )
        }
    }

    func testDistIsDroppedWhenTheAppWasUpdatedSinceItWasStored() {
        // JS stored the dist on 3.8.0+410; this launch runs 3.8.1+415.
        let decision = CrashLaunchDecision.decide(
            storedConfig: stored(release: "com.example.shop@3.8.0+410"), infoDictionary: info
        )
        guard case let .install(_, userInfo, _) = decision else { return XCTFail("expected install") }
        XCTAssertNil(userInfo.dist)
        // The release is always the binary's own.
        XCTAssertEqual(userInfo.release, "com.example.shop@3.8.1+415")
    }

    func testBuildIsReadAsAStringOrANumber() {
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true,"build":"415"}"#)?.build, "415")
        XCTAssertEqual(CrashConfig.parse(#"{"enabled":true,"build":415}"#)?.build, "415")
        XCTAssertNil(CrashConfig.parse(#"{"enabled":true,"build":true}"#)?.build)
        let config = CrashConfig(enabled: true, release: "r", dist: "d", distinctId: "a", deviceId: "b", build: "415")
        XCTAssertEqual(CrashConfig.parse(config.jsonString()), config)
    }

    func testDistIsDroppedWhenTheStoredBuildIsNotTheRunningOne() {
        // Same release string, but the config was written by build 410.
        var dict = info
        dict["CFBundleVersion"] = "415"
        let config = CrashConfig(
            enabled: true, release: "com.example.shop@3.8.1+415", dist: "update-7",
            distinctId: "a", deviceId: "a", build: "410"
        )
        guard case let .install(_, stale, _) = CrashLaunchDecision.decide(storedConfig: config.jsonString(), infoDictionary: dict) else {
            return XCTFail("expected install")
        }
        XCTAssertNil(stale.dist)
        var current = config
        current.build = "415"
        guard case let .install(_, kept, _) = CrashLaunchDecision.decide(storedConfig: current.jsonString(), infoDictionary: dict) else {
            return XCTFail("expected install")
        }
        XCTAssertEqual(kept.dist, "update-7")
    }

    func testDistNeedsAStoredRelease() {
        let config = CrashConfig(enabled: true, release: nil, dist: "update-7", distinctId: "a", deviceId: "a")
        XCTAssertNil(config.userInfo(binaryRelease: "com.example.shop@3.8.1+415").dist)
        XCTAssertNil(config.userInfo(binaryRelease: nil).dist)
    }

    func testUserIdOnlyForAnIdentifiedUser() {
        XCTAssertEqual(CrashConfig.userId(distinctId: "user-42", deviceId: "device-1"), "user-42")
        XCTAssertNil(CrashConfig.userId(distinctId: "device-1", deviceId: "device-1"))
        XCTAssertNil(CrashConfig.userId(distinctId: nil, deviceId: "device-1"))
    }

    func testReleaseFromInfoPlist() {
        XCTAssertEqual(CrashRelease.fromInfoDictionary(info), "com.example.shop@3.8.1+415")
        XCTAssertEqual(CrashRelease.fromInfoDictionary(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "3"]), "ios@1.0+3")
        XCTAssertEqual(CrashRelease.fromInfoDictionary(["CFBundleIdentifier": "a.b", "CFBundleShortVersionString": "1.0"]), "a.b@1.0")
        XCTAssertNil(CrashRelease.fromInfoDictionary(["CFBundleIdentifier": "a.b", "CFBundleVersion": "3"]))
    }

    // MARK: launcher

    func testEnabledLaunchInstallsWritesUserInfoSendsAndSubscribes() {
        let backend = FakeBackend()
        let installed = CrashLauncher.run(
            CrashLaunchDecision.decide(storedConfig: stored(), infoDictionary: info), backend: backend
        )
        XCTAssertTrue(installed)
        XCTAssertEqual(backend.calls, ["install", "userInfo", "send", "metricKit"])
        XCTAssertEqual(backend.userInfo?.distinctId, "user-42")
    }

    func testMetricKitOnlyLaunchNeverInstallsKSCrash() {
        let backend = FakeBackend()
        let installed = CrashLauncher.run(
            CrashLaunchDecision.decide(storedConfig: stored(enabled: false, metricKit: true), infoDictionary: info),
            backend: backend
        )
        XCTAssertFalse(installed, "the reporter is not installed in this process")
        XCTAssertEqual(backend.calls, ["metricKitUserInfo", "send", "metricKit"])
        XCTAssertFalse(backend.calls.contains("install"))
        XCTAssertFalse(backend.calls.contains("userInfo"), "user info is never written into KSCrash")
        XCTAssertEqual(backend.metricKitUserInfo?.deviceId, "device-1")
    }

    func testEnabledLaunchWithMetricKitOffDoesNotSubscribe() {
        let backend = FakeBackend()
        let installed = CrashLauncher.run(
            CrashLaunchDecision.decide(storedConfig: stored(enabled: true, metricKit: false), infoDictionary: info),
            backend: backend
        )
        XCTAssertTrue(installed)
        XCTAssertEqual(backend.calls, ["install", "userInfo", "send"])
    }

    func testDisabledLaunchDeletesPendingReportsAndDoesNothingElse() {
        for config in [nil, "garbage", stored(enabled: false), stored(enabled: false, metricKit: false)] {
            let backend = FakeBackend()
            let installed = CrashLauncher.run(
                CrashLaunchDecision.decide(storedConfig: config, infoDictionary: info), backend: backend
            )
            XCTAssertFalse(installed)
            XCTAssertEqual(backend.calls, ["deletePending"], String(describing: config))
        }
    }

    func testMisconfiguredLaunchTouchesNothing() {
        let backend = FakeBackend()
        XCTAssertFalse(CrashLauncher.run(.misconfigured, backend: backend))
        XCTAssertEqual(backend.calls, [])
    }

    func testFailedInstallStillSendsEarlierReportsWithoutUserInfo() {
        let backend = FakeBackend()
        backend.installSucceeds = false
        XCTAssertFalse(CrashLauncher.run(
            CrashLaunchDecision.decide(storedConfig: stored(), infoDictionary: info), backend: backend
        ))
        XCTAssertEqual(backend.calls, ["install", "send", "metricKit"])
    }

    // MARK: upload policy

    func testUploadPolicy() {
        for status in [200, 201, 204, 299, 400, 413] {
            XCTAssertEqual(UploadPolicy.outcome(statusCode: status, error: nil), .delete, "\(status)")
        }
        for status in [401, 403, 404, 429, 500, 502, 503] {
            XCTAssertEqual(UploadPolicy.outcome(statusCode: status, error: nil), .keep, "\(status)")
        }
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual(UploadPolicy.outcome(statusCode: nil, error: offline), .keep)
        XCTAssertEqual(UploadPolicy.outcome(statusCode: nil, error: nil), .keep)
        // A status with a transport error is not a delivery.
        XCTAssertEqual(UploadPolicy.outcome(statusCode: 200, error: URLError(.networkConnectionLost)), .keep)
        XCTAssertEqual(UploadPolicy.outcome(statusCode: 400, error: URLError(.networkConnectionLost)), .keep)
    }

    // MARK: background completion

    func testBackgroundCompletionHandlerSetBeforeEventsFinish() {
        var gate = BackgroundCompletionGate()
        var calls = 0
        XCTAssertNil(gate.setHandler { calls += 1 })
        gate.eventsFinished()?()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(gate.eventsFinished(), "delivered once")
    }

    func testBackgroundCompletionHandlerSetAfterEventsFinish() {
        var gate = BackgroundCompletionGate()
        var calls = 0
        XCTAssertNil(gate.eventsFinished())
        gate.setHandler { calls += 1 }?()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(gate.setHandler { calls += 1 }, "a later handler waits for the next events")
        XCTAssertEqual(calls, 1)
    }

    func testSessionIdentifierIsStablePerBundle() {
        XCTAssertEqual(CrashUploader.sessionIdentifier(bundleId: "com.example.shop"), "com.example.shop.cohorly.crash.upload")
        XCTAssertEqual(CrashUploader.sessionIdentifier(bundleId: "com.example.shop"),
                       CrashUploader.sessionIdentifier(bundleId: "com.example.shop"))
    }
}

private final class FakeBackend: CrashBackend {
    var calls: [String] = []
    var userInfo: CrashUserInfo?
    var metricKitUserInfo: CrashUserInfo?
    var installSucceeds = true

    func installMonitors() -> Bool {
        calls.append("install")
        return installSucceeds
    }

    func setUserInfo(_ userInfo: CrashUserInfo) {
        calls.append("userInfo")
        self.userInfo = userInfo
    }

    func setMetricKitUserInfo(_ userInfo: CrashUserInfo) {
        calls.append("metricKitUserInfo")
        metricKitUserInfo = userInfo
    }

    func sendPendingReports(endpoint: CrashEndpoint) { calls.append("send") }
    func subscribeMetricKit(endpoint: CrashEndpoint) { calls.append("metricKit") }
    func deletePendingReports() { calls.append("deletePending") }
}
