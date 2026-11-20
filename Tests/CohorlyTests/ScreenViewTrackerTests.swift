import XCTest

@testable import Cohorly

#if os(iOS)
import UIKit
#endif

/// `trackScreenViews` wiring. The swizzle is process-global, so the "off"
/// checks do not rely on `ScreenViewSwizzle.isInstalled` alone (another test
/// may have installed it): they assert that the instance has no tracker, that
/// none is registered for it and that no `$screen` is queued, which holds
/// whether or not the swizzle is in place.
final class ScreenViewTrackerTests: XCTestCase {
    private func makeClient(trackScreenViews: Bool? = nil, transport: MockTransport) -> Cohorly {
        if let trackScreenViews {
            return Cohorly(
                apiHost: "http://localhost:4000", transport: transport, storage: InMemoryStorage(),
                flushInterval: 3600, flushAt: 1000, trackScreenViews: trackScreenViews,
                flagsFetcher: NoFlagsFetcher(), loadFeatureFlags: false)
        }
        // Default: the parameter is not passed at all.
        return Cohorly(
            apiHost: "http://localhost:4000", transport: transport, storage: InMemoryStorage(),
            flushInterval: 3600, flushAt: 1000, flagsFetcher: NoFlagsFetcher(), loadFeatureFlags: false)
    }

    private func screenEvents(_ transport: MockTransport) -> [TrackEvent] {
        transport.requests.filter { $0.path == "/track" }.flatMap {
            (try? JSONDecoder().decode([TrackEvent].self, from: $0.body)) ?? []
        }.filter { $0.event == "$screen" }
    }

    @MainActor func testOffByDefaultHasNoTrackerAndNoScreenEvent() async {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        XCTAssertNil(client.screenViewTracker)
        #if os(iOS)
        // Another instance with the option on keeps the swizzle in place, so a
        // screen the filter would keep really reaches the hook.
        let onTransport = MockTransport()
        let on = makeClient(trackScreenViews: true, transport: onTransport)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = OffCheckViewController()
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.isHidden = true
        #endif
        await client.flush()
        XCTAssertTrue(screenEvents(transport).isEmpty)
        #if os(iOS)
        await on.flush()
        XCTAssertEqual(screenEvents(onTransport).count, 1)
        #endif
    }

    func testExplicitFalseHasNoTracker() {
        let client = makeClient(trackScreenViews: false, transport: MockTransport())
        XCTAssertNil(client.screenViewTracker)
    }

    func testOnCreatesAndRegistersATracker() throws {
        let client = makeClient(trackScreenViews: true, transport: MockTransport())
        let tracker = try XCTUnwrap(client.screenViewTracker)
        XCTAssertTrue(ScreenViewSwizzle.isRegistered(tracker))
        #if os(iOS)
        XCTAssertTrue(ScreenViewSwizzle.isInstalled)
        #else
        // No UIKit: nothing to swizzle.
        XCTAssertFalse(ScreenViewSwizzle.isInstalled)
        #endif
    }

    func testTrackerEmitsScreenWithOnlyTheScreenNameProperty() async throws {
        let transport = MockTransport()
        let client = makeClient(trackScreenViews: true, transport: transport)
        client.register(["plan": "pro"])
        let tracker = try XCTUnwrap(client.screenViewTracker)
        tracker.screenAppeared(NSObject())  // `NSObject` is not ignored
        client.track("plain")
        await client.flush()
        // `NSObject` has no UI prefix, so it emits under its own class name.
        let events = screenEvents(transport)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.properties["$screen_name"], .string("NSObject"))
        // The usual defaults and super props of any track are there.
        XCTAssertEqual(event.properties["plan"], .string("pro"))
        XCTAssertEqual(event.properties["$lib"], .string("ios"))
        // Nothing of the controller beyond `$screen_name`.
        let plain = try XCTUnwrap(transport.requests.filter { $0.path == "/track" }.flatMap {
            (try? JSONDecoder().decode([TrackEvent].self, from: $0.body)) ?? []
        }.first { $0.event == "plain" })
        XCTAssertEqual(Set(event.properties.keys).subtracting(plain.properties.keys), ["$screen_name"])
    }
}

#if os(iOS)
private final class OffCheckViewController: UIViewController {}
#endif

private struct NoFlagsFetcher: CohorlyFlagsFetcher {
    func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? { nil }
}
