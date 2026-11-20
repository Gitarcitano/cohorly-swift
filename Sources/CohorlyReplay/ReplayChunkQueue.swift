@_spi(CohorlyReplay) import Cohorly
import Foundation

/// One chunk as sent to `POST /replay` (docs/SESSION-REPLAY.md section 2).
struct ReplayChunkBody: Codable, Equatable {
    var sessionId: String
    var distinctId: String
    var seq: Int
    var mode: ReplayChunkMode
    var lib: String
    var libVersion: String
    var events: [ReplayJSON]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case distinctId = "distinct_id"
        case seq
        case mode
        case lib
        case libVersion = "lib_version"
        case events
    }
}

/// Writes a chunk file. Swapped in tests to make a write fail.
typealias ReplayFileWriter = @Sendable (Data, URL) throws -> Void

/// The replay chunk queue: one gzipped file per chunk at
/// `<root>/<session_id>/<seq>.json.gz` (`root` is already the project's own
/// directory), apart from the event queue, sent oldest first to
/// `POST {apiHost}/replay`, one request at a time.
///
/// A chunk takes its session, distinct id and seq when it is queued (on the
/// caller's thread); a file that exists is never overwritten (the chunk takes
/// the next free seq). The files survive a relaunch (a new queue on the same
/// directory sends them and continues their seqs), the directory is bounded
/// by `maxDiskBytes` (oldest dropped first), and a failed write loses the
/// chunk, never the app. Retry policy (same as the web sender): 2xx removes;
/// 429, 408, 5xx and network keep it and back off (`Retry-After` above 0
/// wins); 401 keeps it at the maximum backoff; 413 splits it in two; any
/// other 4xx drops it; 404 stops replay for the rest of the process (files
/// stay); 429 `replay quota exceeded` pauses session mode until
/// `Retry-After` (persisted) and drops that session's queued session-mode
/// chunks.
///
/// All state lives on `queue`, except the quota pause and the gone flag
/// (`flagsLock`, read from any thread).
final class ReplayChunkQueue: @unchecked Sendable {
    static let maxChunkEvents = 1000
    /// The whole chunk JSON (envelope included) stays at or below this; one
    /// event whose chunk alone is larger is dropped.
    static let maxChunkBytes = 1_000_000
    static let defaultMaxDiskBytes = 20 * 1024 * 1024
    static func quotaKey(_ namespace: String) -> String { "cohorly.replay.quota_until.\(namespace)" }
    /// Pause after a quota refusal without `Retry-After` (web `DEFAULT_QUOTA_PAUSE_MS`).
    static let defaultQuotaPause: TimeInterval = 60 * 60
    static let quotaError = "replay quota exceeded"
    static let lib = "ios"
    private static let fileSuffix = ".json.gz"

