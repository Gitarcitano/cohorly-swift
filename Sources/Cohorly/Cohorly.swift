import Foundation

/// Cohorly - local, Mixpanel-style product analytics.
///
/// Thread-safe: all mutable state is confined to a private serial
/// `DispatchQueue`. Events are queued in memory and persisted to `storage`
/// so they survive a relaunch, then flushed either every `flushInterval`
/// seconds or once `flushAt` events have accumulated, whichever comes first.
public final class Cohorly: @unchecked Sendable {
    private enum Keys {
        static let distinctId = "cohorly.distinct_id"
        static let deviceId = "cohorly.device_id"
        static let anonymous = "cohorly.anonymous"
        static let superProperties = "cohorly.super_properties"
        static let eventQueue = "cohorly.event_queue"
        static let engageQueue = "cohorly.engage_queue"
        /// Feature-flag cache (mirrors sdk-core's `chl_flags`), scoped by
        /// distinct id so one user's flags are never served to another.
        static let flags = "cohorly.flags"
        /// "1" while the app opted out of tracking (sdk-core `cohorly_opt_out`).
        static let optOut = "cohorly.opt_out"
    }

    /// Shared instance, set by `initialize(apiHost:)`. `nil` until then.
    /// `nonisolated(unsafe)`: the class is `@unchecked Sendable` and serializes
    /// its own state, so Swift 6 consumers can access the singleton directly.
    public private(set) static nonisolated(unsafe) var shared: Cohorly?

    /// Cohorly's hosted ingestion API, used when no `apiHost` is supplied.
    public static let defaultAPIHost = "https://cohorly-service.velloalabs.com"

    /// Posted (object: the instance) after init, `identify()` and `reset()`
    /// with the new identity in `userInfo` under `IdentityKey`. Delivered
    /// synchronously on the SDK's queue: read the values from `userInfo`, never
    /// call back into the instance from the observer. Used by `CohorlyCrash`
    /// to keep crash-time identity current.
    public static let identityDidChangeNotification = Notification.Name("CohorlyIdentityDidChange")

    /// `userInfo` keys of `identityDidChangeNotification`. `userId` is present
    /// only for an identified user.
    public enum IdentityKey {
        public static let distinctId = "distinct_id"
        public static let deviceId = "device_id"
        public static let userId = "user_id"
    }

    /// Posted (object: the instance) by `CohorlyReplay` every time a replay
    /// session starts, the first one included, with the new id in `userInfo`
    /// under `ReplaySessionKey.sessionId`. Delivered synchronously on the
    /// posting thread: read the value, never call back into the instance.
    /// `CohorlyCrash` follows it so a crash carries the `$session_id` of the
    /// session it happened in.
    public static let replaySessionDidChangeNotification = Notification.Name("CohorlyReplaySessionDidChange")

    /// `userInfo` keys of `replaySessionDidChangeNotification`.
    public enum ReplaySessionKey {
        public static let sessionId = "session_id"
    }

    /// Posted (object: the instance) on the SDK queue when `reset()` runs,
    /// before any later `track()` is built and before the identity
    /// notification, with the new anonymous id under
    /// `IdentityKey.distinctId`. `CohorlyReplay` rotates its session on it.
    @_spi(CohorlyReplay)
    public static let didResetNotification = Notification.Name("CohorlyDidReset")

    /// Posted (object: the instance) on the SDK queue by `optOutTracking()`
    /// and `optInTracking()`, with the new state under `optedOutKey` (Bool).
    @_spi(CohorlyReplay)
    public static let trackingOptOutDidChangeNotification = Notification.Name("CohorlyTrackingOptOutDidChange")

    @_spi(CohorlyReplay)
    public static let optedOutKey = "opted_out"

    /// Default flag-cache TTL: 24 hours, the Mixpanel reference default for
    /// flag persistence. Shared with the sibling SDKs so a cache means the
    /// same thing everywhere.
    public static let defaultFlagCacheTTL: TimeInterval = 24 * 60 * 60

    /// Hard staleness bound for the persisted flag cache under
    /// `persistenceUntilNetworkSuccess`: 7 days. That policy trades
    /// freshness for offline availability, so a cache past `flagCacheTTL` is
    /// still served while it is within this window - the served window is
    /// the wider of the configured TTL and 7 days.
    public static let flagCacheMaxStale: TimeInterval = 7 * 24 * 60 * 60

    /// Creates and stores the shared instance. Call once near app launch.
    @discardableResult
    public static func initialize(
        apiHost: String = Cohorly.defaultAPIHost,
        token: String? = nil,
        transport: CohorlyTransport = URLSessionTransport(),
        storage: CohorlyStorage = UserDefaultsStorage(),
        flushInterval: TimeInterval = 5,
        flushAt: Int = 20,
        maxQueueSize: Int = 1000,
        maxRetryDelay: TimeInterval = 600,
        trackAutomaticEvents: Bool = false,
        trackScreenViews: Bool = false,
        clock: CohorlyClock = SystemClock(),
        flagsFetcher: CohorlyFlagsFetcher = URLSessionFlagsFetcher(),
        loadFeatureFlags: Bool = true,
        sendExposureEvents: Bool = true,
        flagPersistence: FlagPersistenceMode = .persistenceUntilNetworkSuccess,
        flagCacheTTL: TimeInterval = Cohorly.defaultFlagCacheTTL
    ) -> Cohorly {
        let instance = Cohorly(
            apiHost: apiHost,
            token: token,
            transport: transport,
            storage: storage,
            flushInterval: flushInterval,
            flushAt: flushAt,
            maxQueueSize: maxQueueSize,
            maxRetryDelay: maxRetryDelay,
            trackAutomaticEvents: trackAutomaticEvents,
            trackScreenViews: trackScreenViews,
            clock: clock,
            flagsFetcher: flagsFetcher,
            loadFeatureFlags: loadFeatureFlags,
            sendExposureEvents: sendExposureEvents,
            flagPersistence: flagPersistence,
            flagCacheTTL: flagCacheTTL
        )
        shared = instance
        return instance
    }

    private let apiHost: String
    /// Project token. When set, stamped as `properties.token` on every
    /// tracked event and included as a top-level `token` field on every
    /// engage payload, so the server can resolve data to a project.
    private let token: String?
    private let transport: CohorlyTransport
    private let storage: CohorlyStorage
    private let flushInterval: TimeInterval
    private let flushAt: Int
    /// Max events retained in the persisted queue (drop oldest on overflow).
    private let maxQueueSize: Int
    /// Upper bound on the retry backoff, in seconds.
    private let maxRetryDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.cohorly.sdk")
    /// Serial delivery point for `onFeatureFlags` callbacks: emissions are
    /// enqueued from inside `queue` where the flag state is committed, so
    /// delivery order always matches commit order (an identity-clear `[:]`
    /// can never land after a reload that already repopulated the set).
    private let flagNotifyQueue = DispatchQueue(label: "com.cohorly.sdk.flags")
    private var timer: DispatchSourceTimer?

