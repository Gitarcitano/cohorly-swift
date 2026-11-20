#if os(iOS)
import ObjectiveC
import UIKit
import XCTest

@testable import Cohorly

private final class ScreenAViewController: UIViewController {}
private final class ScreenBViewController: UIViewController {}
private final class ScreenCViewController: UIViewController {}
private final class OverridingViewController: UIViewController {
    var ranOwnViewDidAppear = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ranOwnViewDidAppear = true
    }
}

/// Drives the real swizzle with a real window. Navigation is not animated and
/// each step spins the run loop so `viewDidAppear` has run before reading.
final class ScreenViewUIKitTests: XCTestCase {
    private var window: UIWindow!
    private var transport: MockTransport!
    private var client: Cohorly!

    override func setUp() {
        super.setUp()
        transport = MockTransport()
        client = makeClient()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        client = nil
        transport = nil
        super.tearDown()
    }

    private func makeClient() -> Cohorly {
        Cohorly(
            apiHost: "http://localhost:4000", transport: transport, storage: InMemoryStorage(),
            flushInterval: 3600, flushAt: 1000, trackScreenViews: true,
            flagsFetcher: NoFlagsForScreens(), loadFeatureFlags: false)
    }

    private func show(_ root: UIViewController) {
        window.rootViewController = root
        window.makeKeyAndVisible()
        spin()
    }

