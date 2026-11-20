@_spi(CohorlyReplay) import Cohorly
import CryptoKit
import Foundation

/// How the iOS recorder describes the screen.
public enum CohorlyReplayMode: String, Sendable {
    /// Each view as a wireframe (position, size, colors, text, kind): small,
    /// but SwiftUI `Text`, shapes and layer drawings do not appear.
    case wireframe
    /// One JPEG of the key window per capture (1 point per pixel, quality
    /// 0.3), masked in its pixels before it is encoded: everything on screen
    /// appears, at a higher size and CPU cost.
    case screenshot
}

/// Session replay options. Rates are shares of sessions, 0 to 1 (a value
/// outside is clamped, NaN is 0), drawn once per session.
public struct CohorlyReplayConfig: Sendable, Equatable {
    /// Share of sessions recorded whole. Default 0.
    public let sampleRate: Double
    /// Share of the remaining sessions that keep a short buffer and send it
    /// when an error happens. Default 0.
    public let onErrorSampleRate: Double
    /// Mask every image in recordings. Default true.
    public let maskAllImages: Bool
    /// Wireframes or screenshots. Default `.wireframe`.
    public let mode: CohorlyReplayMode
    /// Read the replay settings saved in the dashboard
    /// (`GET /replay/config`, cached for an hour): a saved sample rate,
    /// error sample rate or minimum duration replaces the code's for new
    /// sessions. A new session waits for them at most 3 seconds, recording
    /// nothing meanwhile. Triggers, masking and the capture mode stay in
    /// code. Default false: no request is made.
    public let remoteConfig: Bool

    public init(
        sampleRate: Double = 0, onErrorSampleRate: Double = 0, maskAllImages: Bool = true,
        mode: CohorlyReplayMode = .wireframe, remoteConfig: Bool = false
    ) {
        self.sampleRate = Self.clamp(sampleRate)
        self.onErrorSampleRate = Self.clamp(onErrorSampleRate)
        self.maskAllImages = maskAllImages
        self.mode = mode
        self.remoteConfig = remoteConfig
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    /// The recorder's view of this config (Recorder/ knows no public type).
    var recorderConfig: ReplayRecorderConfig {
        let captureMode: ReplayCaptureMode
        switch mode {
        case .wireframe: captureMode = .wireframe
        case .screenshot: captureMode = .screenshot
        }
        return ReplayRecorderConfig(captureMode: captureMode, maskAllImages: maskAllImages)
    }
}

/// Session replay for a Swift app (docs/SESSION-REPLAY.md). Installing it
/// makes the SDK stamp `$session_id` on every tracked event and on
/// `CohorlyCrash` crashes, draws each session's sampling decision, and sends
/// the recorded chunks to `POST /replay` from a queue on disk.
///
/// ```swift
/// let cohorly = Cohorly.initialize(token: "<project token>")
/// CohorlyReplay.install(cohorly: cohorly, config: CohorlyReplayConfig(sampleRate: 0.1, onErrorSampleRate: 1))
/// ```
public enum CohorlyReplay {
    /// Held across a whole install or uninstall: two never interleave.
    private static let installLock = NSLock()
    private static let lock = NSLock()
    private static var runtime: ReplayRuntime?

    /// Installs replay on `cohorly`, replacing an earlier install. Call it
    /// right after `Cohorly.initialize`.
    ///
    /// - Returns: false when the instance has no token or no http(s) API host.
    @discardableResult
    public static func install(cohorly: Cohorly, config: CohorlyReplayConfig = CohorlyReplayConfig()) -> Bool {
        install(cohorly: cohorly, config: config, environment: ReplayEnvironment()) != nil
    }

    /// True once `install` succeeded in this process.
    public static var isInstalled: Bool { current != nil }

    /// Tells replay an error happened, for errors that do not go through
    /// `Cohorly.track("$exception", ...)` (which does this by itself). A
    /// session drawn for error mode (`onErrorSampleRate`) then sends its
    /// buffer, the last 30 to 60 seconds, at most once every 5 seconds (an
    /// error inside that gap goes with the next send). Nothing happens when
    /// replay is not installed or the session is not in error mode. Safe
    /// from any thread; never waits.
    public static func notifyError() {
        current?.noteError()
    }

