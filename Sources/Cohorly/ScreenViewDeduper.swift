import Foundation

/// Decides whether a view controller that became the visible screen
/// produces a `$screen`. No UIKit: it only sees an object and its class name,
/// so the rule is unit-tested on any platform.
///
/// - A class name starting with `UI` or `_` (containers, `UIAlertController`,
///   `UIHostingController`, other system controllers) is skipped, and a skipped
///   call never changes the last emitted controller.
/// - The same instance that produced the last `$screen` produces no other.
///   Going back to a previous controller after another one does, so does a
///   new instance of the same class, and so does the same instance shown again
///   after it disappeared.
///
/// The last emitted controller is held weakly: the SDK never retains a view
/// controller, and a freed address reused by a new instance must still emit
/// (which an `ObjectIdentifier` could not tell).
final class ScreenViewDeduper: @unchecked Sendable {
    private let lock = NSLock()
    private weak var last: AnyObject?

    /// The prefix of the runtime subclass KVO makes of an observed object.
    private static let kvoPrefix = "NSKVONotifying_"

    /// The class name without module, the value of `$screen_name`.
    static func screenName(of controller: AnyObject) -> String {
        displayName(ofClassNamed: String(describing: type(of: controller)))
    }

    /// An observed (KVO) Objective-C controller can report the runtime
    /// subclass KVO made of it; the screen is the class it was made from.
    static func displayName(ofClassNamed name: String) -> String {
        name.hasPrefix(kvoPrefix) ? String(name.dropFirst(kvoPrefix.count)) : name
    }

    /// True for the class names the SDK never reports.
    static func isIgnored(className: String) -> Bool {
        className.hasPrefix("UI") || className.hasPrefix("_")
    }

    /// The `$screen_name` to emit for `controller`, or nil. Records it as the
    /// last emitted when it returns a name.
    func nameToEmit(for controller: AnyObject) -> String? {
        nameToEmit(for: controller, className: Self.screenName(of: controller))
    }

    /// `controller` left the screen. If it was the last emitted one, showing it
    /// again emits again (a sheet dismissed and presented a second time). A
    /// controller that is not the last one changes nothing.
    func disappeared(_ controller: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        if last === controller { last = nil }
    }

    func nameToEmit(for controller: AnyObject, className: String) -> String? {
        if Self.isIgnored(className: className) { return nil }
        lock.lock()
        defer { lock.unlock() }
        if last === controller { return nil }
        last = controller
        return className
    }
}
