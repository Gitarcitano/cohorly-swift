import Cohorly
import Foundation

/// The replay settings the project saved in the dashboard, read with
/// `CohorlyReplayConfig.remoteConfig` (VEL-2234, docs/SESSION-REPLAY.md
/// "Remote settings"). Only these three fields are read: triggers, masking,
/// the capture mode and the quality come from the code only. A field with an
/// invalid value counts as not saved; nil keeps the code's value.
struct RemoteReplayConfig: Equatable, Sendable {
    var sampleRate: Double?
    var onErrorSampleRate: Double?
    var minDurationMs: Int64?

    /// The settings in `value` (a `JSONSerialization` object), nil when it is
    /// not an object.
    static func parse(_ value: Any?) -> RemoteReplayConfig? {
        guard let object = value as? [String: Any] else { return nil }
        var config = RemoteReplayConfig()
        config.sampleRate = rate(object["sampleRate"])
        config.onErrorSampleRate = rate(object["onErrorSampleRate"])
        if let minDuration = number(object["minDurationMs"]), minDuration >= 0 {
            config.minDurationMs = Int64(min(minDuration, Double(ReplayRemoteConfigLoader.maxMinDurationMs)))
        }
        return config
    }

    /// A finite JSON number. `JSONSerialization` hands `true` and `false` back
    /// as `NSNumber` too: a boolean is not a number here.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func rate(_ value: Any?) -> Double? {
        guard let rate = number(value), (0...1).contains(rate) else { return nil }
        return rate
    }

    /// The saved fields only, as stored in the cache.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let sampleRate { object["sampleRate"] = sampleRate }
        if let onErrorSampleRate { object["onErrorSampleRate"] = onErrorSampleRate }
        if let minDurationMs { object["minDurationMs"] = NSNumber(value: minDurationMs) }
        return object
    }
}

/// The cached answer and when it was fetched (unix ms, SDK clock).
struct StoredReplayConfig: Equatable, Sendable {
    var fetchedAt: Int64
    var config: RemoteReplayConfig
}

/// Delayed runs of the remote settings' timers (the 3 s wait and the 30 s
/// abort). Tests swap it to fire them by hand.
typealias ReplayConfigSchedule = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

/// A monotonic clock in seconds, what the 3 s wait and the 30 s abort are
/// measured with: a late timer never stretches either.
typealias ReplayConfigMonotonicNow = @Sendable () -> TimeInterval

/// What `ReplayRemoteConfigLoader.lookup` found: a fresh copy, or a load the
/// completion will end.
enum ReplayConfigLookup: Equatable, Sendable {
    case fresh(RemoteReplayConfig)
    case loading
}

/// Reads `GET {apiHost}/replay/config?token=` and keeps the answer in the
/// SDK's `CohorlyStorage` for an hour, per project. At most one request per
/// project is in flight in the process (a new install included): a load
/// made while one runs waits for the same answer. Each load waits for it at
/// most `timeoutMs` from when it began; the request itself is aborted
/// `abortMs` after it began, so an answer arriving in between still
/// refreshes the cache for later sessions. A failure (network, a status
/// outside 2xx, invalid JSON, the abort) writes nothing. A cached copy
/// stamped in the future is no copy, and an answer never replaces a copy
/// written after its request began.
final class ReplayRemoteConfigLoader: @unchecked Sendable {
    static let ttlMs: Int64 = 3_600_000
    static let timeoutMs: Int64 = 3000
    static let abortMs: Int64 = 30_000
    static let maxMinDurationMs: Int64 = 30_000

    static func storageKey(_ namespace: String) -> String { "cohorly.replay.config.\(namespace)" }

    static let defaultSchedule: ReplayConfigSchedule = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    static let defaultMonotonicNow: ReplayConfigMonotonicNow = { ProcessInfo.processInfo.systemUptime }

    private let url: URL
    private let storage: CohorlyStorage
    private let clock: CohorlyClock
    private let transport: ReplayTransport
    private let schedule: ReplayConfigSchedule
    private let monotonicNow: ReplayConfigMonotonicNow
    private let key: String

    /// The requests in flight in the process, by cache key. Its lock also
    /// covers every read and write of the cached copies, so a lookup sees
    /// either the answer written or the request still running.
    private static let registry = Registry()