    static var current: ReplayRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }

    @discardableResult
    static func install(cohorly: Cohorly, config: CohorlyReplayConfig, environment: ReplayEnvironment) -> ReplayRuntime? {
        guard let host = normalizedHost(cohorly.configuredAPIHost),
              let endpoint = replayEndpoint(host: host),
              let token = cohorly.configuredToken, !token.isEmpty
        else {
            ReplayLog.log("CohorlyReplay.install needs a Cohorly instance with a token and an http(s) API host; not installed")
            return nil
        }
        installLock.lock()
        defer { installLock.unlock() }
        // The previous runtime is fully stopped (its pending writes done, its
        // hooks removed) before the new queue reads the disk.
        takeRuntime()?.stop()
        let installed = ReplayRuntime(
            cohorly: cohorly, config: config, environment: environment, endpoint: endpoint, token: token,
            namespace: ReplayNamespace.make(host: host, token: token),
            configURL: ReplayRemoteConfigLoader.configURL(host: host, token: token))
        lock.lock()
        runtime = installed
        lock.unlock()
        return installed
    }

    /// Removes the install (tests).
    static func uninstall() {
        installLock.lock()
        defer { installLock.unlock() }
        takeRuntime()?.stop()
    }

    private static func takeRuntime() -> ReplayRuntime? {
        lock.lock()
        defer { lock.unlock() }
        let previous = runtime
        runtime = nil
        return previous
    }

    /// The API host without surrounding whitespace or trailing slashes, nil
    /// when it is not an http(s) URL with a host.
    static func normalizedHost(_ host: String) -> String? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return trimmed
    }

    static func replayEndpoint(host: String) -> URL? {
        guard let normalized = normalizedHost(host), let url = URL(string: normalized) else { return nil }
        return url.appendingPathComponent("replay")
    }
}

