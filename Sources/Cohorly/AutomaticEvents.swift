import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Drives Mixpanel-style automatic (`$ae_*`) lifecycle events when
/// `trackAutomaticEvents` is enabled:
///
/// - `$ae_first_open`  - fired once ever (guarded by a UserDefaults flag).
/// - `$ae_updated`     - fired when the stored last-seen app version differs
///                       from the current one (prop `$ae_updated_version`).
/// - `$ae_session`     - fired on background/terminate with `$ae_session_length`
///                       (seconds, integer) when the session ran for >= 10s.
///
/// Sessions are bracketed by foreground/background notifications on UIKit
/// platforms. On non-UIKit platforms (e.g. a macOS test host) a single session
/// runs from `start()` to `appWillTerminate()` (called from `Cohorly.deinit`).
///
/// The clock is injected so session-length math is deterministic in tests.
final class AutomaticEvents: @unchecked Sendable {
    private enum Keys {
        static let didFirstOpen = "cohorly.ae.did_first_open"
        static let lastVersion = "cohorly.ae.last_version"
    }

    /// Minimum session duration (seconds) that produces an `$ae_session`.
    static let minSessionLength: TimeInterval = 10

    private weak var client: Cohorly?
    private let storage: CohorlyStorage
    private let clock: CohorlyClock

    private let lock = NSLock()
    private var sessionStart: Date?

    init(client: Cohorly, storage: CohorlyStorage, clock: CohorlyClock) {
        self.client = client
        self.storage = storage
        self.clock = clock
    }

    deinit {
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    /// Runs first-open / updated detection, begins the initial session, and
    /// registers lifecycle observers on UIKit platforms. `currentVersion` is
    /// the host app version (injected in tests, `DeviceInfo.appVersion` live).
    func start(currentVersion: String?) {
        if storage.string(forKey: Keys.didFirstOpen) == nil {
            storage.setString("1", forKey: Keys.didFirstOpen)
            client?.track("$ae_first_open")
            client?.people.setOnce(["$ae_first_app_open_date": Self.iso8601(clock.now())])
        }

        if let currentVersion {
            let lastVersion = storage.string(forKey: Keys.lastVersion)
            if let lastVersion, lastVersion != currentVersion {
                client?.track("$ae_updated", properties: ["$ae_updated_version": currentVersion])
            }
            storage.setString(currentVersion, forKey: Keys.lastVersion)
        }

        beginSession()
        registerLifecycleObservers()
    }

    // MARK: - Session tracking

    /// Marks the start of a session (idempotent - resets the start instant).
    func beginSession() {
        lock.lock()
        sessionStart = clock.now()
        lock.unlock()
    }

    /// Ends the current session, emitting `$ae_session` + a profile increment
    /// when it ran for at least `minSessionLength` seconds. `via` overrides the
    /// weak back-reference: during `Cohorly.deinit` weak refs to the client
    /// already read nil, so the deinit path must pass the client explicitly.
    func endSession(via strongClient: Cohorly? = nil) {
        lock.lock()
        guard let start = sessionStart else {
            lock.unlock()
            return
        }
        sessionStart = nil
        lock.unlock()

        let length = clock.now().timeIntervalSince(start)
        guard length >= Self.minSessionLength else { return }

        let target = strongClient ?? client
        target?.track("$ae_session", properties: ["$ae_session_length": Int(length)])
        target?.people.increment(["$ae_total_app_sessions": 1])
    }

    /// Called from `Cohorly.deinit`; closes the final session on platforms
    /// without foreground/background notifications. The client is passed
    /// explicitly because the weak back-reference is nil by deinit time.
    func appWillTerminate(via strongClient: Cohorly) {
        endSession(via: strongClient)
    }

    // MARK: - Lifecycle wiring

    private func registerLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(handleWillResignActive),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(handleWillResignActive),
            name: UIApplication.willTerminateNotification, object: nil)
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    @objc private func handleDidBecomeActive() {
        beginSession()
    }

    @objc private func handleWillResignActive() {
        endSession()
    }
    #endif

    // MARK: - Helpers

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