    init(
        url: URL, namespace: String, storage: CohorlyStorage, clock: CohorlyClock,
        transport: ReplayTransport, schedule: @escaping ReplayConfigSchedule,
        monotonicNow: @escaping ReplayConfigMonotonicNow = ReplayRemoteConfigLoader.defaultMonotonicNow
    ) {
        self.url = url
        self.storage = storage
        self.clock = clock
        self.transport = transport
        self.schedule = schedule
        self.monotonicNow = monotonicNow
        key = Self.storageKey(namespace)
    }

    /// `{host}/replay/config?token=<token>`, the token percent-encoded.
    static func configURL(host: String, token: String) -> URL? {
        guard let normalized = CohorlyReplay.normalizedHost(host) else { return nil }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "\(normalized)/replay/config?token=\(encoded)")
    }

    /// A plain `GET` of `url`: no cookie, no `Authorization`, no cached
    /// answer, given up after `abortMs`.
    static func configRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds(abortMs))
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return request
    }

    var nowMs: Int64 { ReplaySessionStore.ms(clock.now()) }

    /// The cached copy, fresh or expired; nil without one, when unreadable, or
    /// when it was fetched after `nowMs`.
    func stored(nowMs: Int64) -> StoredReplayConfig? {
        Self.registry.lock.lock()
        defer { Self.registry.lock.unlock() }
        return storedLocked(nowMs: nowMs)
    }

    /// `fetchedAt <= nowMs < fetchedAt + ttlMs`.
    static func isFresh(_ stored: StoredReplayConfig, nowMs: Int64) -> Bool {
        let age = nowMs.subtractingReportingOverflow(stored.fetchedAt)
        return !age.overflow && age.partialValue >= 0 && age.partialValue < ttlMs
    }

    /// In one step: a fresh cached copy, else a load that asks the server or
    /// joins the request in flight. `completion` runs once (only for
    /// `.loading`), never on the caller's stack: with the answer, or with the
    /// expired copy (nil for none) on a failure or `timeoutMs` after this
    /// call, whichever comes first.
    func lookup(completion: @escaping @Sendable (RemoteReplayConfig?) -> Void) -> ReplayConfigLookup {
        let registry = Self.registry
        registry.lock.lock()
        let now = nowMs
        let stored = storedLocked(nowMs: now)
        if let stored, Self.isFresh(stored, nowMs: now) {
            registry.lock.unlock()
            return .fresh(stored.config)
        }
        let waiter = Waiter(
            fallback: stored?.config, startedAt: monotonicNow(), monotonicNow: monotonicNow, completion: completion)
        let flight: Flight
        let starts: Bool
        if let running = registry.flights[key] {
            flight = running
            starts = false
        } else {
            flight = Flight(loader: self, startedAtMs: now, startedAt: monotonicNow())
            registry.flights[key] = flight
            starts = true
        }
        flight.waiters.append(waiter)
        registry.lock.unlock()
        schedule(Self.seconds(Self.timeoutMs)) { waiter.finish(waiter.fallback) }
        if starts { start(flight) }
        return .loading
    }

    /// Forgets every request in flight (tests: each starts from none). A
    /// forgotten request that ends later changes nothing.
    static func resetInFlight() {
        registry.lock.lock()
        registry.flights = [:]
        registry.lock.unlock()
    }

    private func start(_ flight: Flight) {
        let request = Self.configRequest(url: url)
        let transport = self.transport
        let task = Task {
            let config = await Self.fetch(transport: transport, request: request)
            Self.finish(flight, config: config)
        }
        schedule(Self.seconds(Self.abortMs)) {
            task.cancel()
            Self.finish(flight, config: nil)
        }
    }

    private static func fetch(transport: ReplayTransport, request: URLRequest) async -> RemoteReplayConfig? {
        guard let response = try? await transport.get(request: request), !Task.isCancelled,
              (200..<300).contains(response.status),
              let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        else { return nil }
        return RemoteReplayConfig.parse(object["config"])
    }

    /// `flight` ended (answer, failure or abort): every waiter gets its
    /// result. Only the first end counts. The clock decides, not the order
    /// the timers ran in: an answer `abortMs` or more after the request
    /// began is dropped and never cached, and a waiter whose own
    /// `timeoutMs` has passed gets its fallback.
    private static func finish(_ flight: Flight, config: RemoteReplayConfig?) {
        let loader = flight.loader
        registry.lock.lock()
        guard registry.flights[loader.key] === flight else {
            registry.lock.unlock()
            return
        }
        registry.flights[loader.key] = nil
        let inTime = loader.monotonicNow() - flight.startedAt < seconds(abortMs)
        let answer = inTime ? config : nil
        if let answer {
            let now = loader.nowMs
            if let latest = loader.storedLocked(nowMs: now), latest.fetchedAt > flight.startedAtMs {
                // Written after this request began: newer than this answer.
            } else {
                loader.writeLocked(StoredReplayConfig(fetchedAt: now, config: answer))
            }
        }
        let waiters = flight.waiters
        registry.lock.unlock()
        for waiter in waiters {
            let waited = waiter.monotonicNow() - waiter.startedAt
            waiter.finish(waited < seconds(timeoutMs) ? (answer ?? waiter.fallback) : waiter.fallback)
        }
    }

    /// Must hold `registry.lock`.
    private func storedLocked(nowMs: Int64) -> StoredReplayConfig? {
        guard let raw = storage.string(forKey: key), let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fetched = RemoteReplayConfig.number(object["fetchedAt"]),
              abs(fetched) < 9e15,
              let config = RemoteReplayConfig.parse(object["config"])
        else { return nil }
        let fetchedAt = Int64(fetched)
        guard fetchedAt <= nowMs else { return nil }
        return StoredReplayConfig(fetchedAt: fetchedAt, config: config)
    }

    /// Must hold `registry.lock`.
    private func writeLocked(_ stored: StoredReplayConfig) {
        let object: [String: Any] = ["fetchedAt": NSNumber(value: stored.fetchedAt), "config": stored.config.jsonObject]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        storage.setString(raw, forKey: key)
    }

    private static func seconds(_ ms: Int64) -> TimeInterval { TimeInterval(ms) / 1000 }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var flights: [String: Flight] = [:]
    }

    /// One request and the loads waiting for it. The loader that started it
    /// writes the answer. `waiters` is guarded by `registry.lock`.
    private final class Flight: @unchecked Sendable {
        let loader: ReplayRemoteConfigLoader
        /// Unix ms (SDK clock), for the newer-copy check.
        let startedAtMs: Int64
        /// Monotonic seconds, for the abort.
        let startedAt: TimeInterval
        var waiters: [Waiter] = []

        init(loader: ReplayRemoteConfigLoader, startedAtMs: Int64, startedAt: TimeInterval) {
            self.loader = loader
            self.startedAtMs = startedAtMs
            self.startedAt = startedAt
        }
    }

    /// One load: finished once, by the answer or by its own timeout.
    private final class Waiter: @unchecked Sendable {
        let fallback: RemoteReplayConfig?
        /// Monotonic seconds, when this load began.
        let startedAt: TimeInterval
        let monotonicNow: ReplayConfigMonotonicNow
        private let lock = NSLock()
        private var completion: (@Sendable (RemoteReplayConfig?) -> Void)?

        init(
            fallback: RemoteReplayConfig?, startedAt: TimeInterval, monotonicNow: @escaping ReplayConfigMonotonicNow,
            completion: @escaping @Sendable (RemoteReplayConfig?) -> Void
        ) {
            self.fallback = fallback
            self.startedAt = startedAt
            self.monotonicNow = monotonicNow
            self.completion = completion
        }

        func finish(_ config: RemoteReplayConfig?) {
            lock.lock()
            let completion = self.completion
            self.completion = nil
            lock.unlock()
            completion?(config)
        }
    }
}

