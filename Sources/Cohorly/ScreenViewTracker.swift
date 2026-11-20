import Foundation
import ObjectiveC

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Turns the visible screen into `$screen` events for one `Cohorly` instance
/// when `trackScreenViews` is on. Each instance has its own dedupe state; the
/// emission goes through the public `track`, so super properties, default
/// properties, `$session_id` (replay installed) and the event quota apply as
/// for any event. The only property it adds is `$screen_name`.
final class ScreenViewTracker: @unchecked Sendable {
    private weak var client: Cohorly?
    private let deduper = ScreenViewDeduper()

    init(client: Cohorly) {
        self.client = client
    }

    /// `controller` is the top controller of the window that just showed one.
    func screenAppeared(_ controller: AnyObject) {
        guard let name = deduper.nameToEmit(for: controller) else { return }
        client?.track("$screen", properties: ["$screen_name": name])
    }

    /// A controller left the screen; see `ScreenViewDeduper.disappeared`.
    func screenDisappeared(_ controller: AnyObject) {
        deduper.disappeared(controller)
    }
}

/// The process-wide `UIViewController.viewDidAppear(_:)` swizzle, installed
/// once, only when some instance turns `trackScreenViews` on, and never
/// removed: a registry of weakly held trackers decides who hears it, and with
/// none the hook only forwards. The replacement calls the implementation it
/// replaced FIRST (the original, or another SDK's swizzle installed before),
/// so it does not depend on ordering with other libraries. Off platforms
/// without UIKit it does nothing.
enum ScreenViewSwizzle {
    private final class WeakTracker {
        weak var tracker: ScreenViewTracker?
        init(_ tracker: ScreenViewTracker) { self.tracker = tracker }
    }

    private static let lock = NSLock()
    private static nonisolated(unsafe) var trackers: [WeakTracker] = []
    private static nonisolated(unsafe) var installScheduled = false
    private static nonisolated(unsafe) var installed = false

    /// True once the swizzle is in place. Internal, for tests.
    static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    /// Adds `tracker` to those notified and installs the swizzle the first time.
    static func register(_ tracker: ScreenViewTracker) {
        lock.lock()
        trackers.removeAll { $0.tracker == nil }
        trackers.append(WeakTracker(tracker))
        let mustInstall = !installScheduled
        installScheduled = true
        lock.unlock()
        if mustInstall { install() }
    }

    static func isRegistered(_ tracker: ScreenViewTracker) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trackers.contains { $0.tracker === tracker }
    }

    private static func liveTrackers() -> [ScreenViewTracker] {
        lock.lock()
        defer { lock.unlock() }
        return trackers.compactMap(\.tracker)
    }

    private typealias BoolMethodIMP = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias BoolMethodBlock = @convention(block) (AnyObject, Bool) -> Void

    /// Replaces the `(Bool) -> Void` method `selector` of `cls` with one that
    /// calls the implementation it replaced, then `after` with the receiver.
    /// False when `cls` has no such method. Internal, so the call to the
    /// replaced implementation is tested on a plain class.
    @discardableResult
    static func hook(_ cls: AnyClass, _ selector: Selector, after: @escaping (AnyObject) -> Void) -> Bool {
        guard let method = class_getInstanceMethod(cls, selector) else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: BoolMethodIMP.self)
        let replacement: BoolMethodBlock = { object, flag in
            original(object, selector, flag)
            after(object)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }

    #if canImport(UIKit) && !os(watchOS)

    /// Swizzles on the main thread: now when already there, else hops to it.
    private static func install() {
        if Thread.isMainThread {
            installOnMain()
        } else {
            DispatchQueue.main.async { installOnMain() }
        }
    }

    private static func installOnMain() {
        let selector = #selector(UIViewController.viewDidAppear(_:))
        let hooked = hook(UIViewController.self, selector) { object in
            if let controller = object as? UIViewController { viewDidAppear(controller) }
        }
        guard hooked else { return }
        hook(UIViewController.self, #selector(UIViewController.viewDidDisappear(_:))) { object in
            liveTrackers().forEach { $0.screenDisappeared(object) }
        }
        lock.lock()
        installed = true
        lock.unlock()
    }

    /// Runs after the original `viewDidAppear`. `controller` itself is not
    /// reported (containers and children also receive it): the top controller
    /// of its window is.
    private static func viewDidAppear(_ controller: UIViewController) {
        let active = liveTrackers()
        if active.isEmpty { return }
        guard let window = controller.viewIfLoaded?.window, !isKeyboardWindow(window),
              let top = topController(of: window) else { return }
        active.forEach { $0.screenAppeared(top) }
    }

    /// The input windows UIKit adds for the keyboard never hold a screen.
    static func isKeyboardWindow(_ window: UIWindow) -> Bool {
        let name = String(describing: type(of: window))
        return name.contains("Keyboard") || name.contains("TextEffects")
    }

    /// The controller on top of `window`: root, then presented (not being
    /// dismissed), a navigation stack's visible one, a tab bar's selected one,
    /// until stable. Same rule as session replay's `href` (kept as a copy:
    /// `Cohorly` cannot depend on `CohorlyReplay`).
    static func topController(of window: UIWindow) -> UIViewController? {
        guard var controller = window.rootViewController else { return nil }
        var steps = 0
        while steps < 32 {
            steps += 1
            if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                controller = presented
            } else if let navigation = controller as? UINavigationController,
                      let top = navigation.visibleViewController ?? navigation.topViewController {
                if top === controller { break }
                controller = top
            } else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
                controller = selected
            } else {
                break
            }
        }
        return controller
    }
    #else
    private static func install() {}
    #endif
}
