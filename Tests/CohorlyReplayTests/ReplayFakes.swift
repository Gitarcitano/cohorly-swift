import Foundation
import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

final class MutableClock: CohorlyClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

/// Hands out `values` in order, then `fallback`.
final class ScriptedRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    private let fallback: Double
    private(set) var calls = 0

    init(_ values: [Double] = [], fallback: Double = 0.5) {
        self.values = values
        self.fallback = fallback
    }

    func push(_ more: [Double]) {
        lock.lock(); values += more; lock.unlock()
    }

    func next() -> Double {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return values.isEmpty ? fallback : values.removeFirst()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

struct SentRequest {
    let url: URL
    let headers: [String: String]
    let body: Data

    var chunk: ReplayChunkBody? {
        guard let json = try? body.cohorlyGunzipped() else { return nil }
        return try? JSONDecoder().decode(ReplayChunkBody.self, from: json)
    }
}

enum ScriptedReply {
    case status(Int, retryAfter: TimeInterval? = nil, body: String = "")
    case networkError
}

/// Answers from a script (then `fallback`), recording every request. While
/// held, requests wait until `release()`. `GET /replay/config` has its own
/// script, record and hold (`replyConfig`, `configRequests`, `holdConfig`).
final class FakeReplayTransport: ReplayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ScriptedReply]
    private var fallback: ScriptedReply
    private var _requests: [SentRequest] = []
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var configScript: [ScriptedReply] = []
    private var configFallback: ScriptedReply = .status(200, body: #"{"config":{}}"#)
    private var _configRequests: [URLRequest] = []
    private var configHeld = false
    private var configWaiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var configCancelled: Set<Int> = []
    private var _configCancellations = 0

    init(_ script: [ScriptedReply] = [], fallback: ScriptedReply = .status(200)) {
        self.script = script
        self.fallback = fallback
    }

    var requests: [SentRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var chunks: [ReplayChunkBody] { requests.compactMap(\.chunk) }

    func reply(_ more: [ScriptedReply], fallback: ScriptedReply? = nil) {
        lock.lock()
        script += more
        if let fallback { self.fallback = fallback }
        lock.unlock()
    }

    func hold() {
        lock.lock(); held = true; lock.unlock()
    }

    func release() {
        lock.lock()
        held = false
        let waiting = self.waiting
        self.waiting = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    /// Waits (polling, at most `timeout` seconds) until `count` requests were made.
    func waitForRequests(_ count: Int, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while requests.count < count {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    var configRequests: [URL] { configURLRequests.compactMap(\.url) }

    var configURLRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _configRequests
    }

    /// Config requests cancelled while they waited (the 30 s abort).
    var configCancellations: Int {
        lock.lock(); defer { lock.unlock() }
        return _configCancellations
    }

    func replyConfig(_ more: [ScriptedReply], fallback: ScriptedReply? = nil) {
        lock.lock()
        configScript += more
        if let fallback { configFallback = fallback }
        lock.unlock()
    }

    /// Config requests made from now on wait until `releaseConfig()`.
    func holdConfig() {
        lock.lock(); configHeld = true; lock.unlock()
    }

    func releaseConfig() {
        lock.lock()
        configHeld = false
        let waiting = configWaiting.values
        configWaiting = [:]
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    /// Waits (polling, at most `timeout` seconds) until `count` config requests were made.
    func waitForConfigRequests(_ count: Int, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while configRequests.count < count {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    /// While held it waits for `releaseConfig()` or the task's cancellation
    /// (counted in `configCancellations`, then `CancellationError`).
    func get(request: URLRequest) async throws -> ReplayHTTPResponse {
        let (id, mustWait) = recordConfig(request)
        if mustWait {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    parkConfig(id, continuation)
                }
            } onCancel: {
                cancelConfig(id)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        switch nextConfigReply() {
        case let .status(status, retryAfter, body):
            return ReplayHTTPResponse(status: status, retryAfter: retryAfter, body: Data(body.utf8))
        case .networkError:
            throw URLError(.notConnectedToInternet)
        }
    }

    private func recordConfig(_ request: URLRequest) -> (id: Int, mustWait: Bool) {
        lock.lock(); defer { lock.unlock() }
        _configRequests.append(request)
        return (_configRequests.count, configHeld)
    }

    private func parkConfig(_ id: Int, _ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if configHeld, !configCancelled.contains(id) {
            configWaiting[id] = continuation
            lock.unlock()
        } else {
            lock.unlock()
            continuation.resume()
        }
    }

    private func cancelConfig(_ id: Int) {
        lock.lock()
        configCancelled.insert(id)
        _configCancellations += 1
        let continuation = configWaiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume()
    }

    private func nextConfigReply() -> ScriptedReply {
        lock.lock(); defer { lock.unlock() }
        return configScript.isEmpty ? configFallback : configScript.removeFirst()
    }

    func send(url: URL, headers: [String: String], body: Data) async throws -> ReplayHTTPResponse {
        lock.lock()
        _requests.append(SentRequest(url: url, headers: headers, body: body))
        let mustWait = held
        lock.unlock()
        if mustWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if held {
                    waiting.append(continuation)
                    lock.unlock()
                } else {
                    lock.unlock()
                    continuation.resume()
                }
            }
        }
        lock.lock()
        let reply = script.isEmpty ? fallback : script.removeFirst()
        lock.unlock()
        switch reply {
        case let .status(status, retryAfter, body):
            return ReplayHTTPResponse(status: status, retryAfter: retryAfter, body: Data(body.utf8))
        case .networkError:
            throw URLError(.notConnectedToInternet)
        }
    }
}

final class FakeLifecycle: ReplayLifecycleSource {
    private var handler: (@Sendable (ReplayLifecycleEvent) -> Void)?
    func start(_ handler: @escaping @Sendable (ReplayLifecycleEvent) -> Void) { self.handler = handler }
    func stop() { handler = nil }
    func send(_ event: ReplayLifecycleEvent) { handler?(event) }
}

/// Records `/track` batches.
final class TrackRecorder: CohorlyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []

    func post(apiHost: String, path: String, body: Data) async throws {
        guard path == "/track" else { return }
        lock.lock(); bodies.append(body); lock.unlock()
    }

    var events: [TrackEvent] {
        lock.lock(); defer { lock.unlock() }
        return bodies.flatMap { (try? JSONDecoder().decode([TrackEvent].self, from: $0)) ?? [] }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bodies.count
    }
}

struct NoFlags: CohorlyFlagsFetcher {
    func fetchFlags(apiHost: String, path: String, body: Data) async -> Data? { nil }
}

/// The remote settings' timers, fired by hand: `fire(after:)` runs every
/// timer scheduled with that delay (the 3 s wait, the 30 s abort).
final class ManualSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [(delay: TimeInterval, work: @Sendable () -> Void)] = []

    var schedule: ReplayConfigSchedule {
        { [self] delay, work in
            lock.lock(); timers.append((delay, work)); lock.unlock()
        }
    }

    func pending(after delay: TimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        return timers.filter { $0.delay == delay }.count
    }

    func fire(after delay: TimeInterval) {
        lock.lock()
        let due = timers.filter { $0.delay == delay }
        timers.removeAll { $0.delay == delay }
        lock.unlock()
        due.forEach { $0.work() }
    }
}

/// Polls `condition` (at most `timeout` seconds); true once it holds.
func eventually(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

/// A one-shot gate a background step waits on, with a deadline so a test
/// that goes wrong fails instead of hanging.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    @discardableResult
    func wait(timeout: TimeInterval = 2) -> Bool { semaphore.wait(timeout: .now() + timeout) == .success }
}

/// A file writer that fails for the urls `shouldFail` picks.
final class FailingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var predicate: (URL) -> Bool = { _ in false }
    func fail(when predicate: @escaping (URL) -> Bool) {
        lock.lock(); self.predicate = predicate; lock.unlock()
    }
    var writer: ReplayFileWriter {
        { [self] data, url in
            lock.lock()
            let fails = predicate(url)
            lock.unlock()
            if fails { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Everything one test needs, on a fresh temporary directory.
final class ReplayHarness {
    static let apiHost = "https://ingest.example.com"
    let clock = MutableClock()
    let storage = InMemoryStorage()
    let transport: FakeReplayTransport
    let lifecycle = FakeLifecycle()
    let random: ScriptedRandom
    let track = TrackRecorder()
    /// Parent of every project's directory.
    let root: URL
    var maxDiskBytes = ReplayChunkQueue.defaultMaxDiskBytes
    let writer = FailingWriter()
    /// The remote settings' 3 s and 30 s timers.
    let configTimers = ManualSchedule()

    /// The namespace and directory of the default project (`tok_1`).
    static func namespace(token: String = "tok_1") -> String {
        ReplayNamespace.make(host: apiHost, token: token)
    }
    var queueRoot: URL { root.appendingPathComponent(Self.namespace(), isDirectory: true) }

    init(transport: FakeReplayTransport = FakeReplayTransport(), random: ScriptedRandom = ScriptedRandom()) {
        self.transport = transport
        self.random = random
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohorly-replay-tests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeCohorly(token: String? = "tok_1", flushAt: Int = 1000) -> Cohorly {
        Cohorly(
            apiHost: Self.apiHost + "/",
            token: token,
            transport: track,
            storage: storage,
            flushInterval: 3600,
            flushAt: flushAt,
            maxRetryDelay: 600,
            clock: clock,
            flagsFetcher: NoFlags(),
            loadFeatureFlags: false
        )
    }

    var environment: ReplayEnvironment {
        let random = self.random
        return ReplayEnvironment(
            transport: transport,
            lifecycle: lifecycle,
            random: { random.next() },
            rootDirectory: root,
            maxDiskBytes: maxDiskBytes,
            writeFile: writer.writer,
            // The recorder is tested on its own (ReplayRecorderTests): here it
            // would capture whatever window the test host shows.
            makeRecorder: { _ in nil },
            configSchedule: configTimers.schedule,
            configMonotonicNow: { [clock] in clock.now().timeIntervalSince1970 }
        )
    }

    func install(
        _ cohorly: Cohorly, sampleRate: Double = 1, onErrorSampleRate: Double = 0, remoteConfig: Bool = false
    ) -> ReplayRuntime? {
        CohorlyReplay.install(
            cohorly: cohorly,
            config: CohorlyReplayConfig(
                sampleRate: sampleRate, onErrorSampleRate: onErrorSampleRate, remoteConfig: remoteConfig),
            environment: environment)
    }

    /// A session store and a started chunk queue on this harness's storage,
    /// clock and directory, as a relaunch would build them.
    func makeQueue(
        transport: ReplayTransport? = nil,
        maxDiskBytes: Int? = nil,
        distinctId: String = "user-1",
        mode: ReplayMode = .session
    ) -> (ReplayChunkQueue, ReplaySessionStore) {
        let namespace = Self.namespace()
        let sessions = ReplaySessionStore(storage: storage, clock: clock, namespace: namespace) { mode }
        sessions.setDistinctId(distinctId)
        let random = self.random
        let queue = ReplayChunkQueue(
            endpoint: URL(string: "https://ingest.example.com/replay")!,
            token: "tok_1",
            namespace: namespace,
            root: queueRoot,
            maxDiskBytes: maxDiskBytes ?? self.maxDiskBytes,
            backoff: CohorlyBackoff(maxDelay: 600),
            libVersion: "9.9.9",
            transport: transport ?? self.transport,
            clock: clock,
            storage: storage,
            sessions: sessions,
            random: { random.next() },
            writeFile: writer.writer
        )
        queue.beforeSendHook = beforeSendHook
        queue.start()
        return (queue, sessions)
    }

    /// Set before `makeQueue` to run it before every pre-send check.
    var beforeSendHook: (@Sendable () -> Void)?

    /// Chunk files of the default project, as `<session>/<seq>.json.gz`.
    func files() -> [String] { files(under: queueRoot) }

    /// Every chunk file under the shared root, as `<namespace>/<session>/<seq>.json.gz`.
    func allFiles() -> [String] { files(under: root) }

    private func files(under base: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "gz" else { continue }
            found.append(url.resolvingSymlinksInPath().path.replacingOccurrences(of: base.resolvingSymlinksInPath().path + "/", with: ""))
        }
        return found.sorted()
    }

    /// Writes a chunk file as an earlier launch would have left it.
    func plantChunk(sessionId: String, seq: Int, events: [ReplayJSON] = rrwebEvents(1), name: String? = nil) throws {
        let dir = queueRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let header = ReplayChunkHeader(sessionId: sessionId, distinctId: "planted", seq: seq, mode: .session,
                                             lib: "ios", libVersion: "0")
        let encoder = JSONEncoder()
        let json = ReplayChunkQueue.chunkJSON(header: header, events: events.compactMap { try? encoder.encode($0) })
        try json.cohorlyGzipped().write(to: dir.appendingPathComponent(name ?? "\(seq).json.gz"))
    }
}

func rrwebEvents(_ count: Int, start: Int = 0, payload: String = "x") -> [ReplayJSON] {
    (start..<(start + count)).map { index in
        .object([
            "type": .int(3),
            "timestamp": .int(1_800_000_000_000 + index),
            "data": .object(["index": .int(index), "payload": .string(payload)])
        ])
    }
}

func eventIndexes(_ chunk: ReplayChunkBody?) -> [Int] {
    (chunk?.events ?? []).compactMap { event in
        guard case .object(let object) = event, case .object(let data)? = object["data"],
              case .int(let index)? = data["index"] else { return nil }
        return index
    }
}