/// Keeps two projects (API host + token) apart on one device: their chunk
/// directories and persisted keys are suffixed with a short hash of both.
/// The token itself is never written.
enum ReplayNamespace {
    static func make(host: String, token: String) -> String {
        let digest = SHA256.hash(data: Data("\(host)|\(token)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a runtime is built from besides the `Cohorly` instance (whose
/// storage, clock and maximum retry delay it reuses). Tests swap each part.
struct ReplayEnvironment {
    var transport: ReplayTransport = URLSessionReplayTransport()
    var lifecycle: ReplayLifecycleSource = SystemReplayLifecycle()
    /// [0, 1), drives the sampling decision and the backoff jitter.
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    /// Parent of the per-project chunk directories.
    var rootDirectory: URL = ReplayChunkQueue.defaultRootDirectory
    var maxDiskBytes: Int = ReplayChunkQueue.defaultMaxDiskBytes
    var writeFile: ReplayFileWriter = ReplayChunkQueue.defaultFileWriter
    /// Builds the screen recorder of a new runtime (nil: none). On iOS the
    /// wireframe recorder; elsewhere nothing is recorded.
    var makeRecorder: (ReplayRuntime) -> ReplayRecorder? = ReplayRuntime.platformRecorder
    /// Runs the remote settings' 3 s wait and 30 s abort.
    var configSchedule: ReplayConfigSchedule = ReplayRemoteConfigLoader.defaultSchedule
    /// The clock those two are measured with.
    var configMonotonicNow: ReplayConfigMonotonicNow = ReplayRemoteConfigLoader.defaultMonotonicNow
}

/// One install: wires the session store and the chunk queue to the
/// `Cohorly` instance through its `@_spi(CohorlyReplay)` hooks.
final class ReplayRuntime: ReplayRecorderHost, @unchecked Sendable {
    let sessions: ReplaySessionStore
    let chunks: ReplayChunkQueue
    let config: CohorlyReplayConfig
    let namespace: String
    /// The settings new sessions are decided with (`config.remoteConfig`).
    let settings: ReplayRemoteSettings
    /// Holds a `session` mode recording until its minimum duration.
    let hold = ReplayMinDurationHold()
    /// The screen recorder (iOS), started with the runtime and stopped with it.
    var recorder: ReplayRecorder? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recorderValue
    }
    private var recorderValue: ReplayRecorder?
    private let clock: CohorlyClock

    private weak var cohorly: Cohorly?
    private let lifecycle: ReplayLifecycleSource
    private let stateLock = NSLock()
    private var stopped = false
    private var optedOut = false
    /// Newest session generation published; an older one is never posted.
    private var publishedGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var removeTrackedEventObserver: (@Sendable () -> Void)?

    init(
        cohorly: Cohorly, config: CohorlyReplayConfig, environment: ReplayEnvironment,
        endpoint: URL, token: String, namespace: String, configURL: URL? = nil
    ) {
        self.cohorly = cohorly
        self.config = config
        self.namespace = namespace
        clock = cohorly.configuredClock
        lifecycle = environment.lifecycle
        let random = environment.random
        var loader: ReplayRemoteConfigLoader?
        if config.remoteConfig, let configURL {
            loader = ReplayRemoteConfigLoader(
                url: configURL, namespace: namespace, storage: cohorly.configuredStorage, clock: cohorly.configuredClock,
                transport: environment.transport, schedule: environment.configSchedule,
                monotonicNow: environment.configMonotonicNow)
        }
        // Before the store: a new session at launch is decided by it. Its
        // request (when one starts) never blocks this init.
        settings = ReplayRemoteSettings(code: config, loader: loader, random: random)
        sessions = ReplaySessionStore(
            storage: cohorly.configuredStorage, clock: cohorly.configuredClock, namespace: namespace, decider: settings)
        chunks = ReplayChunkQueue(
            endpoint: endpoint,
            token: token,
            namespace: namespace,
            root: environment.rootDirectory.appendingPathComponent(namespace, isDirectory: true),
            maxDiskBytes: environment.maxDiskBytes,
            backoff: CohorlyBackoff(maxDelay: cohorly.configuredMaxRetryDelay),
            libVersion: Cohorly.sdkVersion,
            transport: environment.transport,
            clock: cohorly.configuredClock,
            storage: cohorly.configuredStorage,
            sessions: sessions,
            random: random,
            writeFile: environment.writeFile
        )
        sessions.onRotate = { [weak self] session, generation in
            self?.publish(session, generation)
            // The old session's buffer goes out now, under its own id.
            self?.recorder?.sessionDidRotate()
        }

        // Observers first, then the state they follow: a change landing in
        // between is seen twice, never missed. Every handler runs on the
        // poster's thread and only takes locks or dispatches async.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: Cohorly.identityDidChangeNotification, object: cohorly, queue: nil
        ) { [weak self] note in
            guard let id = note.userInfo?[Cohorly.IdentityKey.distinctId] as? String else { return }
            self?.sessions.setDistinctId(id)
        })
        observers.append(center.addObserver(
            forName: Cohorly.didResetNotification, object: cohorly, queue: nil
        ) { [weak self] note in
            // The new identity and the new session are taken in one step.
            self?.sessions.rotate(distinctId: note.userInfo?[Cohorly.IdentityKey.distinctId] as? String)
        })
        observers.append(center.addObserver(
            forName: Cohorly.trackingOptOutDidChangeNotification, object: cohorly, queue: nil
        ) { [weak self] note in
            guard let self, let optedOut = note.userInfo?[Cohorly.optedOutKey] as? Bool else { return }
            self.setOptedOut(optedOut)
            if optedOut {
                self.recorder?.setPaused(true)
                self.hold.discard()
                self.chunks.stopAndDiscard()
            } else {
                self.sessions.rotate()
                self.chunks.start()
                self.recorder?.setPaused(false)
            }
        })
        let identityVersion = sessions.currentIdentityVersion
        sessions.setDistinctId(cohorly.currentDistinctId, ifUnchangedSince: identityVersion)

        cohorly.setSessionIdProvider { [weak self] _ in
            self?.sessions.sessionIdForEvent()
        }
        lifecycle.start { [weak self] event in
            switch event {
            case .didEnterBackground:
                self?.sessions.didEnterBackground()
                self?.recorder?.didEnterBackground()
            case .willEnterForeground:
                // The session first: a rotation here makes the recorder's
                // next capture a full snapshot of the new session.
                self?.sessions.willEnterForeground()
                self?.recorder?.willEnterForeground()
            }
        }
        let (session, generation) = sessions.snapshot
        publish(session, generation)
        let optedOutNow = cohorly.hasOptedOutTracking()
        if optedOutNow {
            setOptedOut(true)
            chunks.stopAndDiscard()
        } else {
            chunks.start()
        }
        let recorder = environment.makeRecorder(self)
        stateLock.lock()
        recorderValue = recorder
        stateLock.unlock()
        recorder?.setPaused(optedOutNow)
        recorder?.start()
        // Called on the SDK queue for every queued event: only a hop to the
        // recorder's queue happens there.
        let removeObserver = cohorly.addTrackedEventObserver { [weak self] name, properties in
            guard name == ReplayRuntime.exceptionEvent else { return }
            // The session stamped on the event: an `$exception` that rotated
            // the session belongs to the new one, which has no snapshot yet.
            var sessionId: String?
            if case .string(let stamped)? = properties["$session_id"] { sessionId = stamped }
            self?.noteError(sessionId: sessionId)
        }
        stateLock.lock()
        removeTrackedEventObserver = removeObserver
        stateLock.unlock()
        // A pending session (born now, or persisted by the previous launch)
        // is decided when the settings resolve, or now if they already did.
        settings.onSettled = { [weak self] in self?.settlePendingSession() }
        settlePendingSession()
    }

    /// Decides the live session when it is pending and the settings are
    /// resolved; the recorder then starts with a full snapshot.
    func settlePendingSession() {
        stateLock.lock()
        let stopped = self.stopped
        stateLock.unlock()
        guard !stopped else { return }
        let settings = self.settings
        guard sessions.settlePending({ settings.decisionForPending() }) != nil else { return }
        recorder?.requestCapture(full: true)
    }

    static let exceptionEvent = "$exception"

    /// The recorder `install` starts: the key window on iOS, as wireframes
    /// or screenshots (`config.mode`); none elsewhere (`swift test` on macOS
    /// builds the runtime without it).
    static func platformRecorder(_ runtime: ReplayRuntime) -> ReplayRecorder? {
        #if os(iOS)
        return ReplayRecorder(host: runtime, source: makeSource(config: runtime.config), touchSource: SendEventTouchSource())
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// The capture source of `config.mode`.
    static func makeSource(config: CohorlyReplayConfig) -> ReplaySnapshotSource {
        config.recorderConfig.makeSource()
    }
    #endif

    /// An error happened in `sessionId` (nil = the live session): the
    /// recorder sends the error buffer when the session records in error
    /// mode. Any thread.
    func noteError(sessionId: String? = nil) {
        stateLock.lock()
        let stopped = self.stopped
        let recorder = recorderValue
        stateLock.unlock()
        guard !stopped else { return }
        recorder?.noteError(sessionId: sessionId)
    }

    /// The distinct id chunks queued now carry.
    var currentDistinctId: String { sessions.distinctId }

    /// The mode the live session records in now: off after an opt-out or a
    /// 404; a session-mode session buffers like error mode while the replay
    /// quota pause runs.
    var effectiveMode: ReplayMode {
        resolvedMode(sessions.session.mode)
    }

    /// `.off` while the session is pending (its mode is stored as `.off`).
    private func resolvedMode(_ mode: ReplayMode) -> ReplayMode {
        stateLock.lock()
        let off = optedOut || stopped
        stateLock.unlock()
        if off || chunks.isGoneNow { return .off }
        return mode == .session && chunks.isQuotaPaused ? .error : mode
    }

    // MARK: - ReplayRecorderHost

    func recordingState() -> ReplayRecordingState {
        let live = sessions.live
        return ReplayRecordingState(
            mode: resolvedMode(live.session.mode), sessionId: live.session.id, distinctId: live.distinctId)
    }

    var droppedChunks: Int { chunks.droppedChunks }

    var nowMs: Int64 { ReplaySessionStore.ms(clock.now()) }

    func enqueueRecorded(_ events: [ReplayJSON], mode: ReplayChunkMode, sessionId: String, distinctId: String) -> ReplayAdmission {
        stateLock.lock()
        let refused = stopped || optedOut
        stateLock.unlock()
        guard !refused else { return .refused }
        guard mode == .session else {
            return chunks.enqueue(events: events, mode: mode, sessionId: sessionId, distinctId: distinctId)
        }
        // The minimum duration of the chunk's own session (live or rotated
        // out); a session the store does not know is not held.
        guard let session = sessions.holdSession(sessionId) else {
            return chunks.enqueue(events: events, mode: mode, sessionId: sessionId, distinctId: distinctId)
        }
        switch hold.admit(events, sessionId: sessionId, distinctId: distinctId, session: session) {
        case .pass:
            return chunks.enqueue(events: events, mode: mode, sessionId: sessionId, distinctId: distinctId)
        case .held, .drop:
            return .queued
        case .release(let held):
            var admission = ReplayAdmission.queued
            for chunk in held {
                let result = chunks.enqueue(
                    events: chunk.events, mode: mode, sessionId: sessionId, distinctId: chunk.distinctId)
                if admission == .queued { admission = result }
            }
            return admission
        }
    }

    func noteActivity() {
        stateLock.lock()
        let stopped = self.stopped
        stateLock.unlock()
        guard !stopped else { return }
        sessions.noteActivity()
    }

    func afterPendingWrites(_ completion: @escaping () -> Void) {
        chunks.afterPendingWrites(completion)
    }

    /// Queues recorded events (rrweb-shaped JSON) of the live session. The
    /// session, distinct id and seq are those of this moment.
    func enqueue(events: [ReplayJSON], mode: ReplayChunkMode) {
        stateLock.lock()
        let stopped = self.stopped
        stateLock.unlock()
        guard !stopped else { return }
        chunks.enqueue(events: events, mode: mode)
    }

    /// Stops this install synchronously: no hook, observer or queue of it
    /// runs or writes after this returns.
    func stop() {
        stateLock.lock()
        stopped = true
        let recorder = recorderValue
        let removeObserver = removeTrackedEventObserver
        removeTrackedEventObserver = nil
        stateLock.unlock()
        // First: nothing it holds reaches the queue after this.
        recorder?.stop()
        hold.discard()
        removeObserver?()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        lifecycle.stop()
        cohorly?.setSessionIdProvider(nil)
        chunks.shutdown()
        sessions.close()
        cohorly?.publishReplaySession(nil)
    }

    private func setOptedOut(_ value: Bool) {
        stateLock.lock()
        optedOut = value
        stateLock.unlock()
    }

    /// Posts the session, never under a lock. A rotation older than one
    /// already published is ignored; when a newer one lands while this one
    /// is being posted, the newest is posted again so it is the last word.
    private func publish(_ session: ReplaySessionState, _ generation: UInt64) {
        stateLock.lock()
        guard !stopped, generation >= publishedGeneration else {
            stateLock.unlock()
            return
        }
        publishedGeneration = generation
        stateLock.unlock()
        var posting = (session: session, generation: generation)
        while true {
            cohorly?.publishReplaySession(posting.session.id)
            let latest = sessions.snapshot
            if latest.generation == posting.generation { return }
            stateLock.lock()
            if stopped {
                stateLock.unlock()
                return
            }
            publishedGeneration = max(publishedGeneration, latest.generation)
            stateLock.unlock()
            posting = latest
        }
    }
}