    private let backoff: CohorlyBackoff

    /// Persisted opt-out flag; see `optOutTracking()`.
    private var optedOut = false
    /// Bumped by `optOutTracking()`: a flush that started before it neither
    /// re-queues its batch nor starts a backoff when it comes back.
    private var optOutEpoch: UInt64 = 0

    /// Replay hooks (`@_spi(CohorlyReplay)`). Behind their own lock, not
    /// `queue`, so `CohorlyReplay` can install them from any thread and
    /// `track()` reads them on `queue` without a nested `queue.sync`.
    private let replayHooksLock = NSLock()
    private var sessionIdProvider: (@Sendable (String) -> String?)?
    private var trackedEventObservers: [UInt64: @Sendable (String, Properties) -> Void] = [:]
    private var trackedEventObserverSeq: UInt64 = 0
    private var replaySessionId: String?

    private var distinctId: String
    /// Stable per-device id stamped as `$device_id` on every event. Persisted
    /// separately so it survives `identify()`. On a fresh install it equals the
    /// anonymous distinct id (Mixpanel's `$device:<uuid>` convention); an
    /// identified install migrating in mints a fresh UUID.
    private var deviceId: String
    /// True until `identify()` is called (reset back to true by `reset()`).
    /// Gates `$user_id` stamping, which happens only for identified users.
    private var anonymous: Bool
    private var superProperties: Properties = [:]
    private var eventQueue: [TrackEvent] = []
    private var engageQueue: [EngagePayload] = []
    private var isFlushing = false
    private var pendingFlushCompletions: [() -> Void] = []
    /// Epoch of the queued data, bumped by `reset()`. A flush captures the
    /// current value; when its request comes back with a different value the
    /// batch belongs to an identity the app asked to forget, so it is dropped
    /// instead of being re-queued and re-persisted.
    private var flushGeneration: UInt64 = 0

    /// In-memory start instants for timed events, keyed by event name. The next
    /// `track` of a keyed event attaches `$duration` (seconds) and clears it.
    /// Not persisted - timers reset on relaunch, matching Mixpanel.
    private var timedEvents: [String: Date] = [:]

    /// Consecutive flush failures, drives exponential backoff. Reset on success.
    private var consecutiveFailures = 0
    /// Instant before which non-forced flushes are skipped. `nil` when clear.
    private var backoffUntil: Date?
    /// Current effective per-flush batch size; halved on 413 (floor 1).
    private var effectiveBatchSize: Int

    /// Time source, injected for deterministic tests. Used by automatic events.
    private let clock: CohorlyClock

    // MARK: - Feature flags

    private let flagsFetcher: CohorlyFlagsFetcher
    /// Last known flag results for the current distinct id.
    private var flags: [String: FlagResult] = [:]
    /// True once flags were loaded, from the persisted cache or a reload.
    private var flagsLoaded = false
    /// Bumped per reload; a response carrying an older value is stale.
    private var flagRequestSeq: UInt64 = 0
    /// Bumped per subscription, keys `flagListeners` for unsubscribe.
    private var flagListenerSeq: UInt64 = 0
    private var flagListeners: [UInt64: @Sendable ([String: FlagResult]) -> Void] = [:]
    /// Emit `$feature_flag_called` the first time each flag value is read.
    private let sendExposureEvents: Bool
    /// `"<key>:<value>"` pairs already reported for the current identity.
    /// In-memory only (never persisted) and cleared by `identify()`/`reset()`,
    /// so a new identity re-reports its exposures exactly once.
    private var reportedExposures: Set<String> = []
    /// How flag reads resolve values against the persisted cache.
    private let flagPersistence: FlagPersistenceMode
    /// Max age of the persisted flag cache, in seconds (see
    /// `defaultFlagCacheTTL`). How a cache older than this is treated depends
    /// on `flagPersistence` (see `isFlagCacheUsable`): `networkFirst` is
    /// strict, `persistenceUntilNetworkSuccess` still serves it inside
    /// `flagCacheMaxStale`, and a legacy cache with no `stored_at` is served
    /// indefinitely.
    private let flagCacheTTL: TimeInterval
    /// Where the currently served flag set came from (`nil` until flags load).
    /// One source covers the whole map because the set is swapped atomically:
    /// a cache load or a network success replaces it wholesale, never per key.
    private var flagSource: FlagSource?
    /// Epoch ms the served flag set was persisted; non-nil only while
    /// `flagSource == .persistence`.
    private var flagPersistedAt: Int?
    /// Drives `$ae_*` lifecycle events; non-nil only when `trackAutomaticEvents`.
    private var automaticEvents: AutomaticEvents?
    /// Drives automatic `$screen` events; non-nil only when `trackScreenViews`.
    /// Internal so tests can tell the option is off.
    private(set) var screenViewTracker: ScreenViewTracker?