    /// The SPM test host has no `UIWindowScene`, and there UIKit skips the
    /// appearance callbacks of a tab switch and of a presentation (a push
    /// still gets them). This sends the `viewDidAppear` a real app gets, through
    /// the swizzled method; were the host to send it too, the dedupe absorbs
    /// the second call.
    private func appeared(_ controller: UIViewController?) {
        controller?.viewDidAppear(false)
        spin(0.05)
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func screenNames(of client: Cohorly? = nil, _ transport: MockTransport? = nil) async -> [String] {
        await (client ?? self.client).flush()
        return (transport ?? self.transport).requests.filter { $0.path == "/track" }.flatMap {
            (try? JSONDecoder().decode([TrackEvent].self, from: $0.body)) ?? []
        }.compactMap { event -> String? in
            guard event.event == "$screen", case .string(let name)? = event.properties["$screen_name"] else { return nil }
            return name
        }
    }

    @MainActor func testPushThenPopEmitsEachScreenIncludingTheReturn() async {
        let a = ScreenAViewController()
        let navigation = UINavigationController(rootViewController: a)
        show(navigation)
        navigation.pushViewController(ScreenBViewController(), animated: false)
        spin()
        navigation.popViewController(animated: false)
        spin()
        let names = await screenNames()
        XCTAssertEqual(names, ["ScreenAViewController", "ScreenBViewController", "ScreenAViewController"])
    }

    @MainActor func testTabSwitchAndBackEmitsThree() async {
        let tabs = UITabBarController()
        tabs.viewControllers = [ScreenAViewController(), ScreenBViewController()]
        show(tabs)
        tabs.selectedIndex = 1
        spin()
        appeared(tabs.selectedViewController)
        tabs.selectedIndex = 0
        spin()
        appeared(tabs.selectedViewController)
        let names = await screenNames()
        XCTAssertEqual(names, ["ScreenAViewController", "ScreenBViewController", "ScreenAViewController"])
    }

    /// The scene-less host attaches a presented controller's views to the
    /// window only some of the time and never finishes a dismissal, so the
    /// emission on present and dismiss is checked on the simulator. This checks
    /// the walk the hook relies on: a presented controller, then the visible
    /// controller of a presented navigation stack.
    @MainActor func testTopControllerWalksIntoPresentedControllers() {
        let a = ScreenAViewController()
        show(a)
        let sheet = ScreenBViewController()
        sheet.modalPresentationStyle = .fullScreen
        a.present(sheet, animated: false)
        spin()
        XCTAssertTrue(ScreenViewSwizzle.topController(of: window) === sheet)
        let root = ScreenAViewController()
        show(root)
        let c = ScreenCViewController()
        let navigation = UINavigationController(rootViewController: c)
        navigation.modalPresentationStyle = .fullScreen
        root.present(navigation, animated: false)
        spin()
        XCTAssertTrue(ScreenViewSwizzle.topController(of: window) === c)
        let b = ScreenBViewController()
        navigation.pushViewController(b, animated: false)
        spin()
        XCTAssertTrue(ScreenViewSwizzle.topController(of: window) === b)
    }

    /// A page sheet dismissed and presented again, with no other screen in
    /// between, leaves the same controller as the last one: it must emit again.
    /// The callbacks go through the swizzled methods, as in `appeared`.
    @MainActor func testTheSameControllerEmitsAgainAfterItDisappeared() async {
        let a = ScreenAViewController()
        show(a)
        a.viewDidDisappear(false)
        spin(0.05)
        a.viewDidAppear(false)
        spin(0.05)
        a.viewDidAppear(false)
        spin(0.05)
        let names = await screenNames()
        XCTAssertEqual(names, ["ScreenAViewController", "ScreenAViewController"])
    }

    @MainActor func testSubclassOverrideRunsBeforeTheHookAndASecondRegisterKeepsTheSwizzle() async {
        let selector = #selector(UIViewController.viewDidAppear(_:))
        let method = class_getInstanceMethod(UIViewController.self, selector)
        let installedIMP = method.map(method_getImplementation)
        _ = makeClient()
        XCTAssertEqual(method.map(method_getImplementation), installedIMP)
        let overriding = OverridingViewController()
        show(overriding)
        XCTAssertTrue(overriding.ranOwnViewDidAppear)
        let names = await screenNames()
        XCTAssertEqual(names, ["OverridingViewController"])
    }

    @MainActor func testAlertEmitsNothingAndDoesNotBreakTheDedupe() async {
        let a = ScreenAViewController()
        show(a)
        let alert = UIAlertController(title: "t", message: nil, preferredStyle: .alert)
        a.present(alert, animated: false)
        spin()
        alert.dismiss(animated: false)
        spin()
        // `UIAlertController` is ignored and does not change the last emitted.
        // Whether or not UIKit calls `viewDidAppear` on `a` after the alert
        // is gone, `a` is still the last emitted one, so there is one `$screen`.
        let names = await screenNames()
        XCTAssertEqual(names, ["ScreenAViewController"])
    }

    @MainActor func testNewInstanceOfTheSameClassEmitsAgain() async {
        let navigation = UINavigationController(rootViewController: ScreenAViewController())
        show(navigation)
        navigation.pushViewController(ScreenAViewController(), animated: false)
        spin()
        let names = await screenNames()
        XCTAssertEqual(names, ["ScreenAViewController", "ScreenAViewController"])
    }

    @MainActor func testEachInstanceKeepsItsOwnDedupe() async {
        let otherTransport = MockTransport()
        let other = Cohorly(
            apiHost: "http://localhost:4000", transport: otherTransport, storage: InMemoryStorage(),
            flushInterval: 3600, flushAt: 1000, trackScreenViews: true,
            flagsFetcher: NoFlagsForScreens(), loadFeatureFlags: false)
        show(ScreenAViewController())
        let first = await screenNames()
        let second = await screenNames(of: other, otherTransport)
        XCTAssertEqual(first, ["ScreenAViewController"])
        XCTAssertEqual(second, ["ScreenAViewController"])
    }

    @MainActor func testOffInstanceEmitsNothingWhileAnotherIsOn() async {
        // The swizzle is installed (by `client`), yet a default instance hears nothing.
        let offTransport = MockTransport()
        let off = Cohorly(
            apiHost: "http://localhost:4000", transport: offTransport, storage: InMemoryStorage(),
            flushInterval: 3600, flushAt: 1000,
            flagsFetcher: NoFlagsForScreens(), loadFeatureFlags: false)
        XCTAssertNil(off.screenViewTracker)
        show(ScreenAViewController())
        let offNames = await screenNames(of: off, offTransport)
        let onNames = await screenNames()
        XCTAssertEqual(offNames, [])
        XCTAssertEqual(onNames, ["ScreenAViewController"])
    }
}

private struct NoFlagsForScreens: CohorlyFlagsFetcher {
    func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? { nil }
}
#endif
