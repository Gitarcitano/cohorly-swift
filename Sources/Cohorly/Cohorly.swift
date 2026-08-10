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
    }

    /// Shared instance, set by `initialize(apiHost:)`. `nil` until then.
    /// `nonisolated(unsafe)`: the class is `@unchecked Sendable` and serializes
    /// its own state, so Swift 6 consumers can access the singleton directly.
    public private(set) static nonisolated(unsafe) var shared: Cohorly?

    /// Cohorly's hosted ingestion API, used when no `apiHost` is supplied.
    public static let defaultAPIHost = "https://cohorly-service.velloalabs.com"

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
        clock: CohorlyClock = SystemClock(),
        flagsFetcher: CohorlyFlagsFetcher = URLSessionFlagsFetcher(),
        loadFeatureFlags: Bool = true,
        sendExposureEvents: Bool = true
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
            clock: clock,
            flagsFetcher: flagsFetcher,
            loadFeatureFlags: loadFeatureFlags,
            sendExposureEvents: sendExposureEvents
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
    private var timer: DispatchSourceTimer?

    /// Exponential backoff base, in seconds.
    private let backoffBase: TimeInterval = 2

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
    /// Drives `$ae_*` lifecycle events; non-nil only when `trackAutomaticEvents`.
    private var automaticEvents: AutomaticEvents?

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
        clock: CohorlyClock = SystemClock(),
        flagsFetcher: CohorlyFlagsFetcher = URLSessionFlagsFetcher(),
        loadFeatureFlags: Bool = true,
        sendExposureEvents: Bool = true
    ) {
        self.flagsFetcher = flagsFetcher
        self.sendExposureEvents = sendExposureEvents
        self.apiHost = apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost
        self.token = token
        self.transport = transport
        self.storage = storage
        self.flushInterval = flushInterval
        self.flushAt = flushAt
        self.maxQueueSize = maxQueueSize
        self.maxRetryDelay = maxRetryDelay
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

        // Feature-flag cache: served only when it belongs to the current
        // distinct id; another identity's cache is dropped, never served.
        if let raw = storage.string(forKey: Keys.flags),
            let data = raw.data(using: .utf8),
            let cache = try? JSONDecoder().decode(FlagsCache.self, from: data) {
            if cache.distinctId == self.distinctId {
                self.flags = cache.flags
                self.flagsLoaded = true
            } else {
                storage.setString(nil, forKey: Keys.flags)
            }
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

            self.eventQueue.append(TrackEvent(event: event, properties: merged))
            _ = self.enforceEventQueueCap()
            self.persistEventQueue()

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
            // Exposures are per-identity: the new user must report its own.
            self.reportedExposures.removeAll()

            // Flags are per-identity: refresh them for the new id, off the
            // serial queue so the request never delays the switch.
            Task { await self.reloadFeatureFlags() }

            guard wasAnonymous else { return }
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
            self.persistSuperProperties()
            self.persistEventQueue()
            self.persistEngageQueue()
            // Flags are per-identity: the previous identity's flags must never
            // be served to the fresh anonymous id, so drop them (memory and
            // disk) BEFORE asking the server for this id's flags.
            self.flags = [:]
            self.flagsLoaded = false
            self.flagRequestSeq &+= 1
            self.reportedExposures.removeAll()
            self.storage.setString(nil, forKey: Keys.flags)
            Task { await self.reloadFeatureFlags() }
        }
    }

    // MARK: - Feature flags

    /// Re-evaluates feature flags for the current distinct id via
    /// `POST /flags/evaluate`, caching the result in memory and in `storage`
    /// (scoped by distinct id).
    ///
    /// Never throws and never clears the cache on failure: a network error,
    /// a non-2xx response or an unparseable body simply leaves the previously
    /// known flags in place. Results are discarded when the identity changed,
    /// or a newer reload started, while the request was in flight.
    public func reloadFeatureFlags() async {
        let (requestedId, seq) = queue.sync { () -> (String, UInt64) in
            flagRequestSeq &+= 1
            return (distinctId, flagRequestSeq)
        }
        guard
            let body = try? JSONEncoder().encode(
                FlagsRequest(distinctId: requestedId, token: token)),
            let data = await flagsFetcher.fetchFlags(
                apiHost: apiHost, path: "/flags/evaluate", body: body),
            let decoded = try? JSONDecoder().decode(FlagsResponse.self, from: data)
        else { return }

        let listeners: [@Sendable ([String: FlagResult]) -> Void] = queue.sync {
            guard requestedId == distinctId, seq == flagRequestSeq else { return [] }
            flags = decoded.flags
            flagsLoaded = true
            persistFlags()
            return Array(flagListeners.values)
        }
        for listener in listeners { listener(decoded.flags) }
    }

    /// The flag's variant when it has one, else its enabled boolean. `.bool(false)`
    /// for an unknown flag or before flags have loaded.
    ///
    /// Reading a *known* flag also emits `$feature_flag_called` once per
    /// distinct value, per identity (see `recordExposure`).
    public func getFeatureFlag(_ key: String) -> JSONValue {
        let (value, exposure) = queue.sync { () -> (JSONValue, Any?) in
            guard let flag = flags[key] else { return (.bool(false), nil) }
            let value: JSONValue = flag.variant.map { JSONValue.string($0) } ?? .bool(flag.enabled)
            return (value, recordExposure(key: key, flag: flag))
        }
        trackExposure(key: key, response: exposure)
        return value
    }

    /// Whether `key` is enabled. `false` for an unknown or unloaded flag.
    ///
    /// Emits `$feature_flag_called` on the same terms as `getFeatureFlag`.
    public func isFeatureEnabled(_ key: String) -> Bool {
        let (enabled, exposure) = queue.sync { () -> (Bool, Any?) in
            guard let flag = flags[key] else { return (false, nil) }
            return (flag.enabled, recordExposure(key: key, flag: flag))
        }
        trackExposure(key: key, response: exposure)
        return enabled
    }

    /// Marks `key` as exposed and returns the `$feature_flag_response` value to
    /// report, or `nil` when nothing should be tracked (exposure events off, or
    /// this key/value pair was already reported for the current identity).
    ///
    /// Must be called on `queue`.
    private func recordExposure(key: String, flag: FlagResult) -> Any? {
        guard sendExposureEvents else { return nil }
        let response: Any = flag.variant ?? flag.enabled
        let dedupeKey = "\(key):\(flag.variant ?? String(flag.enabled))"
        guard reportedExposures.insert(dedupeKey).inserted else { return nil }
        return response
    }

    /// Queues the exposure event. Called OFF `queue` (right after the
    /// `queue.sync` that decided it) because `track` hops onto `queue` itself -
    /// nesting the two would be a re-entrant `sync` and deadlock.
    private func trackExposure(key: String, response: Any?) {
        guard let response else { return }
        track(
            "$feature_flag_called",
            properties: ["$feature_flag": key, "$feature_flag_response": response]
        )
    }

    /// The JSON payload attached to `key`, or `nil` when it has none.
    public func getFeatureFlagPayload(_ key: String) -> JSONValue? {
        queue.sync { flags[key]?.payload }
    }

    /// Every flag currently known for the active distinct id.
    public func currentFeatureFlags() -> [String: FlagResult] {
        queue.sync { flags }
    }

    /// Subscribes to flag updates. `listener` fires after every successful
    /// reload, and immediately when flags are already loaded. Returns a closure
    /// that removes the subscription.
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

    /// Must be called on `queue`.
    private func persistFlags() {
        guard
            let data = try? JSONEncoder().encode(
                FlagsCache(distinctId: distinctId, flags: flags)),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        storage.setString(raw, forKey: Keys.flags)
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

        Task {
            var eventError: Error?
            var failedEngagements: [EngagePayload] = []

            if !events.isEmpty {
                do {
                    let body = try JSONEncoder().encode(events)
                    try await transport.post(apiHost: apiHost, path: "/track", body: body)
                } catch {
                    eventError = error
                }
            }
            if !engagements.isEmpty {
                do {
                    let body = try JSONEncoder().encode(engagements)
                    try await transport.post(apiHost: apiHost, path: "/engage", body: body)
                } catch {
                    failedEngagements = engagements
                }
            }

            self.queue.async {
                if !events.isEmpty {
                    self.handleEventFlushResult(
                        events: events, error: eventError, generation: generation)
                }
                // Same rule as the event batch: a reset() during the request
                // means these profile updates belong to a forgotten user, so
                // drop them rather than re-queue and re-persist them.
                if !failedEngagements.isEmpty, generation == self.flushGeneration {
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
        var delay = computeBackoff()
        if status == 401 {
            delay = maxRetryDelay
        } else if status == 429, let retryAfter {
            delay = min(retryAfter, maxRetryDelay)
        }
        backoffUntil = Date().addingTimeInterval(delay)
    }

    /// Exponential backoff: base 2s, doubling per consecutive failure, capped at
    /// `maxRetryDelay`, with +/-20% jitter.
    private func computeBackoff() -> TimeInterval {
        let exp = backoffBase * pow(2, Double(consecutiveFailures - 1))
        let capped = min(exp, maxRetryDelay)
        let jitter = capped * 0.2 * (Double.random(in: -1...1))
        return max(0, capped + jitter)
    }

    /// Trims the event queue to `maxQueueSize`, dropping the OLDEST events.
    /// Returns true if anything was dropped. Must be called on `queue`.
    private func enforceEventQueueCap() -> Bool {
        guard eventQueue.count > maxQueueSize else { return false }
        eventQueue.removeFirst(eventQueue.count - maxQueueSize)
        return true
    }
}