    static var defaultRootDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("cohorly/replay", isDirectory: true)
    }

    static let defaultFileWriter: ReplayFileWriter = { data, url in try data.write(to: url, options: .atomic) }

    // MARK: Process-wide 404

    private static let processLock = NSLock()
    private static var processGone = false

    /// A 404 seen by any queue in this process.
    static var isGoneForProcess: Bool {
        processLock.lock(); defer { processLock.unlock() }
        return processGone
    }

    /// Tests only: a fresh process.
    static func resetProcessGone() {
        processLock.lock(); processGone = false; processLock.unlock()
    }

    struct Entry: Equatable {
        var sessionId: String
        var seq: Int
        var url: URL
        var bytes: Int
        /// nil for a chunk found on disk at launch (read from the file when needed).
        var mode: ReplayChunkMode?
    }

    enum Outcome: Equatable {
        case ok
        case retry(retryAfter: TimeInterval?)
        case retryAtMax
        case split
        case drop
        case gone
        case quota(retryAfter: TimeInterval?)
    }

    private let queue = DispatchQueue(label: "com.cohorly.replay")
    private let endpoint: URL
    private let token: String
    private let root: URL
    private let quotaStorageKey: String
    private let maxDiskBytes: Int
    private let backoff: CohorlyBackoff
    private let libVersion: String
    private let transport: ReplayTransport
    private let clock: CohorlyClock
    private let storage: CohorlyStorage
    private let sessions: ReplaySessionStore
    private let random: @Sendable () -> Double
    private let writeFile: ReplayFileWriter

    private var entries: [Entry] = []
    private var inFlight: URL?
    private var failures = 0
    private var backoffUntil: Date?
    private var gone = false
    private var stopped = true
    /// Bumped by every halt: a send not yet started, or a response that comes
    /// back after it, changes nothing.
    private var epoch: UInt64 = 0
    private var retryWork: DispatchWorkItem?
    private var idleWaiters: [() -> Void] = []

    private let flagsLock = NSLock()
    private var quotaUntilMs: Int64
    private var goneFlag = false
    private var haltedFlag = true
    private var droppedCount = 0

    /// Tests only: runs off the queue right before the pre-send check.
    var beforeSendHook: (@Sendable () -> Void)?
    /// Tests only: runs on the caller's thread after a chunk was admitted
    /// (seqs taken) and before its write is handed to the queue.
    var afterAdmitHook: (@Sendable () -> Void)?

    init(
        endpoint: URL,
        token: String,
        namespace: String,
        root: URL,
        maxDiskBytes: Int,
        backoff: CohorlyBackoff,
        libVersion: String,
        transport: ReplayTransport,
        clock: CohorlyClock,
        storage: CohorlyStorage,
        sessions: ReplaySessionStore,
        random: @escaping @Sendable () -> Double,
        writeFile: @escaping ReplayFileWriter = ReplayChunkQueue.defaultFileWriter
    ) {
        self.endpoint = endpoint
        self.token = token
        self.root = root
        let quotaStorageKey = Self.quotaKey(namespace)
        self.quotaStorageKey = quotaStorageKey
        self.maxDiskBytes = maxDiskBytes
        self.backoff = backoff
        self.libVersion = libVersion
        self.transport = transport
        self.clock = clock
        self.storage = storage
        self.sessions = sessions
        self.random = random
        self.writeFile = writeFile
        quotaUntilMs = storage.string(forKey: quotaStorageKey).flatMap { Int64($0) } ?? 0
        if Self.isGoneForProcess {
            gone = true
            goneFlag = true
        }
        queue.sync { load() }
    }

    // MARK: - API

    /// Starts sending (what a previous launch left included).
    func start() {
        setHalted(false)
        queue.async {
            self.stopped = false
            self.pump()
        }
    }

    /// Queues `events` (rrweb-shaped JSON) as chunks of the live session. The
    /// session, distinct id and seqs are taken now, on the caller's thread;
    /// the files are written on the queue. A no-op once stopped (opt-out,
    /// 404), and for `.session` while the quota pause runs.
    func enqueue(events: [ReplayJSON], mode: ReplayChunkMode) {
        _ = enqueue(events: events, mode: mode) { sessions.reserve($0) }
    }

    /// Queues `events` under `sessionId` and `distinctId` as given, the live
    /// session or one that rotated out since the events were recorded (the
    /// recorder's buffer), with that session's next seqs. `.refused` when
    /// nothing was queued (stopped, 404, quota pause for `.session`, or a
    /// session neither live nor remembered, which also counts as dropped).
    @discardableResult
    func enqueue(events: [ReplayJSON], mode: ReplayChunkMode, sessionId: String, distinctId: String) -> ReplayAdmission {
        guard ReplaySessionId.isValid(sessionId) else { return .refused }
        return enqueue(events: events, mode: mode) { count in
            sessions.reserve(sessionId: sessionId, distinctId: distinctId, count)
        }
    }

    private func enqueue(
        events: [ReplayJSON], mode: ReplayChunkMode,
        reserve: ((_ sessionId: String, _ distinctId: String) -> Int) -> ReplayChunkContext?
    ) -> ReplayAdmission {
        guard !events.isEmpty, isAccepting else { return .refused }
        if mode == .session, isQuotaPaused { return .refused }
        let units = Self.units(events)
        let libVersion = self.libVersion
        var parts: [[Data]] = []
        var oversized = 0
        var snapshotDropped = false
        let reserved = reserve { sessionId, distinctId in
            let overhead = Self.envelopeBytes(ReplayChunkHeader(
                sessionId: sessionId, distinctId: distinctId, seq: ReplaySessionState.maxSeq,
                mode: mode, lib: Self.lib, libVersion: libVersion))
            parts = Self.parts(units: units, overhead: overhead) { isSnapshot in
                oversized += 1
                if isSnapshot { snapshotDropped = true }
            }
            return parts.count
        }
        guard let context = reserved else {
            ReplayLog.log("replay chunk of a session whose next seq is unknown, dropped")
            noteDropped()
            return .refused
        }
        if oversized > 0 { noteDropped(oversized) }
        if !parts.isEmpty {
            afterAdmitHook?()
            queue.async { self.write(parts: parts, mode: mode, context: context) }
        }
        if snapshotDropped { return .snapshotDropped }
        return parts.isEmpty && oversized > 0 ? .refused : .queued
    }

    /// Chunks (or single events) dropped after they were handed to the queue
    /// and before the server took them: a refused 4xx, a 413 on a single
    /// event, an event over the chunk limit, the disk cap, a failed write, a
    /// quota refusal. The recorder sends a full snapshot when it changes,
    /// since the server may lack the one its next Mutation builds on.
    var droppedChunks: Int {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return droppedCount
    }

    private func noteDropped(_ count: Int = 1) {
        flagsLock.lock()
        droppedCount &+= count
        flagsLock.unlock()
    }

    /// Sends what can go now; returns once nothing more can (queue empty,
    /// backing off, or stopped).
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.pump { continuation.resume() } }
        }
    }

    /// Runs `completion` on the queue once every write handed to it before
    /// this call is done (the app going to the background).
    func afterPendingWrites(_ completion: @escaping () -> Void) {
        queue.async(execute: completion)
    }

    /// Opt-out: stops for good (until `start()`), deletes every queued chunk.
    func stopAndDiscard() {
        setHalted(true)
        queue.async { self.discard() }
    }

    /// Stops sending and returns once the queue has stopped, keeping the
    /// files (a later install sends them). Never call it on the queue.
    func shutdown() {
        setHalted(true)
        queue.sync { self.halt() }
    }

    var isQuotaPaused: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return ReplaySessionStore.ms(clock.now()) < quotaUntilMs
    }

    /// Stopped for this process by a 404.
    var isGoneNow: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return goneFlag
    }

    private var isAccepting: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return !haltedFlag && !goneFlag
    }

    private func setHalted(_ value: Bool) {
        flagsLock.lock()
        haltedFlag = value
        flagsLock.unlock()
    }

    // MARK: - Test accessors

    var pendingChunks: [Entry] { queue.sync { entries } }
    var isGone: Bool { queue.sync { gone } }
    var currentBackoffUntil: Date? { queue.sync { backoffUntil } }

    // MARK: - Queueing (on `queue`)

    private func write(parts: [[Data]], mode: ReplayChunkMode, context: ReplayChunkContext) {
        // Admitted but never written: the recorder must not build a
        // Mutation on what was in it.
        guard !stopped, !gone, !(mode == .session && isQuotaPaused) else {
            noteDropped(parts.count)
            return
        }
        let reservedEnd = context.firstSeq + parts.count
        var floor = context.firstSeq
        for (index, part) in parts.enumerated() {
            var seq = max(context.firstSeq + index, floor)
            if seq >= reservedEnd { seq = sessions.takeSeq(sessionId: context.sessionId, atLeast: seq) }
            seq = freeSeq(sessionId: context.sessionId, from: seq)
            floor = seq + 1
            let header = ReplayChunkHeader(sessionId: context.sessionId, distinctId: context.distinctId, seq: seq,
                                mode: mode, lib: Self.lib, libVersion: libVersion)
            guard let entry = writeChunk(Self.chunkJSON(header: header, events: part),
                                         sessionId: context.sessionId, seq: seq, mode: mode)
            else {
                noteDropped()
                continue
            }
            entries.append(entry)
        }
        enforceDiskCap()
        pump()
    }

    /// `seq`, or the next seq of the session whose file does not exist yet.
    private func freeSeq(sessionId: String, from seq: Int) -> Int {
        var seq = seq
        var tries = 0
        while FileManager.default.fileExists(atPath: fileURL(sessionId: sessionId, seq: seq).path), tries < 10_000 {
            seq = sessions.takeSeq(sessionId: sessionId, atLeast: seq + 1)
            tries += 1
        }
        return seq
    }

    /// Bytes of the chunk JSON with no event (`events: []`).
    static func envelopeBytes(_ header: ReplayChunkHeader) -> Int {
        chunkJSON(header: header, events: []).count
    }

    /// Encodes events with sorted keys: a Dictionary's order changes from
    /// one instance to the next, so without it the same events would give a
    /// different gzip size each time and the disk bound would not hold to
    /// the byte.
    static func eventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The encoded events in units a chunk boundary never cuts: a Meta
    /// (type 4) with the event after it (its Full snapshot), every other
    /// event alone.
    static func units(_ events: [ReplayJSON]) -> [[Data]] {
        let encoder = eventEncoder()
        var units: [[Data]] = []
        var index = 0
        while index < events.count {
            let size = ReplayEvents.isMeta(events[index]) && index + 1 < events.count ? 2 : 1
            let unit = events[index..<(index + size)].compactMap { try? encoder.encode($0) }
            if !unit.isEmpty { units.append(unit) }
            index += size
        }
        return units
    }

    /// Units grouped so no chunk holds more than `maxChunkEvents` events and
    /// no chunk JSON (`overhead` plus the events and their commas) is larger
    /// than `maxChunkBytes`. A unit that alone makes it larger is dropped
    /// whole (`onDrop`, true for a Meta + Full snapshot pair).
    static func parts(units: [[Data]], overhead: Int, onDrop: (_ isSnapshot: Bool) -> Void = { _ in }) -> [[Data]] {
        var parts: [[Data]] = []
        var part: [Data] = []
        var bytes = overhead
        for unit in units {
            let unitBytes = unit.reduce(0) { $0 + $1.count } + unit.count - 1
            if overhead + unitBytes > maxChunkBytes || unit.count > maxChunkEvents {
                ReplayLog.log("replay event over \(maxChunkBytes) bytes, dropped")
                onDrop(unit.count > 1)
                continue
            }
            let cost = unitBytes + (part.isEmpty ? 0 : 1)
            if !part.isEmpty, part.count + unit.count > maxChunkEvents || bytes + cost > maxChunkBytes {
                parts.append(part)
                part = []
                bytes = overhead
            }
            bytes += unitBytes + (part.isEmpty ? 0 : 1)
            part.append(contentsOf: unit)
        }
        if !part.isEmpty { parts.append(part) }
        return parts
    }

    /// The chunk JSON with the already encoded events spliced in, so they are
    /// never encoded twice.
    static func chunkJSON(header: ReplayChunkHeader, events: [Data]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var json = (try? encoder.encode(header)) ?? Data("{}".utf8)
        if json.last == UInt8(ascii: "}") { json.removeLast() }
        json.append(contentsOf: Array(#","events":["#.utf8))
        for (index, event) in events.enumerated() {
            if index > 0 { json.append(UInt8(ascii: ",")) }
            json.append(event)
        }
        json.append(contentsOf: Array("]}".utf8))
        return json
    }

    private func fileURL(sessionId: String, seq: Int) -> URL {
        root.appendingPathComponent(sessionId, isDirectory: true).appendingPathComponent("\(seq)\(Self.fileSuffix)")
    }

    /// Gzips and writes one chunk (a split replaces its original this way).
    /// nil on any failure: disk full must never take the app down.
    private func writeChunk(_ json: Data, sessionId: String, seq: Int, mode: ReplayChunkMode?) -> Entry? {
        let url = fileURL(sessionId: sessionId, seq: seq)
        do {
            let gzipped = try json.cohorlyGzipped()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeFile(gzipped, url)
            sessions.pin(sessionId: sessionId)
            return Entry(sessionId: sessionId, seq: seq, url: url, bytes: gzipped.count, mode: mode)
        } catch {
            ReplayLog.log("replay chunk could not be written: \(error)")
            return nil
        }
    }

    /// Drops the oldest chunks (never the one in flight) while the queue is
    /// over `maxDiskBytes`. Only a file really removed frees its bytes.
    private func enforceDiskCap() {
        var total = entries.reduce(0) { $0 + $1.bytes }
        var index = 0
        while total > maxDiskBytes, index < entries.count {
            let victim = entries[index]
            guard victim.url != inFlight, deleteFile(victim) else {
                index += 1
                continue
            }
            entries.remove(at: index)
            total -= victim.bytes
            noteDropped()
            ReplayLog.log("replay queue over \(maxDiskBytes) bytes, dropped the oldest chunk")
        }
    }

    private func remove(_ entry: Entry) {
        entries.removeAll { $0.url == entry.url }
        deleteFile(entry)
    }

    /// True when the file is gone (removed now or already missing).
    @discardableResult
    private func deleteFile(_ entry: Entry) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: entry.url)
        } catch {
            if fileManager.fileExists(atPath: entry.url.path) { return false }
        }
        let dir = entry.url.deletingLastPathComponent()
        let left = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        if left.isEmpty {
            try? fileManager.removeItem(at: dir)
            sessions.forget(sessionId: entry.sessionId)
        }
        return true
    }

    /// Chunks a previous launch left, oldest first. A file or directory whose
    /// name is not a valid session id / seq is deleted; each session's next
    /// seq is moved past its highest file.
    private func load() {
        let fileManager = FileManager.default
        guard let dirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var found: [(date: Date, entry: Entry)] = []
        for dir in dirs {
            let sessionId = dir.lastPathComponent
            guard ReplaySessionId.isValid(sessionId) else {
                try? fileManager.removeItem(at: dir)
                continue
            }
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            var maxSeq = -1
            for file in files {
                guard let seq = Self.seq(fromFileName: file.lastPathComponent) else {
                    try? fileManager.removeItem(at: file)
                    continue
                }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                found.append((values?.contentModificationDate ?? .distantPast,
                              Entry(sessionId: sessionId, seq: seq, url: file, bytes: values?.fileSize ?? 0, mode: nil)))
                maxSeq = max(maxSeq, seq)
            }
            if maxSeq < 0 {
                try? fileManager.removeItem(at: dir)
            } else {
                sessions.reconcile(sessionId: sessionId, next: maxSeq + 1)
            }
        }
        entries = found.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.entry.sessionId != rhs.entry.sessionId { return lhs.entry.sessionId < rhs.entry.sessionId }
            return lhs.entry.seq < rhs.entry.seq
        }.map { $0.entry }
        enforceDiskCap()
    }

    /// `<seq>.json.gz` with `seq` in `0...maxSeq`, digits only.
    static func seq(fromFileName name: String) -> Int? {
        guard name.hasSuffix(fileSuffix) else { return nil }
        let digits = name.dropLast(fileSuffix.count)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let seq = Int(digits), (0...ReplaySessionState.maxSeq).contains(seq)
        else { return nil }
        return seq
    }

    private func readBody(_ entry: Entry) -> ReplayChunkBody? {
        guard let data = try? Data(contentsOf: entry.url), let json = try? data.cohorlyGunzipped() else { return nil }
        return try? JSONDecoder().decode(ReplayChunkBody.self, from: json)
    }

    private func mode(of entry: Entry) -> ReplayChunkMode? {
        entry.mode ?? readBody(entry)?.mode
    }

    // MARK: - Sending (on `queue`)

    private func halt() {
        stopped = true
        epoch &+= 1
        inFlight = nil
        retryWork?.cancel()
        retryWork = nil
        finishIdle()
    }

    private func discard() {
        halt()
        entries = []
        // Nothing left to retry: an opt-in starts with a clean slate.
        failures = 0
        backoffUntil = nil
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            // The persisted opt-out deletes it again on the next install.
            if FileManager.default.fileExists(atPath: root.path) {
                ReplayLog.log("replay queue could not be deleted: \(error)")
            }
        }
    }

    private func finishIdle() {
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0() }
    }

    private func pump(completion: (() -> Void)? = nil) {
        if let completion { idleWaiters.append(completion) }
        guard inFlight == nil else { return }
        guard !stopped, !gone, let entry = entries.first else {
            finishIdle()
            return
        }
        if let until = backoffUntil, clock.now() < until {
            scheduleRetry(at: until)
            finishIdle()
            return
        }
        guard let body = try? Data(contentsOf: entry.url) else {
            entries.removeFirst()
            deleteFile(entry)
            noteDropped()
            pump()
            return
        }
        inFlight = entry.url
        let epoch = self.epoch
        let transport = self.transport
        let endpoint = self.endpoint
        let hook = beforeSendHook
        let headers = [
            "Content-Type": "application/json",
            "Content-Encoding": "gzip",
            "X-Cohorly-Token": token
        ]
        Task { [weak self] in
            hook?()
            // Checked on the queue right before the request: a halt (opt-out,
            // reinstall) that ran since this task was created sends nothing.
            guard let self, await self.isCurrent(epoch) else { return }
            let outcome: Outcome
            do {
                outcome = Self.classify(try await transport.send(url: endpoint, headers: headers, body: body))
            } catch {
                outcome = .retry(retryAfter: nil)
            }
            self.queue.async {
                guard epoch == self.epoch else { return }
                self.inFlight = nil
                self.handle(entry, outcome)
                self.pump()
            }
        }
    }

    private func isCurrent(_ epoch: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { continuation.resume(returning: epoch == self.epoch && !self.stopped && !self.gone) }
        }
    }

    static func classify(_ response: ReplayHTTPResponse) -> Outcome {
        switch response.status {
        case 200..<300:
            return .ok
        case 429:
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            if object?["error"] as? String == quotaError { return .quota(retryAfter: response.retryAfter) }
            return .retry(retryAfter: response.retryAfter)
        case 413:
            return .split
        case 401:
            return .retryAtMax
        case 404:
            return .gone
        case 408, 500...:
            return .retry(retryAfter: response.retryAfter)
        default:
            return .drop
        }
    }

    private func handle(_ entry: Entry, _ outcome: Outcome) {
        guard entries.contains(where: { $0.url == entry.url }) else { return }
        switch outcome {
        case .ok:
            remove(entry)
            failures = 0
            backoffUntil = nil
        case .drop:
            ReplayLog.log("replay chunk refused (4xx), dropped")
            remove(entry)
            noteDropped()
        case .gone:
            ReplayLog.log("replay endpoint not found (404), session replay stopped for this launch")
            gone = true
            retryWork?.cancel()
            retryWork = nil
            flagsLock.lock(); goneFlag = true; flagsLock.unlock()
            Self.processLock.lock(); Self.processGone = true; Self.processLock.unlock()
        case .split:
            split(entry)
        case .quota(let retryAfter):
            let refusedMode = mode(of: entry)
            remove(entry)
            noteDropped()
            if refusedMode == .session {
                for other in entries where other.sessionId == entry.sessionId && mode(of: other) == .session {
                    remove(other)
                    noteDropped()
                }
            }
            pauseSessionMode(for: retryAfter ?? Self.defaultQuotaPause)
        case .retry(let retryAfter):
            backOff(retryAfter: retryAfter)
        case .retryAtMax:
            failures += 1
            backoffUntil = clock.now().addingTimeInterval(backoff.maxDelay)
        }
    }

    private func backOff(retryAfter: TimeInterval?) {
        failures += 1
        backoffUntil = clock.now().addingTimeInterval(
            backoff.delay(failures: failures, retryAfter: retryAfter, random: random))
    }

    /// Two chunks with half the events each, never cut between a Meta and
    /// its Full snapshot. The second half is written first, under a new seq
    /// of the same session; only then is the original replaced by the first
    /// half (same seq). A failed write leaves the original as it was and
    /// retries it later. A single event, or a lone Meta + Full snapshot
    /// pair, is dropped.
    private func split(_ entry: Entry) {
        guard let body = readBody(entry), entries.contains(where: { $0.url == entry.url }),
              let half = Self.splitPoint(body.events)
        else {
            ReplayLog.log("replay chunk with a single event is too large (413), dropped")
            remove(entry)
            noteDropped()
            return
        }
        let encoder = Self.eventEncoder()
        let first = body.events[..<half].compactMap { try? encoder.encode($0) }
        let second = body.events[half...].compactMap { try? encoder.encode($0) }
        let onDisk = entries.filter { $0.sessionId == entry.sessionId }.map(\.seq).max() ?? entry.seq
        let secondSeq = freeSeq(
            sessionId: entry.sessionId,
            from: sessions.takeSeq(sessionId: entry.sessionId, atLeast: max(onDisk, entry.seq) + 1))
        var header = ReplayChunkHeader(sessionId: body.sessionId, distinctId: body.distinctId, seq: secondSeq,
                            mode: body.mode, lib: body.lib, libVersion: body.libVersion)
        guard let secondEntry = writeChunk(Self.chunkJSON(header: header, events: second),
                                           sessionId: entry.sessionId, seq: secondSeq, mode: body.mode)
        else {
            backOff(retryAfter: nil)
            return
        }
        header.seq = body.seq
        guard let firstEntry = writeChunk(Self.chunkJSON(header: header, events: first),
                                          sessionId: entry.sessionId, seq: entry.seq, mode: body.mode)
        else {
            // The original is intact: drop the second half so no event goes twice.
            try? FileManager.default.removeItem(at: secondEntry.url)
            backOff(retryAfter: nil)
            return
        }
        guard let index = entries.firstIndex(where: { $0.url == entry.url }) else { return }
        entries[index] = firstEntry
        entries.insert(secondEntry, at: index + 1)
        enforceDiskCap()
    }

    /// Where a 413 cuts `events`: about the middle, moved off a point that
    /// would separate a Meta from the event after it; nil when no point is
    /// allowed.
    static func splitPoint(_ events: [ReplayJSON]) -> Int? {
        guard events.count >= 2 else { return nil }
        let middle = (events.count + 1) / 2
        func allowed(_ point: Int) -> Bool {
            point > 0 && point < events.count && !ReplayEvents.isMeta(events[point - 1])
        }
        for candidate in [middle, middle + 1, middle - 1] where allowed(candidate) { return candidate }
        return (1..<events.count).first(where: allowed)
    }

    private func pauseSessionMode(for seconds: TimeInterval) {
        let until = ReplaySessionStore.ms(clock.now().addingTimeInterval(seconds))
        flagsLock.lock()
        quotaUntilMs = until
        flagsLock.unlock()
        storage.setString(String(until), forKey: quotaStorageKey)
    }

    private func scheduleRetry(at until: Date) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.pump()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + max(0, until.timeIntervalSince(clock.now())), execute: work)
    }
}

/// The chunk fields other than `events` (docs/SESSION-REPLAY.md section 2).
struct ReplayChunkHeader: Encodable {
    var sessionId: String
    var distinctId: String
    var seq: Int
    var mode: ReplayChunkMode
    var lib: String
    var libVersion: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case distinctId = "distinct_id"
        case seq
        case mode
        case lib
        case libVersion = "lib_version"
    }
}
