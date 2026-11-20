@_spi(CohorlyReplay) import Cohorly
import Foundation

/// Native crash reporting for a Swift app (ADR-0020): KSCrash records signals,
/// Mach exceptions, uncaught NSExceptions and C++ exceptions to disk, and the
/// next launch sends each one as a `$exception` event (level `fatal`) through
/// a background upload. MetricKit crash, hang and CPU diagnostics are sent too
/// (levels `error` and `warning`).
///
/// ```swift
/// func application(_ application: UIApplication,
///                  didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
///     let cohorly = Cohorly.initialize(token: "<project token>")
///     CohorlyCrash.install(cohorly: cohorly)
///     ...
/// }
/// ```
///
/// Never install a second crash reporter (e.g. Sentry's
/// `enableNativeCrashHandling`) in the same process.
public enum CohorlyCrash {
    /// `$lib_version` of crash events; mirrors the `Cohorly` SDK version.
    static let libVersion = "0.10.0"

    /// Guards the state below AND every write of it to the reporter, so the
    /// user info KSCrash holds is always the newest (an older one never
    /// lands after a newer one).
    private static let lock = NSLock()
    private static var observer: NSObjectProtocol?
    private static var sessionObserver: NSObjectProtocol?
    private static var userInfo = CrashUserInfo()
    /// Bumped by every identity notification: an identity read before one
    /// arrived is stale.
    private static var identityVersion: UInt64 = 0
    /// The reporter (tests swap it). Read and written under `lock`.
    private static var reporter: CrashUserInfoReporter = CrashReporter.shared

    /// Installs the reporter now and starts sending the reports of earlier
    /// launches in the background. Call it in `didFinishLaunching`, right
    /// after `Cohorly.initialize`. Uses the instance's token and API host,
    /// stamps its identity on crashes and follows `identify()`/`reset()`.
    ///
    /// - Parameters:
    ///   - release: `$exception_release` of crashes in this launch. Defaults to
    ///     `<CFBundleIdentifier>@<CFBundleShortVersionString>+<CFBundleVersion>`;
    ///     must equal the `--release` of `cohorly debug-files upload`.
    ///   - dist: `$exception_dist`, optional.
    /// - Returns: false when the instance has no token or the install failed.
    @discardableResult
    public static func install(cohorly: Cohorly, release: String? = nil, dist: String? = nil) -> Bool {
        guard let endpoint = CrashEndpoint(token: cohorly.configuredToken, host: cohorly.configuredAPIHost) else {
            CrashLog.log("CohorlyCrash.install needs a Cohorly instance with a token and an http(s) API host; not installed")
            return false
        }
        let release = release ?? CrashRelease.fromInfoDictionary(Bundle.main.infoDictionary ?? [:])
        lock.lock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: Cohorly.identityDidChangeNotification, object: cohorly, queue: nil
        ) { note in
            identityDidChange(note.userInfo)
        }
        // With CohorlyReplay installed (before or after this), a crash carries
        // the $session_id of the session it happened in.
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: Cohorly.replaySessionDidChangeNotification, object: cohorly, queue: nil
        ) { note in
            replaySessionDidChange(note.userInfo?[Cohorly.ReplaySessionKey.sessionId] as? String)
        }
        userInfo.release = release
        userInfo.dist = dist
        let versionBeforeRead = identityVersion
        lock.unlock()

        // Read outside the lock: these wait on the SDK queue, which may be
        // posting an identity notification to the observer above.
        let distinctId = cohorly.currentDistinctId
        let deviceId = cohorly.currentDeviceId
        let userId = cohorly.currentUserId

        lock.lock()
        if identityVersion == versionBeforeRead {
            userInfo.distinctId = distinctId
            userInfo.deviceId = deviceId
            userInfo.userId = userId
        }
        userInfo.sessionId = cohorly.currentReplaySessionId
        let info = userInfo
        let reporter = self.reporter
        lock.unlock()

        let installed = reporter.start(
            .install(endpoint: endpoint, userInfo: info, metricKit: true),
            lib: CrashLibInfo(lib: "ios", version: libVersion)
        )
        // A change while the reporter was starting reached nothing (it only
        // takes user info once installed): apply the newest state now.
        lock.lock()
        userInfo.sessionId = cohorly.currentReplaySessionId
        self.reporter.updateUserInfo(userInfo)
        lock.unlock()
        return installed
    }

    /// True once `install(cohorly:)` succeeded in this process.
    public static var isInstalled: Bool { CrashReporter.shared.isInstalled }

    /// Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// here. Returns true when the session is the reporter's (it then calls
    /// `completionHandler`); false means the identifier belongs to someone else.
    @discardableResult
    public static func handleEventsForBackgroundURLSession(
        _ identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        CrashReporter.shared.handleEventsForBackgroundURLSession(identifier, completionHandler: completionHandler)
    }

    static func identityDidChange(_ values: [AnyHashable: Any]?) {
        update { info in
            identityVersion &+= 1
            info.distinctId = values?[Cohorly.IdentityKey.distinctId] as? String
            info.deviceId = values?[Cohorly.IdentityKey.deviceId] as? String
            info.userId = values?[Cohorly.IdentityKey.userId] as? String
        }
    }

    static func replaySessionDidChange(_ sessionId: String?) {
        update { $0.sessionId = sessionId }
    }

    /// Changes the user info and writes it to the reporter in one step.
    private static func update(_ change: (inout CrashUserInfo) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&userInfo)
        reporter.updateUserInfo(userInfo)
    }

    /// The user info crashes of this launch carry (for tests).
    static var currentUserInfo: CrashUserInfo {
        lock.lock(); defer { lock.unlock() }
        return userInfo
    }

    /// Tests only: swaps the reporter and drops the observers and state.
    static func resetForTesting(reporter: CrashUserInfoReporter = CrashReporter.shared) {
        lock.lock()
        defer { lock.unlock() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
        observer = nil
        sessionObserver = nil
        userInfo = CrashUserInfo()
        self.reporter = reporter
    }
}

/// What `CohorlyCrash` drives: `CrashReporter` in an app, a fake in tests.
protocol CrashUserInfoReporter: AnyObject {
    @discardableResult
    func start(_ decision: CrashLaunchDecision, lib: CrashLibInfo) -> Bool
    /// Writes the user info for crashes of this launch; a no-op until started.
    func updateUserInfo(_ userInfo: CrashUserInfo)
}

extension CrashReporter: CrashUserInfoReporter {}