/// The sampling settings a new session is decided with: the saved value of
/// each field, else the code's. The code has no minimum duration (0).
struct ReplayEffectiveConfig: Equatable, Sendable {
    var sampleRate: Double
    var onErrorSampleRate: Double
    var minDurationMs: Int64

    init(code: CohorlyReplayConfig, remote: RemoteReplayConfig?) {
        sampleRate = remote?.sampleRate ?? code.sampleRate
        onErrorSampleRate = remote?.onErrorSampleRate ?? code.onErrorSampleRate
        minDurationMs = remote?.minDurationMs ?? 0
    }
}

/// How a new session is born: decided (its mode and minimum duration), or
/// pending until the remote settings arrive.
struct ReplaySessionDecision: Equatable, Sendable {
    var mode: ReplayMode
    var minDurationMs: Int64 = 0
    var pending = false

    static let undecided = ReplaySessionDecision(mode: .off, minDurationMs: 0, pending: true)
}

/// Decides the sampling of new sessions (`ReplaySessionStore`). Called under
/// the store's lock: it never calls back into the store.
protocol ReplaySessionDeciding: AnyObject {
    func decideNewSession() -> ReplaySessionDecision
}

/// The settings sessions are decided with, `CohorlyReplayConfig.remoteConfig`
/// on or off. Off: always the code's, no request. On: a fresh cached copy
/// decides a new session at once; without one the session is born pending
/// and a load starts (or the one in flight is joined), and `onSettled` runs
/// when it resolves (the answer, the expired copy, or the code's values) so
/// the runtime decides the pending session. Only the latest load counts.
/// Lock order: the session store's lock, then this one, then the loader's.
final class ReplayRemoteSettings: ReplaySessionDeciding, @unchecked Sendable {
    private let code: CohorlyReplayConfig
    private let loader: ReplayRemoteConfigLoader?
    private let random: () -> Double