    /// Creates a standalone instance. Prefer `initialize(apiHost:)` for the
    /// shared singleton; this initializer is public mainly so tests (and
    /// advanced callers who want multiple instances) can inject a mock
    /// transport/storage directly.
    public init(
        apiHost: String = Cohorly.defaultAPIHost,
        token: String? = nil,
        transport: CohorlyTransport = URLSessionTransport(),
        storage: CohorlyStorage = UserDefaultsStorage(),
        flushInterval: TimeInterval = 5,
        flushAt: Int = 20,
        maxQueueSize: Int = 1000,
        maxRetryDelay: TimeInterval = 600,
        trackAutomaticEvents: Bool = false,
        trackScreenViews: Bool = false,
        clock: CohorlyClock = SystemClock(),
        flagsFetcher: CohorlyFlagsFetcher = URLSessionFlagsFetcher(),
        loadFeatureFlags: Bool = true,
        sendExposureEvents: Bool = true,
        flagPersistence: FlagPersistenceMode = .persistenceUntilNetworkSuccess,
        flagCacheTTL: TimeInterval = Cohorly.defaultFlagCacheTTL
    ) {
        self.flagsFetcher = flagsFetcher
        self.sendExposureEvents = sendExposureEvents
        self.flagPersistence = flagPersistence
        self.flagCacheTTL = flagCacheTTL
        self.apiHost = apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost
        self.token = token
        self.transport = transport
        self.storage = storage
        self.flushInterval = flushInterval
        self.flushAt = flushAt
        self.maxQueueSize = maxQueueSize
        self.maxRetryDelay = maxRetryDelay
        self.backoff = CohorlyBackoff(maxDelay: maxRetryDelay)
        self.effectiveBatchSize = flushAt
        self.clock = clock

        if let storedId = storage.string(forKey: Keys.distinctId) {
            self.distinctId = storedId
            // Installs predating the anonymous flag have no stored value; treat
            // them as anonymous rather than stamping a possibly-false $user_id.
            // Identified users self-heal on their next identify() call.
            self.anonymous = storage.string(forKey: Keys.anonymous) != "0"
        } else {
            let newId = UUID().uuidString
            self.distinctId = newId
            self.anonymous = true
            storage.setString(newId, forKey: Keys.distinctId)
            storage.setString("1", forKey: Keys.anonymous)
        }

        // Device id: persisted separately so it survives identify(). A fresh
        // or migrating anonymous install reuses the anon distinct id; an
        // identified install (anonymous flag "0") mints a fresh one.
        if let storedDevice = storage.string(forKey: Keys.deviceId) {
            self.deviceId = storedDevice
        } else {
            let newDevice = self.anonymous ? self.distinctId : UUID().uuidString
            self.deviceId = newDevice
            storage.setString(newDevice, forKey: Keys.deviceId)
        }

        if let raw = storage.string(forKey: Keys.superProperties),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Properties.self, from: data) {
            self.superProperties = decoded
        }
        if let raw = storage.string(forKey: Keys.eventQueue),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([TrackEvent].self, from: data) {
            self.eventQueue = decoded
            // Enforce the persisted cap on load in case a larger queue was stored.
            if enforceEventQueueCap() { persistEventQueue() }
        }
        if let raw = storage.string(forKey: Keys.engageQueue),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([EngagePayload].self, from: data) {
            self.engageQueue = decoded
        }
        self.optedOut = storage.string(forKey: Keys.optOut) == "1"
        if optedOut {
            // Whatever a previous launch left queued is never sent.
            eventQueue = []
            engageQueue = []
            persistEventQueue()
            persistEngageQueue()
        }

        // Feature-flag cache, per `flagPersistence`: the persistent modes
        // adopt a valid cache immediately (synchronous reads cannot await the
        // network the way Mixpanel's async lookups do, so `networkFirst`
        // serves identically to `persistenceUntilNetworkSuccess` - see the
        // enum doc); `networkOnly` never reads nor writes the key on the
        // serving path (identify()/reset() still remove it - that is identity
        // hygiene, not flag serving). Safe to run before `queue` exists -
        // the instance is not shared yet.
        if flagPersistence != .networkOnly {
            loadPersistedFlagsLocked()
        }

        startTimer()

        // First flag evaluation for the persisted identity (parity with
        // sdk-web / sdk-react-native). Fire and forget - reloadFeatureFlags()
        // never throws, and a failure keeps the cache loaded above.
        if loadFeatureFlags {
            Task { await self.reloadFeatureFlags() }
        }

        if trackAutomaticEvents {
            let newAutomaticEvents = AutomaticEvents(client: self, storage: storage, clock: clock)
            self.automaticEvents = newAutomaticEvents
            newAutomaticEvents.start(currentVersion: DeviceInfo.appVersion)
        }

        if trackScreenViews {
            let tracker = ScreenViewTracker(client: self)
            self.screenViewTracker = tracker
            ScreenViewSwizzle.register(tracker)
        }

