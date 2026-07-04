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
    public private(set) static var shared: Cohorly?

    /// Creates and stores the shared instance. Call once near app launch.
    @discardableResult
    public static func initialize(
        apiHost: String,
        token: String? = nil,
        transport: CohorlyTransport = URLSessionTransport(),
        storage: CohorlyStorage = UserDefaultsStorage(),
        flushInterval: TimeInterval = 5,
        flushAt: Int = 20
    ) -> Cohorly {
        let instance = Cohorly(
            apiHost: apiHost,
            token: token,
            transport: transport,
            storage: storage,
            flushInterval: flushInterval,
            flushAt: flushAt
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
    private let queue = DispatchQueue(label: "com.cohorly.sdk")
    private var timer: DispatchSourceTimer?

    private var distinctId: String
    private var superProperties: Properties = [:]
    private var eventQueue: [TrackEvent] = []
    private var engageQueue: [EngagePayload] = []
    private var isFlushing = false
    private var pendingFlushCompletions: [() -> Void] = []

    /// Creates a standalone instance. Prefer `initialize(apiHost:)` for the
    /// shared singleton; this initializer is public mainly so tests (and
    /// advanced callers who want multiple instances) can inject a mock
    /// transport/storage directly.
    public init(
        apiHost: String,
        token: String? = nil,
        transport: CohorlyTransport = URLSessionTransport(),
        storage: CohorlyStorage = UserDefaultsStorage(),
        flushInterval: TimeInterval = 5,
        flushAt: Int = 20
    ) {
        self.apiHost = apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost
        self.token = token
        self.transport = transport
        self.storage = storage
        self.flushInterval = flushInterval
        self.flushAt = flushAt

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
        }
        if let raw = storage.string(forKey: Keys.engageQueue),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([EngagePayload].self, from: data)
        {
            self.engageQueue = decoded
        }

        startTimer()
    }

    deinit {
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
                self.performFlush {
                    continuation.resume()
                }
            }
        }
    }

    /// Must be called on `queue`.
    private func performFlush(completion: (() -> Void)? = nil) {
        guard !isFlushing else {
            // A flush is already in flight - wait for it to finish (including
            // its retry bookkeeping) rather than racing it or reporting
            // completion before the network call actually resolves.
            if let completion {
                pendingFlushCompletions.append(completion)
            }
            return
        }
        let events = eventQueue
        let engagements = engageQueue
        if events.isEmpty && engagements.isEmpty {
            completion?()
            return
        }

        isFlushing = true
        eventQueue = []
        engageQueue = []
        persistEventQueue()
        persistEngageQueue()

        let apiHost = self.apiHost
        let transport = self.transport

        Task {
            var failedEvents: [TrackEvent] = []
            var failedEngagements: [EngagePayload] = []

            if !events.isEmpty {
                do {
                    let body = try JSONEncoder().encode(events)
                    try await transport.post(apiHost: apiHost, path: "/track", body: body)
                } catch {
                    failedEvents = events
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
                if !failedEvents.isEmpty {
                    self.eventQueue = failedEvents + self.eventQueue
                    self.persistEventQueue()
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
}