    private let lock = NSLock()
    /// What the latest load resolved to; nil while it runs.
    private var resolved: ReplayEffectiveConfig?
    private var loads: UInt64 = 0

    /// Runs (never under a lock, never on the caller's stack) when a load
    /// resolved. Set before any session can be pending; a load that resolves
    /// first is still read by `decisionForPending()`.
    var onSettled: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onSettledValue
        }
        set {
            lock.lock()
            onSettledValue = newValue
            lock.unlock()
        }
    }
    private var onSettledValue: (() -> Void)?

    init(code: CohorlyReplayConfig, loader: ReplayRemoteConfigLoader?, random: @escaping () -> Double) {
        self.code = code
        self.loader = loader
        self.random = random
        guard let loader else {
            resolved = ReplayEffectiveConfig(code: code, remote: nil)
            return
        }
        // Install: a fresh copy is used as is, else the server is asked now.
        lock.lock()
        _ = lookupLocked(loader)
        lock.unlock()
    }

    /// A new session: decided now with the code's values (off), a fresh
    /// cached copy, or pending on its own load (which joins the request in
    /// flight, if any, within its own 3 s).
    func decideNewSession() -> ReplaySessionDecision {
        guard let loader else { return draw(ReplayEffectiveConfig(code: code, remote: nil)) }
        lock.lock()
        let effective = lookupLocked(loader)
        lock.unlock()
        return effective.map(draw) ?? .undecided
    }

    /// The decision of a pending session, nil while the load runs. Called
    /// under the store's lock (`ReplaySessionStore.settlePending`).
    func decisionForPending() -> ReplaySessionDecision? {
        lock.lock()
        let resolved = self.resolved
        lock.unlock()
        return resolved.map(draw)
    }

    /// Must hold `lock`. The settings of a fresh copy, or
    /// nil when a load began (it becomes the latest).
    private func lookupLocked(_ loader: ReplayRemoteConfigLoader) -> ReplayEffectiveConfig? {
        let id = loads &+ 1
        switch loader.lookup(completion: { [weak self] config in self?.resolve(id: id, config: config) }) {
        case .fresh(let config):
            let effective = ReplayEffectiveConfig(code: code, remote: config)
            resolved = effective
            return effective
        case .loading:
            loads = id
            resolved = nil
            return nil
        }
    }

    private func resolve(id: UInt64, config: RemoteReplayConfig?) {
        lock.lock()
        guard id == loads else {
            lock.unlock()
            return
        }
        resolved = ReplayEffectiveConfig(code: code, remote: config)
        let onSettled = onSettledValue
        lock.unlock()
        onSettled?()
    }

    private func draw(_ effective: ReplayEffectiveConfig) -> ReplaySessionDecision {
        let mode = decideReplayMode(
            sampleRate: effective.sampleRate, onErrorSampleRate: effective.onErrorSampleRate, random: random)
        return ReplaySessionDecision(mode: mode, minDurationMs: mode == .session ? effective.minDurationMs : 0)
    }
}
