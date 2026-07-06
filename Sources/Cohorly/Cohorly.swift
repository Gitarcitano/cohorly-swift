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
        static let superProperties = "cohorly.super_properties"
        static let eventQueue = "cohorly.event_queue"
        static let engageQueue = "cohorly.engage_queue"
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
        clock: CohorlyClock = SystemClock()
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
            clock: clock
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
    private var superProperties: Properties = [:]
    private var eventQueue: [TrackEvent] = []
    private var engageQueue: [EngagePayload] = []
    private var isFlushing = false
    private var pendingFlushCompletions: [() -> Void] = []

    /// Consecutive flush failures, drives exponential backoff. Reset on success.
    private var consecutiveFailures = 0
    /// Instant before which non-forced flushes are skipped. `nil` when clear.
    private var backoffUntil: Date?
    /// Current effective per-flush batch size; halved on 413 (floor 1).
    private var effectiveBatchSize: Int

    /// Time source, injected for deterministic tests. Used by automatic events.
    private let clock: CohorlyClock
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
        clock: CohorlyClock = SystemClock()
    ) {
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
        } else {
            let newId = UUID().uuidString
            self.distinctId = newId
            storage.setString(newId, forKey: Keys.distinctId)
        }

        if let raw = storage.string(forKey: Keys.superProperties),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Properties.self, from: data)
        {
            self.superProperties = decoded
        }
        if let raw = storage.string(forKey: Keys.eventQueue),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([TrackEvent].self, from: data)
        {
            self.eventQueue = decoded
            // Enforce the persisted cap on load in case a larger queue was stored.
            if enforceEventQueueCap() { persistEventQueue() }
        }
        if let raw = storage.string(forKey: Keys.engageQueue),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([EngagePayload].self, from: data)
        {
            self.engageQueue = decoded
        }

        startTimer()

        if trackAutomaticEvents {
            let ae = AutomaticEvents(client: self, storage: storage, clock: clock)
            self.automaticEvents = ae
            ae.start(currentVersion: DeviceInfo.appVersion)
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
            if let token = self.token {
                merged["token"] = .string(token)
            }

            self.eventQueue.append(TrackEvent(event: event, properties: merged))
            _ = self.enforceEventQueueCap()
            self.persistEventQueue()

            if self.eventQueue.count >= self.flushAt {
                self.performFlush()
            }
        }
    }

    public func identify(_ distinctId: String) {
        queue.async {
            self.distinctId = distinctId
            self.storage.setString(distinctId, forKey: Keys.distinctId)
        }
    }

    /// Clears identity, super properties, and any un-flushed events, then
    /// assigns a fresh anonymous distinct id.
    public func reset() {
        queue.async {
            self.distinctId = UUID().uuidString
            self.superProperties = [:]
            self.eventQueue = []
            self.engageQueue = []
            self.storage.setString(self.distinctId, forKey: Keys.distinctId)
            self.persistSuperProperties()
            self.persistEventQueue()
            self.persistEngageQueue()
        }
    }

    public struct People {
        fileprivate weak var client: Cohorly?

        public func set(_ properties: [String: Any]) {
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, set: properties.toCohorlyProperties())
            }
        }

        public func setOnce(_ properties: [String: Any]) {
            client?.queueEngage { distinctId in
                EngagePayload(distinctId: distinctId, setOnce: properties.toCohorlyProperties())
            }
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
                    self.handleEventFlushResult(events: events, error: eventError)
                }
                if !failedEngagements.isEmpty {
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
    private func handleEventFlushResult(events: [TrackEvent], error: Error?) {
        guard let error else {
            // Success.
            consecutiveFailures = 0
            backoffUntil = nil
            return
        }

        var status: Int?
        var retryAfter: TimeInterval?
        if case let CohorlyTransportError.httpError(s, ra) = error {
            status = s
            retryAfter = ra
        }

        if status == 400 {
            // Permanently rejected: already removed from the queue, so drop.
            return
        }

        // Re-queue at the front for the next attempt.
        eventQueue = events + eventQueue
        persistEventQueue()

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