        postIdentityChange()
    }

    /// Posts `identityDidChangeNotification`. Called from init or on `queue`.
    private func postIdentityChange() {
        var userInfo: [String: String] = [
            IdentityKey.distinctId: distinctId,
            IdentityKey.deviceId: deviceId
        ]
        if !anonymous { userInfo[IdentityKey.userId] = distinctId }
        NotificationCenter.default.post(name: Cohorly.identityDidChangeNotification, object: self, userInfo: userInfo)
    }

    deinit {
        // Close the final session on platforms without background notifications.
        // Pass self explicitly: weak refs to this instance already read nil here.
        automaticEvents?.appWillTerminate(via: self)
        timer?.cancel()
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        source.setEventHandler { [weak self] in
            // Already running on `queue` (the timer was created with
            // `queue:` above), so call the internal flush directly.
            self?.performFlush()
        }
        source.resume()
        timer = source
    }

    // MARK: - Persistence helpers (must be called on `queue`)

    private func persistEventQueue() {
        guard let data = try? JSONEncoder().encode(eventQueue),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        storage.setString(raw, forKey: Keys.eventQueue)
    }

    private func persistEngageQueue() {
        guard let data = try? JSONEncoder().encode(engageQueue),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        storage.setString(raw, forKey: Keys.engageQueue)
    }

    private func persistSuperProperties() {
        guard let data = try? JSONEncoder().encode(superProperties),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        storage.setString(raw, forKey: Keys.superProperties)
    }

    // MARK: - Public API

    public var currentDistinctId: String {
        queue.sync { distinctId }
    }

    /// Stable per-device id stamped as `$device_id` on every event. Survives
    /// `identify()`; regenerated by `reset()`.
    public var currentDeviceId: String {
        queue.sync { deviceId }
    }

    /// The identified user's id (`$user_id`), nil while anonymous.
    public var currentUserId: String? {
        queue.sync { anonymous ? nil : distinctId }
    }

    /// The ingestion API base URL this instance sends to.
    public var configuredAPIHost: String { apiHost }

    /// The project token passed to init, if any.
    public var configuredToken: String? { token }

    // MARK: - Opt-out

    /// Stops collecting for this device. Persisted (survives a relaunch);
    /// drops every queued event and profile update, and until
    /// `optInTracking()` no `track`, `people` or `/alias` call is queued or
    /// sent and no flags are requested. `CohorlyReplay` stops too and deletes
    /// its queued chunks.
    public func optOutTracking() {
        // The flag is written before returning so a relaunch right after
        // never misses it; the queues are dropped in order with `track`.
        storage.setString("1", forKey: Keys.optOut)
        queue.async {
            self.optedOut = true
            self.optOutEpoch &+= 1
            self.eventQueue = []
            self.engageQueue = []
            self.persistEventQueue()
            self.persistEngageQueue()
            self.postOptOutChange()
        }
    }

    /// Resumes collecting after `optOutTracking()`. What was discarded is not
    /// restored.
    public func optInTracking() {
        storage.setString(nil, forKey: Keys.optOut)
        queue.async {
            guard self.optedOut else { return }
            self.optedOut = false
            self.postOptOutChange()
        }
    }

    /// Whether the app opted out (the persisted flag).
    public func hasOptedOutTracking() -> Bool {
        queue.sync { optedOut }
    }

    private func postOptOutChange() {
        NotificationCenter.default.post(
            name: Cohorly.trackingOptOutDidChangeNotification,
            object: self,
            userInfo: [Cohorly.optedOutKey: optedOut])
    }

    // MARK: - Replay hooks

    /// `$lib_version` of this SDK.
    @_spi(CohorlyReplay)
    public static var sdkVersion: String { DeviceInfo.libVersion }

    @_spi(CohorlyReplay)
    public var configuredStorage: CohorlyStorage { storage }

    @_spi(CohorlyReplay)
    public var configuredClock: CohorlyClock { clock }

    @_spi(CohorlyReplay)
    public var configuredMaxRetryDelay: TimeInterval { maxRetryDelay }

    /// Called on the SDK queue for every `track()` (event name in), after the
    /// caller's properties, even when the caller set `$session_id`: its id is
    /// stamped as `$session_id` unless the caller set one. It must not call back into the instance synchronously
    /// nor `sync` onto a queue that may wait on this one. `nil` removes it.
    @_spi(CohorlyReplay)
    public func setSessionIdProvider(_ provider: (@Sendable (String) -> String?)?) {
        replayHooksLock.lock()
        sessionIdProvider = provider
        replayHooksLock.unlock()
    }

    /// Called on the SDK queue with the name and final properties of every
    /// event `track()` queues (`$exception` included), right after it is
    /// queued. Same re-entrancy rule as `setSessionIdProvider`. Returns a
    /// closure that removes it.
    @_spi(CohorlyReplay)
    @discardableResult
    public func addTrackedEventObserver(
        _ observer: @escaping @Sendable (String, Properties) -> Void
    ) -> @Sendable () -> Void {
        replayHooksLock.lock()
        trackedEventObserverSeq &+= 1
        let id = trackedEventObserverSeq
        trackedEventObservers[id] = observer
        replayHooksLock.unlock()
        // Removal is ordered with `track` on the SDK queue: an event tracked
        // before the call still reaches the observer.
        return { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.replayHooksLock.lock()
                self.trackedEventObservers.removeValue(forKey: id)
                self.replayHooksLock.unlock()
            }
        }
    }

    /// Records the live replay session and posts
    /// `replaySessionDidChangeNotification` on the calling thread. `nil`
    /// (replay uninstalled or replaced) clears it: the notification then has
    /// no `ReplaySessionKey.sessionId`.
    @_spi(CohorlyReplay)
    public func publishReplaySession(_ sessionId: String?) {
        replayHooksLock.lock()
        replaySessionId = sessionId
        replayHooksLock.unlock()
        var userInfo: [String: String] = [:]
        if let sessionId { userInfo[ReplaySessionKey.sessionId] = sessionId }
        NotificationCenter.default.post(
            name: Cohorly.replaySessionDidChangeNotification,
            object: self,
            userInfo: userInfo)
    }

    /// The last session `publishReplaySession` recorded, nil without replay.
    @_spi(CohorlyReplay)
    public var currentReplaySessionId: String? {
        replayHooksLock.lock()
        defer { replayHooksLock.unlock() }
        return replaySessionId
    }

    private func replayHooks() -> ((@Sendable (String) -> String?)?, [@Sendable (String, Properties) -> Void]) {
        replayHooksLock.lock()
        defer { replayHooksLock.unlock() }
        return (sessionIdProvider, Array(trackedEventObservers.values))
    }

    public func register(_ properties: [String: Any]) {
        queue.async {
            for (key, value) in properties {
                self.superProperties[key] = JSONValue(any: value)
            }
            self.persistSuperProperties()
        }
    }

    public func unregister(_ key: String) {
        queue.async {
            self.superProperties.removeValue(forKey: key)
            self.persistSuperProperties()
        }
    }

    /// Starts a timer for `event`. The next `track(event)` attaches a
    /// `$duration` property (seconds elapsed, rounded to 3 decimals) and clears
    /// the timer. Starting again before tracking resets the start instant.
    public func timeEvent(_ event: String) {
        let now = clock.now()
        queue.async { self.timedEvents[event] = now }
    }

    /// Cancels the timer for `event` without tracking it.
    public func clearTimedEvent(_ event: String) {
        queue.async { self.timedEvents.removeValue(forKey: event) }
    }

    /// Cancels all pending event timers.
    public func clearTimedEvents() {
        queue.async { self.timedEvents.removeAll() }
    }

    public func track(_ event: String, properties: [String: Any]? = nil) {
        queue.async {
            if self.optedOut {
                self.timedEvents.removeValue(forKey: event)
                return
            }
            var merged = self.superProperties
            for (key, value) in DeviceInfo.autoProperties() {
                merged[key] = value
            }
            if let properties {
                for (key, value) in properties {
                    merged[key] = JSONValue(any: value)
                }
            }
            merged["distinct_id"] = .string(self.distinctId)
            merged["time"] = .int(Int(Date().timeIntervalSince1970 * 1000))
            merged["$insert_id"] = .string(UUID().uuidString)
            if let start = self.timedEvents.removeValue(forKey: event) {
                let duration = self.clock.now().timeIntervalSince(start)
                merged["$duration"] = .double((duration * 1000).rounded() / 1000)
            }
            if let token = self.token {
                merged["token"] = .string(token)
            }
            // Reserved identity fields, stamped last but never overriding a
            // value the caller passed explicitly (mirrors Mixpanel's
            // $device_id/$user_id). $device_id is always present; $user_id only
            // once the user is identified.
            if merged["$device_id"] == nil {
                merged["$device_id"] = .string(self.deviceId)
            }
            if !self.anonymous, merged["$user_id"] == nil {
                merged["$user_id"] = .string(self.distinctId)
            }
            let (provider, observers) = self.replayHooks()
            // The provider is asked even when the caller set `$session_id`:
            // the call is what counts the activity (and may rotate). The
            // caller's value wins on the event.
            if let sessionId = provider?(event), merged["$session_id"] == nil {
                merged["$session_id"] = .string(sessionId)
            }

            self.eventQueue.append(TrackEvent(event: event, properties: merged))
            _ = self.enforceEventQueueCap()
            self.persistEventQueue()
            for observer in observers { observer(event, merged) }

            if self.eventQueue.count >= self.flushAt {
                self.performFlush()
            }
        }
    }

    /// Switches the current user's identity to `distinctId`.
    ///
    /// No-op when `distinctId` already is the current id. The switch itself
    /// (distinct id, anonymous flag, persistence) is applied synchronously on
    /// the client queue, exactly as before.
    ///
    /// If - and only if - the previous id was still anonymous, this also
    /// links it to the new id by POSTing `/alias { alias: <previous id>,
    /// distinct_id: <new id>, token? }`, so the server can retroactively fold
    /// pre-login history into the same person. An id that has already been
    /// identified is never re-aliased. The POST is fired off the serial queue
    /// (see `sendAlias`) so a slow or offline request can never delay the
    /// identity switch or any `track()` issued right after it.
    public func identify(_ distinctId: String) {
        queue.async {
            guard distinctId != self.distinctId else { return }

            let previousId = self.distinctId
            let wasAnonymous = self.anonymous

            self.distinctId = distinctId
            self.anonymous = false
            self.storage.setString(distinctId, forKey: Keys.distinctId)
            self.storage.setString("0", forKey: Keys.anonymous)
            self.postIdentityChange()
            // Exposures are per-identity: the new user must report its own.
            self.reportedExposures.removeAll()

            // Flags are per-identity: drop the previous identity's values
            // (memory and disk) BEFORE asking the server for this id's flags,
            // so they can never be served to the new identity - including
            // under `networkOnly`, where the in-memory set is all there is.
            // The persisted entry is removed under every policy: identity
            // hygiene, not flag serving. The seq bump also marks any
            // in-flight reload as stale.
            self.flags = [:]
            self.flagsLoaded = false
            self.flagSource = nil
            self.flagPersistedAt = nil
            self.flagRequestSeq &+= 1
            self.storage.setString(nil, forKey: Keys.flags)
            // The served set changed to empty: notify listeners via the
            // serial delivery queue (a listener may re-read flags, which
            // would deadlock a nested queue.sync). Enqueued here, still on
            // `queue`, its delivery is ordered before any emission a later
            // commit produces - a stale `[:]` can never land on top of flags
            // a concurrent reload already adopted.
            let flagListeners = Array(self.flagListeners.values)
            self.flagNotifyQueue.async {
                for listener in flagListeners { listener([:]) }
            }
            Task { await self.reloadFeatureFlags() }

            guard wasAnonymous, !self.optedOut else { return }
            self.sendAlias(AliasPayload(alias: previousId, distinctId: distinctId, token: self.token))
        }
    }

    /// POSTs an `/alias` payload built by `identify()`, off the serial queue.
    /// Best effort: a failure is neither retried nor surfaced to the caller -
    /// the server also links `$device_id`/`$user_id` implicitly from the next
    /// event either id emits, so a dropped alias call only delays the link
    /// rather than losing it (mirrors sdk-core and the Android SDK).
    private func sendAlias(_ payload: AliasPayload) {
        guard let body = try? JSONEncoder().encode(payload) else { return }
        let apiHost = self.apiHost
        let transport = self.transport
        Task {
            do {
                try await transport.post(apiHost: apiHost, path: "/alias", body: body)
            } catch {
                // Best effort, like sdk-core and Android: an alias failure is
                // not retried.
            }
        }
    }

    /// Clears identity, super properties, pending timers, and any un-flushed
    /// events, then assigns a fresh anonymous distinct id. The device id is
    /// reset to that fresh anon distinct id (Mixpanel parity).
    ///
    /// Data already handed to an in-flight flush is discarded too: bumping the
    /// generation makes that flush drop its batch on failure instead of
    /// splicing the forgotten user's events/profile updates back into the
    /// queue and back onto disk.
    public func reset() {
        queue.async {
            self.flushGeneration &+= 1
            self.distinctId = UUID().uuidString
            self.deviceId = self.distinctId
            self.anonymous = true
            self.superProperties = [:]
            self.eventQueue = []
            self.engageQueue = []
            self.timedEvents.removeAll()
            self.storage.setString(self.distinctId, forKey: Keys.distinctId)
            self.storage.setString(self.deviceId, forKey: Keys.deviceId)
            self.storage.setString("1", forKey: Keys.anonymous)
            NotificationCenter.default.post(
                name: Cohorly.didResetNotification, object: self,
                userInfo: [IdentityKey.distinctId: self.distinctId])
            self.postIdentityChange()
            self.persistSuperProperties()
            self.persistEventQueue()
            self.persistEngageQueue()
            // Flags are per-identity: the previous identity's flags must never
            // be served to the fresh anonymous id, so drop them (memory and
            // disk, under every policy - identity hygiene) BEFORE asking the
            // server for this id's flags.
            self.flags = [:]
            self.flagsLoaded = false
            self.flagSource = nil
            self.flagPersistedAt = nil
            self.flagRequestSeq &+= 1
            self.reportedExposures.removeAll()
            self.storage.setString(nil, forKey: Keys.flags)
            // The served set changed to empty: notify listeners via the
            // serial delivery queue (a listener may re-read flags, which
            // would deadlock a nested queue.sync). Enqueued here, still on
            // `queue`, its delivery is ordered before any emission a later
            // commit produces - a stale `[:]` can never land on top of flags
            // a concurrent reload already adopted.
            let flagListeners = Array(self.flagListeners.values)
            self.flagNotifyQueue.async {
                for listener in flagListeners { listener([:]) }
            }
            Task { await self.reloadFeatureFlags() }
        }
    }

    // MARK: - Feature flags

    /// Re-evaluates feature flags for the current distinct id via
    /// `POST /flags/evaluate`, caching the result in memory and in `storage`
    /// (scoped by distinct id).
    ///
    /// Never throws and never clears the served flags on failure: a network
    /// error, a non-2xx response or an unparseable body re-adopts the
    /// persisted cache under the persistent `flagPersistence` modes (a
    /// safety net - it was already adopted at init), and leaves whatever the
    /// network previously served under `networkOnly`. Results are discarded
    /// when the identity changed, or a newer reload started, while the
    /// request was in flight.
    public func reloadFeatureFlags() async {
        let request = queue.sync { () -> (String, UInt64)? in
            // Opted out: no request at all (it would carry the distinct id).
            // Whatever is cached stays served.
            guard !optedOut else { return nil }
            flagRequestSeq &+= 1
            return (distinctId, flagRequestSeq)
        }
        guard let request else { return }
        let (requestedId, seq) = request
        guard
            let body = try? JSONEncoder().encode(
                FlagsRequest(distinctId: requestedId, token: token)),
            let data = await flagsFetcher.fetchFlags(
                apiHost: apiHost, path: "/flags/evaluate", body: body),
            let decoded = try? JSONDecoder().decode(FlagsResponse.self, from: data)
        else {
            // Evaluation failed: re-adopt the persisted cache under the
            // persistent policies. Both persistent modes already adopted it
            // at init, so this is normally an idempotent safety net (it also
            // covers a cache written between init and now by another path).
            // Once a network response has landed this session
            // (`flagSource == .network`) its values are fresher than any cache
            // the last success wrote, so they win and the cache is not
            // re-read. `networkOnly` never touches it. Silent, like the
            // sibling SDKs: a failed reload notifies nobody.
            queue.sync {
                guard flagPersistence != .networkOnly, flagSource != .network else { return }
                loadPersistedFlagsLocked()
            }
            return
        }

        queue.sync {
            guard requestedId == distinctId, seq == flagRequestSeq else { return }
            flags = decoded.flags
            flagsLoaded = true
            flagSource = .network
            flagPersistedAt = nil
            if flagPersistence != .networkOnly { persistFlags() }
            // Delivered on the serial notify queue, enqueued here while the
            // state is being committed, so listeners observe emissions in
            // commit order.
            let listeners = Array(flagListeners.values)
            let adopted = decoded.flags
            flagNotifyQueue.async {
                for listener in listeners { listener(adopted) }
            }
        }
    }

    /// The flag's variant when it has one, else its enabled boolean. `.bool(false)`
    /// for an unknown flag or before flags have loaded.
    ///
    /// Reading a *known* flag also emits `$feature_flag_called` once per
    /// distinct value, per identity (see `recordExposure`).
    public func getFeatureFlag(_ key: String) -> JSONValue {
        getFeatureFlag(key, fallback: false)
    }

    /// The flag's value, or `fallback` when the flag is unknown or unloaded.
    ///
    /// A read that resolves to `fallback` is not an exposure: nothing was
    /// assigned, so no `$feature_flag_called` is emitted (Mixpanel parity -
    /// fallback variants never fire the exposure event).
    public func getFeatureFlag(_ key: String, fallback: Bool) -> JSONValue {
        getFeatureFlagDetails(key, fallback: fallback).value
    }

    /// The flag's value, or `fallback` when the flag is unknown or unloaded.
    /// Same exposure terms as the `Bool` overload; the two overloads mirror
    /// the shared contract's `boolean | string` fallback type.
    public func getFeatureFlag(_ key: String, fallback: String) -> JSONValue {
        getFeatureFlagDetails(key, fallback: fallback).value
    }

    /// Whether `key` is enabled. `false` for an unknown or unloaded flag.
    ///
    /// Emits `$feature_flag_called` on the same terms as `getFeatureFlag`.
    public func isFeatureEnabled(_ key: String) -> Bool {
        isFeatureEnabled(key, fallback: false)
    }

    /// Whether `key` is enabled, or `fallback` when the flag is unknown or
    /// unloaded. A read that resolves to `fallback` emits no exposure.
    public func isFeatureEnabled(_ key: String, fallback: Bool) -> Bool {
        let (enabled, exposure) = queue.sync {
            () -> (Bool, FlagExposure?) in
            guard let flag = flags[key] else { return (fallback, nil) }
            return (flag.enabled, recordExposure(key: key, flag: flag))
        }
        trackExposure(key: key, exposure: exposure)
        return enabled
    }

    /// The full lookup result for `key`: the value plus `enabled`, `payload`
    /// and where it came from (`FlagDetails.source` is `.network`,
    /// `.persistence` or `.fallback`, with `persistedAt`/`ttlMs` populated for
    /// persistence-served values). A fallback result reports `enabled` = the
    /// fallback's truthiness and `payload` = `nil`.
    ///
    /// Emits `$feature_flag_called` on the same terms as `getFeatureFlag`:
    /// only a read of a *known* flag counts, so a result sourced from
    /// `fallback` never reports an exposure.
    public func getFeatureFlagDetails(_ key: String, fallback: Bool = false) -> FlagDetails {
        getFeatureFlagDetails(key, jsonFallback: .bool(fallback))
    }

    /// The full lookup result with a `String` fallback: same contract as the
    /// `Bool` overload (the two mirror the shared SDKs' `boolean | string`
    /// fallback type).
    public func getFeatureFlagDetails(_ key: String, fallback: String) -> FlagDetails {
        getFeatureFlagDetails(key, jsonFallback: .string(fallback))
    }

    /// Shared implementation for the `getFeatureFlagDetails` overloads. A
    /// fallback result carries `enabled` = the fallback's truthiness
    /// (`true`, or a non-empty string) and a `nil` payload, mirroring the
    /// sibling SDKs' `Boolean(fallback)` / `payload: null`.
    private func getFeatureFlagDetails(_ key: String, jsonFallback: JSONValue) -> FlagDetails {
        let (details, exposure) = queue.sync {
            () -> (FlagDetails, FlagExposure?) in
            guard let flag = flags[key] else {
                return (
                    FlagDetails(
                        key: key,
                        value: jsonFallback,
                        enabled: jsonFallback.truthy,
                        payload: nil,
                        source: .fallback),
                    nil
                )
            }
            let value: JSONValue = flag.variant.map { JSONValue.string($0) } ?? .bool(flag.enabled)
            let persisted = flagSource == .persistence
            let details = FlagDetails(
                key: key,
                value: value,
                enabled: flag.enabled,
                payload: flag.payload,
                source: flagSource ?? .network,
                persistedAt: persisted ? flagPersistedAt : nil,
                ttlMs: persisted ? Int(flagCacheTTL * 1000) : nil)
            return (details, recordExposure(key: key, flag: flag))
        }
        trackExposure(key: key, exposure: exposure)
        return details
    }

    /// The decision `recordExposure` hands to `trackExposure`: the response
    /// value plus where it came from (`persistedAt`/`ttlMs` set only for
    /// persistence-served values). A named type because SwiftLint caps
    /// tuples at two members.
    private struct FlagExposure {
        let response: Any
        let source: FlagSource
        let persistedAt: Int?
        let ttlMs: Int?
    }

    /// Marks `key` as exposed and returns the `$feature_flag_response` value
    /// plus the source to report, or `nil` when nothing should be tracked
    /// (exposure events off, or this key/value pair was already reported for
    /// the current identity). Dedupe keys on (key, value) only, so the same
    /// value served first from persistence and then from the network is
    /// reported exactly once.
    ///
    /// Must be called on `queue`.
    private func recordExposure(key: String, flag: FlagResult) -> FlagExposure? {
        guard sendExposureEvents else { return nil }
        let response: Any = flag.variant ?? flag.enabled
        let dedupeKey = "\(key):\(flag.variant ?? String(flag.enabled))"
        guard reportedExposures.insert(dedupeKey).inserted else { return nil }
        let persisted = flagSource == .persistence
        return FlagExposure(
            response: response,
            source: flagSource ?? .network,
            persistedAt: persisted ? flagPersistedAt : nil,
            ttlMs: persisted ? Int(flagCacheTTL * 1000) : nil
        )
    }

    /// Queues the exposure event. Called OFF `queue` (right after the
    /// `queue.sync` that decided it) because `track` hops onto `queue` itself -
    /// nesting the two would be a re-entrant `sync` and deadlock.
    ///
    /// `$feature_flag_source` is always stamped (`"network"` or
    /// `"persistence"`), matching Mixpanel's always-present `$variant_source`,
    /// so dashboards never have to guess whether a missing property means
    /// "network" or "old SDK". Persistence reads also carry
    /// `$feature_flag_persisted_at` (epoch ms) and `$feature_flag_ttl_ms`,
    /// matching the sibling SDKs' exposure payloads.
    private func trackExposure(
        key: String,
        exposure: FlagExposure?
    ) {
        guard let exposure else { return }
        var properties: [String: Any] = [
            "$feature_flag": key,
            "$feature_flag_response": exposure.response,
            "$feature_flag_source": exposure.source.rawValue
        ]
        if let persistedAt = exposure.persistedAt {
            properties["$feature_flag_persisted_at"] = persistedAt
        }
        if let ttlMs = exposure.ttlMs {
            properties["$feature_flag_ttl_ms"] = ttlMs
        }
        track("$feature_flag_called", properties: properties)
    }

    /// The JSON payload attached to `key`, or `nil` when it has none.
    public func getFeatureFlagPayload(_ key: String) -> JSONValue? {
        queue.sync { flags[key]?.payload }
    }

    /// Every flag currently known for the active distinct id.
    public func currentFeatureFlags() -> [String: FlagResult] {
        queue.sync { flags }
    }

    /// Whether a flag set is currently being served (a successful network
    /// evaluation or an adopted persisted cache). Goes back to false on
    /// `identify()`/`reset()` until the new identity's flags land -
    /// subscribers use it to keep serving "unloaded" instead of getter
    /// fallbacks while the next set is still loading.
    public func areFeatureFlagsLoaded() -> Bool {
        queue.sync { flagsLoaded }
    }

    /// Subscribes to flag updates. `listener` fires whenever the served set
    /// changes: after every successful reload, when `identify()`/`reset()`
    /// drop the previous identity's flags (with an empty map), and
    /// immediately at subscription when flags are already loaded - including
    /// a set adopted from the persisted cache at startup. A failed reload
    /// notifies nobody (the persisted cache is re-adopted silently, matching
    /// the sibling SDKs). Returns a closure that removes the subscription.
    @discardableResult
    public func onFeatureFlags(
        _ listener: @escaping @Sendable ([String: FlagResult]) -> Void
    ) -> @Sendable () -> Void {
        let (id, loadedFlags) = queue.sync { () -> (UInt64, [String: FlagResult]?) in
            flagListenerSeq &+= 1
            let id = flagListenerSeq
            flagListeners[id] = listener
            return (id, flagsLoaded ? flags : nil)
        }
        if let loadedFlags { listener(loadedFlags) }
        return { [weak self] in
            self?.queue.async { self?.flagListeners.removeValue(forKey: id) }
        }
    }

    /// Must be called on `queue`. Never called under `networkOnly`.
    private func persistFlags() {
        guard
            let data = try? JSONEncoder().encode(
                FlagsCache(
                    distinctId: distinctId,
                    flags: flags,
                    storedAt: Int(clock.now().timeIntervalSince1970 * 1000))),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        storage.setString(raw, forKey: Keys.flags)
    }

    /// Reads the persisted flag cache and installs it as the served set when
    /// it belongs to the current distinct id AND is usable under
    /// `flagPersistence` (see `isFlagCacheUsable`). Returns true when the
    /// cache was served.
    ///
    /// A foreign-identity, too-stale or unparseable entry is dropped from
    /// storage, never served. A legacy cache with no `stored_at` (written
    /// before the TTL existed) cannot be dated, so it is served indefinitely
    /// - the graceful-upgrade path preserving the pre-TTL behavior - until
    /// the next successful reload replaces it with the stamped format.
    /// Identity switches adopt nothing: the single-slot entry is removed by
    /// `identify()`/`reset()`, so it can only ever hold the outgoing
    /// identity's cache. Must be called on `queue` - or during `init`,
    /// before the instance is shared.
    @discardableResult
    private func loadPersistedFlagsLocked() -> Bool {
        guard
            let raw = storage.string(forKey: Keys.flags),
            let data = raw.data(using: .utf8),
            let cache = try? JSONDecoder().decode(FlagsCache.self, from: data),
            cache.distinctId == distinctId,
            isFlagCacheUsable(cache)
        else {
            storage.setString(nil, forKey: Keys.flags)
            return false
        }
        flags = cache.flags
        flagsLoaded = true
        flagSource = .persistence
        // nil for a legacy cache without `stored_at` (unprovable age):
        // persistedAt stays absent on FlagDetails and the exposure, while
        // ttlMs is still reported.
        flagPersistedAt = cache.storedAt
        // A future `stored_at` (clock moved backwards after the write)
        // would stay fresh on every adoption until real time catches up,
        // outliving the TTL bound. Normalize the stamp to now and rewrite
        // the entry so subsequent launches age it honestly.
        let nowMs = Int(clock.now().timeIntervalSince1970 * 1000)
        if let storedAt = cache.storedAt, storedAt > nowMs {
            flagPersistedAt = nowMs
            persistFlags()
        }
        return true
    }

    /// Whether a persisted cache may be served under `flagPersistence`.
    /// `networkFirst` is strict: only while `stored_at` is within
    /// `flagCacheTTL`. `persistenceUntilNetworkSuccess` trades freshness for
    /// offline availability and serves until the wider of `flagCacheTTL` and
    /// `flagCacheMaxStale` (inside the TTL always serves; expired still
    /// serves up to 7 days stale). A legacy cache without `stored_at` has no
    /// provable age: it is served indefinitely, matching the pre-TTL
    /// behavior it was written under.
    private func isFlagCacheUsable(_ cache: FlagsCache) -> Bool {
        guard let storedAtMs = cache.storedAt else { return true }
        // A future `stored_at` (clock moved backwards after the write)
        // yields a negative age that would bypass every bound below; clamp
        // it to fresh. The stamp itself is normalized to now on adoption
        // so later launches age it honestly instead of staying fresh until
        // the clock catches up.
        let ageMs = max(0, Int(clock.now().timeIntervalSince1970 * 1000) - storedAtMs)
        if flagPersistence == .networkFirst {
            return ageMs <= Int(flagCacheTTL * 1000)
        }
        return ageMs <= max(
            Int(flagCacheTTL * 1000), Int(Cohorly.flagCacheMaxStale * 1000))
    }

    public struct People {
        fileprivate weak var client: Cohorly?

        public func set(_ properties: [String: Any]) {
            let merged = Self.mergeDefaults(properties)
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, set: merged)
            }
        }

        public func setOnce(_ properties: [String: Any]) {
            let merged = Self.mergeDefaults(properties)
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, setOnce: merged)
            }
        }

        /// Merges the default iOS profile properties (Mixpanel parity) under the
        /// caller-supplied keys, so any explicit user value always wins.
        private static func mergeDefaults(_ properties: [String: Any]) -> Properties {
            var merged = DeviceInfo.defaultPeopleProperties()
            for (key, value) in properties.toCohorlyProperties() {
                merged[key] = value
            }
            return merged
        }

        public func increment(_ properties: [String: Any]) {
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, add: properties.toCohorlyProperties())
            }
        }

        public func unset(_ keys: [String]) {
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, unset: keys)
            }
        }

        public func deleteUser() {
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, delete: true)
            }
        }
    }

    public lazy var people: People = People(client: self)

    private func queueEngage(_ makePayload: @escaping (String) -> EngagePayload) {
        queue.async {
            guard !self.optedOut else { return }
            var payload = makePayload(self.distinctId)
            payload.token = self.token
            self.engageQueue.append(payload)
            self.persistEngageQueue()
            if self.engageQueue.count >= self.flushAt {
                self.performFlush()
            }
        }
    }

    /// Flushes queued events/profile updates now, in addition to the
    /// automatic interval/size-based triggers. Resolves once the flush
    /// (including any retry bookkeeping on failure) has completed.
    ///
    /// Note: this is intentionally the *only* `flush` overload. Having both
    /// a fire-and-forget sync version and an `async` version led to `await
    /// client.flush()` silently resolving to the sync overload in some call
    /// contexts (e.g. top-level scripts), returning before the network
    /// request actually completed.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                // A manual flush always attempts a send, even while backing off.
                self.performFlush(force: true) {
                    continuation.resume()
                }
            }
        }
    }

    /// Must be called on `queue`.
    ///
    /// Auto-flush (timer) and size-triggered flushes pass `force: false` and are
    /// skipped while the backoff deadline has not passed. A manual `flush()`
    /// passes `force: true` and always attempts a send.
    private func performFlush(force: Bool = false, completion: (() -> Void)? = nil) {
        guard !isFlushing else {
            // A flush is already in flight - wait for it to finish (including
            // its retry bookkeeping) rather than racing it or reporting
            // completion before the network call actually resolves.
            if let completion {
                pendingFlushCompletions.append(completion)
            }
            return
        }
        if optedOut {
            completion?()
            return
        }
        if !force, let until = backoffUntil, Date() < until {
            completion?()
            return
        }

        let batchSize = max(1, effectiveBatchSize)
        let events = Array(eventQueue.prefix(batchSize))
        let engagements = engageQueue
        if events.isEmpty && engagements.isEmpty {
            completion?()
            return
        }

        isFlushing = true
        eventQueue = Array(eventQueue.dropFirst(events.count))
        engageQueue = []
        persistEventQueue()
        persistEngageQueue()

        let apiHost = self.apiHost
        let transport = self.transport
        // Epoch this batch was taken from; `reset()` bumps it (see below).
        let generation = flushGeneration
        let epoch = optOutEpoch

        Task {
            var eventError: Error?
            var failedEngagements: [EngagePayload] = []

            // An opt-out between taking the batch and this task starting
            // drops the batch: nothing is sent once optOutTracking() has run.
            if !events.isEmpty, await self.isOptOutEpochCurrent(epoch) {
                do {
                    let body = try JSONEncoder().encode(events)
                    try await transport.post(apiHost: apiHost, path: "/track", body: body)
                } catch {
                    eventError = error
                }
            }
            // An opt-out while /track was on the wire stops the rest of this
            // flush: nothing is sent once optOutTracking() has run.
            if !engagements.isEmpty, await self.isOptOutEpochCurrent(epoch) {
                do {
                    let body = try JSONEncoder().encode(engagements)
                    try await transport.post(apiHost: apiHost, path: "/engage", body: body)
                } catch {
                    failedEngagements = engagements
                }
            }

            self.queue.async {
                // An opt-out while the request was on the wire: its batches are
                // gone for good and the failure says nothing about the next send.
                let optedOutMeanwhile = epoch != self.optOutEpoch
                if !events.isEmpty, !optedOutMeanwhile {
                    self.handleEventFlushResult(
                        events: events, error: eventError, generation: generation)
                }
                // Same rule as the event batch: a reset() during the request
                // means these profile updates belong to a forgotten user, so
                // drop them rather than re-queue and re-persist them.
                if !failedEngagements.isEmpty, !optedOutMeanwhile, generation == self.flushGeneration {
                    self.engageQueue = failedEngagements + self.engageQueue
                    self.persistEngageQueue()
                }
                self.isFlushing = false
                completion?()
                let waiters = self.pendingFlushCompletions
                self.pendingFlushCompletions = []
                waiters.forEach { $0() }
            }
        }
    }

    /// True while no opt-out ran since `epoch` was read (checked on `queue`).
    private func isOptOutEpochCurrent(_ epoch: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { continuation.resume(returning: epoch == self.optOutEpoch && !self.optedOut) }
        }
    }

    /// Applies the retry contract to the just-attempted /track batch. Must be
    /// called on `queue`.
    ///
    /// - success: reset failure counter + clear backoff.
    /// - 400: permanently rejected - drop the batch (already removed).
    /// - 413: too big - re-queue and halve the effective batch size (no backoff).
    /// - 401: invalid token - re-queue, backoff at max delay.
    /// - 429 / 5xx / network: re-queue, exponential backoff (Retry-After, when
    ///   present on a 429, overrides the computed delay, still capped).
    ///
    /// `generation` is the queue epoch the batch was taken from; when it no
    /// longer matches, `reset()` ran while the request was in flight and the
    /// batch is dropped instead of re-queued. Backoff bookkeeping still applies
    /// - it describes the transport, not the forgotten user's data.
    private func handleEventFlushResult(
        events: [TrackEvent], error: Error?, generation: UInt64
    ) {
        guard let error else {
            // Success.
            consecutiveFailures = 0
            backoffUntil = nil
            return
        }

        var status: Int?
        var retryAfter: TimeInterval?
        if case let CohorlyTransportError.httpError(statusCode, retryAfterValue) = error {
            status = statusCode
            retryAfter = retryAfterValue
        }

        if status == 400 {
            // Permanently rejected: already removed from the queue, so drop.
            return
        }

        // Re-queue at the front for the next attempt, unless reset() cleared
        // the queue while this batch was in flight.
        if generation == flushGeneration {
            eventQueue = events + eventQueue
            persistEventQueue()
        }

        if status == 413 {
            effectiveBatchSize = max(1, effectiveBatchSize / 2)
            return
        }

        consecutiveFailures += 1
        let delay = status == 401
            ? maxRetryDelay
            : backoff.delay(failures: consecutiveFailures, retryAfter: status == 429 ? retryAfter : nil)
        backoffUntil = Date().addingTimeInterval(delay)
    }

    /// Trims the event queue to `maxQueueSize`, dropping the OLDEST events.
    /// Returns true if anything was dropped. Must be called on `queue`.
    private func enforceEventQueueCap() -> Bool {
        guard eventQueue.count > maxQueueSize else { return false }
        eventQueue.removeFirst(eventQueue.count - maxQueueSize)
        return true
    }
}
