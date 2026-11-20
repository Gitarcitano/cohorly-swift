import Cohorly
import Foundation

/// The persisted record of a replay session (docs/SESSION-REPLAY.md section
/// 1). Times are unix ms from the SDK clock.
struct ReplaySessionState: Codable, Equatable, Sendable {
    var id: String
    var startedAt: Int64
    var lastActivityAt: Int64
    /// When the app last went to the background; nil while in the foreground.
    var lastBackgroundAt: Int64?
    var mode: ReplayMode
    /// The next chunk seq to use.
    var seq: Int
    /// Born while the remote settings were still loading (VEL-2234): `$session_id`
    /// is stamped, but nothing is recorded (`mode` is `.off`) until the
    /// settings decide it. A record written before this field is decided.
    var pending = false
    /// The recording is sent only once it is this long (`session` mode,
    /// 0 = at once). Fixed at birth; a record written before this field has 0.
    var minDurationMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case lastActivityAt = "last_activity_at"
        case lastBackgroundAt = "last_background_at"
        case mode
        case seq
        case pending
        case minDurationMs = "min_duration_ms"
    }

    static let maxSeq = 1_000_000_000
    /// A stored time more than this far ahead of the clock is corrupt.
    static let maxClockSkewMs: Int64 = 24 * 60 * 60 * 1000

    /// A record a relaunch may continue: a valid id, a seq in
    /// `0...maxSeq`, no negative time, none more than a day ahead of `nowMs`,
    /// and `startedAt <= lastActivityAt`.
    func isValid(nowMs: Int64) -> Bool {
        let latest = nowMs.addingReportingOverflow(Self.maxClockSkewMs)
        let limit = latest.overflow ? Int64.max : latest.partialValue
        func ok(_ time: Int64) -> Bool { time >= 0 && time <= limit }
        return ReplaySessionId.isValid(id)
            && (0...Self.maxSeq).contains(seq)
            && ok(startedAt) && ok(lastActivityAt) && (lastBackgroundAt.map(ok) ?? true)
            && startedAt <= lastActivityAt
    }
}

extension ReplaySessionState {
    /// Records persisted before VEL-2234 have no `pending` or
    /// `min_duration_ms`: decided, no minimum duration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startedAt = try container.decode(Int64.self, forKey: .startedAt)
        lastActivityAt = try container.decode(Int64.self, forKey: .lastActivityAt)
        lastBackgroundAt = try container.decodeIfPresent(Int64.self, forKey: .lastBackgroundAt)
        mode = try container.decode(ReplayMode.self, forKey: .mode)
        seq = try container.decode(Int.self, forKey: .seq)
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        let minDuration = try container.decodeIfPresent(Int64.self, forKey: .minDurationMs) ?? 0
        minDurationMs = min(max(0, minDuration), ReplayRemoteConfigLoader.maxMinDurationMs)
        if pending { mode = .off }
    }
}

enum ReplaySessionId {
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// `^[A-Za-z0-9_-]{1,64}$`, the server's rule for `session_id`.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { allowed.contains($0) }
    }

    /// 32 hex characters (a UUID without its hyphens).
    static func mint() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

/// What a chunk is stamped with, read in one step when it is queued.
struct ReplayChunkContext: Equatable, Sendable {
    var sessionId: String
    var distinctId: String
    /// Seq of the first part; the next parts take the following ones.
    var firstSeq: Int
}

/// Owns `$session_id`: the live session, its sampling decision and its next
/// chunk seq, persisted in the SDK's `CohorlyStorage` (keys suffixed by the
/// project namespace) so a relaunch continues it. Guarded by a lock, never a
/// queue: `Cohorly.track()` reads it from the SDK queue, the recorder from
/// its thread and the chunk queue from its own, and none may wait on the
/// other. No callback ever runs under the lock.
///
/// Rotation: on return to the foreground after 30 min or more in the
/// background, or on an activity in the foreground (a `track()`, a recorded
/// touch or screen change) once the session is 24 h old or 30 min passed
/// since the last activity. Never while in the background. `rotate()` (from
/// `reset()` and opt-in) rotates at once.
final class ReplaySessionStore: @unchecked Sendable {
    static let idleTimeout: TimeInterval = 30 * 60
    static let maxDuration: TimeInterval = 24 * 60 * 60
    /// `lastActivityAt` is persisted at most this often on `track()`.
    static let activityWriteInterval: TimeInterval = 5
    /// Retired sessions remembered (least recently used dropped first),
    /// with their next seq whether or not they still have chunks on disk;
    /// one with chunks on disk is kept past it until they are gone.
    static let maxRetired = 50

    static func storageKey(_ namespace: String) -> String { "cohorly.replay.session.\(namespace)" }
    /// Next seq of sessions rotated out whose chunks may still be on disk.
    static func retiredKey(_ namespace: String) -> String { "cohorly.replay.retired.\(namespace)" }

    private let lock = NSLock()
    private let storage: CohorlyStorage
    private let clock: CohorlyClock
    private let decider: ReplaySessionDeciding
    private let sessionStorageKey: String
    private let retiredStorageKey: String
    private var current: ReplaySessionState
    private var retired: [RetiredSession]
    /// Sessions with chunks on disk (set by the chunk queue): never trimmed.
    private var pinned: Set<String> = []
    private var inBackground = false
    private var lastActivityWrite: Int64 = .min
    private var currentDistinctIdValue = ""
    /// Bumped by every identity write: the initial snapshot of install never
    /// overwrites a change a notification applied after it was read.
    private var identityVersion: UInt64 = 0
    /// Bumped by every rotation; a publication carries it.
    private var generation: UInt64 = 0
    /// After `close()` nothing is written (a newer install owns the keys).
    private var closed = false

    /// Called after every rotation with the new session and its generation,
    /// never under the lock (a newer generation may arrive first). Set once
    /// before the store is shared.
    var onRotate: ((ReplaySessionState, UInt64) -> Void)?

    private struct RetiredSession: Codable {
        var id: String
        var seq: Int
        /// The minimum duration it was decided with; nil for one retired
        /// before it was recorded, or known only from its chunks on disk.
        var minDurationMs: Int64?
    }

    /// A store whose new sessions are decided by `decideMode` alone, never
    /// pending, with no minimum duration.
    convenience init(storage: CohorlyStorage, clock: CohorlyClock, namespace: String, decideMode: @escaping () -> ReplayMode) {
        self.init(storage: storage, clock: clock, namespace: namespace, decider: ClosureSessionDecider(decideMode))
    }

    init(storage: CohorlyStorage, clock: CohorlyClock, namespace: String, decider: ReplaySessionDeciding) {
        self.storage = storage
        self.clock = clock
        self.decider = decider
        let sessionStorageKey = Self.storageKey(namespace)
        let retiredStorageKey = Self.retiredKey(namespace)
        self.sessionStorageKey = sessionStorageKey
        self.retiredStorageKey = retiredStorageKey
        retired = (Self.decode([RetiredSession].self, storage.string(forKey: retiredStorageKey)) ?? [])
            .filter { ReplaySessionId.isValid($0.id) && (0...ReplaySessionState.maxSeq).contains($0.seq) }
        let now = Self.ms(clock.now())
        if let stored = Self.decode(ReplaySessionState.self, storage.string(forKey: sessionStorageKey)),
           stored.isValid(nowMs: now) {
            current = stored
            // A relaunch is a return to the foreground; a process that died in
            // the foreground has no background time, only its last activity.
            let idleSince = stored.lastBackgroundAt ?? stored.lastActivityAt
            if Self.reached(now, since: stored.startedAt, Self.maxDuration)
                || Self.reached(now, since: idleSince, Self.idleTimeout) {
                retire(stored)
                current = Self.mint(now: now, decision: decider.decideNewSession())
            } else {
                current.lastBackgroundAt = nil
                current.lastActivityAt = max(now, stored.lastActivityAt)
            }
        } else {
            current = Self.mint(now: now, decision: decider.decideNewSession())
        }
        write()
    }

    var session: ReplaySessionState {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The live session and its generation, read together.
    var snapshot: (session: ReplaySessionState, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (current, generation)
    }

    /// The distinct id chunks queued now carry.
    var distinctId: String {
        lock.lock()
        defer { lock.unlock() }
        return currentDistinctIdValue
    }

    func setDistinctId(_ id: String) {
        lock.lock()
        currentDistinctIdValue = id
        identityVersion &+= 1
        lock.unlock()
    }

    var currentIdentityVersion: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return identityVersion
    }

    /// Applies `id` only when no identity write happened since `version`.
    func setDistinctId(_ id: String, ifUnchangedSince version: UInt64) {
        lock.lock()
        if identityVersion == version {
            currentDistinctIdValue = id
            identityVersion &+= 1
        }
        lock.unlock()
    }

    /// The id to stamp on an event tracked now (an activity: see
    /// `noteActivity()`).
    func sessionIdForEvent() -> String {
        noteActivity()
    }

    /// An activity of the user (a `track()`, a recorded touch or screen
    /// change): in the foreground, rotates first when the session is 24 h
    /// old or idle for 30 min, then records the activity. Returns the live
    /// session's id.
    @discardableResult
    func noteActivity() -> String {
        lock.lock()
        let now = Self.ms(clock.now())
        if !inBackground,
           Self.reached(now, since: current.startedAt, Self.maxDuration)
            || Self.reached(now, since: current.lastActivityAt, Self.idleTimeout) {
            let (session, generation) = rotateLocked(now: now)
            lock.unlock()
            publish(session, generation)
            return session.id
        }
        current.lastActivityAt = max(current.lastActivityAt, now)
        if Self.reached(now, since: lastActivityWrite, Self.activityWriteInterval) { write() }
        let id = current.id
        lock.unlock()
        return id
    }

    func didEnterBackground() {
        lock.lock()
        defer { lock.unlock() }
        let now = Self.ms(clock.now())
        inBackground = true
        current.lastBackgroundAt = now
        current.lastActivityAt = max(current.lastActivityAt, now)
        write()
    }

    func willEnterForeground() {
        lock.lock()
        let now = Self.ms(clock.now())
        inBackground = false
        let idle = current.lastBackgroundAt.map { Self.reached(now, since: $0, Self.idleTimeout) } ?? false
        if idle || Self.reached(now, since: current.startedAt, Self.maxDuration) {
            let (session, generation) = rotateLocked(now: now)
            lock.unlock()
            publish(session, generation)
            return
        }
        current.lastBackgroundAt = nil
        current.lastActivityAt = max(current.lastActivityAt, now)
        write()
        lock.unlock()
    }

    /// A new session with its own sampling decision. `distinctId`, when
    /// given, is the identity chunks of the new session carry (set in the
    /// same step, so no chunk pairs the new session with the old user).
    @discardableResult
    func rotate(distinctId: String? = nil) -> ReplaySessionState {
        lock.lock()
        if let distinctId {
            currentDistinctIdValue = distinctId
            identityVersion &+= 1
        }
        let (session, generation) = rotateLocked(now: Self.ms(clock.now()))
        lock.unlock()
        publish(session, generation)
        return session
    }

    /// Session, distinct id and consecutive seqs of the live session, in
    /// one step (a chunk queued before a rotation keeps the old session and
    /// user, one queued after gets the new ones). `count` gets the session
    /// and distinct id and returns how many seqs to take; it runs under the
    /// lock, so it must not call back into the store.
    func reserve(_ count: (_ sessionId: String, _ distinctId: String) -> Int) -> ReplayChunkContext {
        lock.lock()
        defer { lock.unlock() }
        let first = current.seq
        let taken = count(current.id, currentDistinctIdValue)
        if taken > 0 {
            current.seq = Self.advance(first, by: taken)
            write()
        }
        return ReplayChunkContext(sessionId: current.id, distinctId: currentDistinctIdValue, firstSeq: first)
    }

    /// Like `reserve(_:)`, for a session named by the caller: the live one or
    /// one already rotated out (the recorder's buffer of a session that ended
    /// while it was filling). The chunk keeps `sessionId` and `distinctId`
    /// whatever rotated since, so events of one session never go out under
    /// another's id. nil (nothing taken, `count` not called) for a session
    /// that is neither live nor remembered as retired: its next seq is
    /// unknown, and guessing could reuse a seq the server already has.
    func reserve(
        sessionId: String, distinctId: String, _ count: (_ sessionId: String, _ distinctId: String) -> Int
    ) -> ReplayChunkContext? {
        lock.lock()
        defer { lock.unlock() }
        if sessionId == current.id {
            let taken = count(sessionId, distinctId)
            let first = current.seq
            if taken > 0 {
                current.seq = Self.advance(first, by: taken)
                write()
            }
            return ReplayChunkContext(sessionId: sessionId, distinctId: distinctId, firstSeq: first)
        }
        guard let found = retired.firstIndex(where: { $0.id == sessionId }) else { return nil }
        let index = touchRetired(at: found)
        let taken = count(sessionId, distinctId)
        let first = retired[index].seq
        if taken > 0 {
            retired[index].seq = Self.advance(first, by: taken)
            writeRetired()
        }
        return ReplayChunkContext(sessionId: sessionId, distinctId: distinctId, firstSeq: first)
    }

    /// The live session and the distinct id its chunks carry, read together
    /// (a `reset()` changes both in one step).
    var live: (session: ReplaySessionState, distinctId: String) {
        lock.lock()
        defer { lock.unlock() }
        return (current, currentDistinctIdValue)
    }

    /// Takes the next chunk seq of `sessionId`, at least `atLeast` and at
    /// most `maxSeq`: the live session's (persisted, so a relaunch continues
    /// it) or a retired one's.
    func takeSeq(sessionId: String, atLeast: Int = 0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if sessionId == current.id {
            let seq = min(max(current.seq, atLeast), ReplaySessionState.maxSeq)
            current.seq = Self.advance(seq, by: 1)
            write()
            return seq
        }
        let index = retired.firstIndex { $0.id == sessionId }.map(touchRetired(at:))
        let seq = min(max(index.map { retired[$0].seq } ?? 0, atLeast), ReplaySessionState.maxSeq)
        if let index {
            retired[index].seq = Self.advance(seq, by: 1)
        } else {
            retired.append(RetiredSession(id: sessionId, seq: Self.advance(seq, by: 1)))
            trimRetired()
        }
        writeRetired()
        return seq
    }

    /// The next seq of `sessionId` becomes at least `next` (chunks found on
    /// disk at launch), and the session is pinned while they are there.
    func reconcile(sessionId: String, next: Int) {
        lock.lock()
        defer { lock.unlock() }
        pinned.insert(sessionId)
        if sessionId == current.id {
            if current.seq < next {
                current.seq = min(next, ReplaySessionState.maxSeq)
                write()
            }
            return
        }
        if let index = retired.firstIndex(where: { $0.id == sessionId }) {
            guard retired[index].seq < next else { return }
            retired[index].seq = min(next, ReplaySessionState.maxSeq)
        } else {
            retired.append(RetiredSession(id: sessionId, seq: min(next, ReplaySessionState.maxSeq)))
            trimRetired()
        }
        writeRetired()
    }

    /// `sessionId` has a chunk on disk.
    func pin(sessionId: String) {
        lock.lock()
        pinned.insert(sessionId)
        lock.unlock()
    }

    /// `sessionId` has no chunk left on disk: it is no longer pinned. A
    /// retired one keeps its next seq (a late buffer of it still continues
    /// after its last chunk); only the size cap forgets it.
    func forget(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        pinned.remove(sessionId)
        let before = retired.count
        trimRetired()
        if retired.count != before { writeRetired() }
    }

    /// What the minimum duration hold needs of `sessionId`: the live session
    /// or one rotated out; nil for any other.
    func holdSession(_ sessionId: String) -> ReplayMinDurationHold.Session? {
        lock.lock()
        defer { lock.unlock() }
        if sessionId == current.id {
            return ReplayMinDurationHold.Session(
                minDurationMs: current.minDurationMs, alreadySent: current.seq > 0, ended: false)
        }
        guard let entry = retired.first(where: { $0.id == sessionId }) else { return nil }
        return ReplayMinDurationHold.Session(
            minDurationMs: entry.minDurationMs ?? 0, alreadySent: entry.seq > 0, ended: true)
    }

    /// Decides the live session when it is pending: `decide` (run under the
    /// lock, so it must not call back into the store; nil = not yet) gives
    /// its mode and minimum duration. Returns the session when it was decided
    /// now, nil otherwise (decided already, or `decide` gave nil).
    @discardableResult
    func settlePending(_ decide: () -> ReplaySessionDecision?) -> ReplaySessionState? {
        lock.lock()
        defer { lock.unlock() }
        guard current.pending, let decision = decide(), !decision.pending else { return nil }
        current.pending = false
        current.mode = decision.mode
        current.minDurationMs = decision.minDurationMs
        write()
        return current
    }

    /// Stops every write (the install is being replaced).
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    // MARK: - Locked helpers (must hold `lock`)

    private func rotateLocked(now: Int64) -> (ReplaySessionState, UInt64) {
        retire(current)
        current = Self.mint(now: now, decision: decider.decideNewSession())
        if inBackground { current.lastBackgroundAt = now }
        generation &+= 1
        write()
        return (current, generation)
    }

    private func publish(_ session: ReplaySessionState, _ generation: UInt64) {
        onRotate?(session, generation)
    }

    private func retire(_ session: ReplaySessionState) {
        retired.removeAll { $0.id == session.id }
        retired.append(RetiredSession(id: session.id, seq: session.seq, minDurationMs: session.minDurationMs))
        trimRetired()
        writeRetired()
    }

    /// Moves the retired session at `index` to the end (most recently used)
    /// and returns its new index.
    private func touchRetired(at index: Int) -> Int {
        let entry = retired.remove(at: index)
        retired.append(entry)
        return retired.count - 1
    }

    /// Drops the least recently used retired sessions past `maxRetired`,
    /// never one whose chunks are still on disk.
    private func trimRetired() {
        var excess = retired.count - Self.maxRetired
        guard excess > 0 else { return }
        retired.removeAll { session in
            guard excess > 0, !pinned.contains(session.id) else { return false }
            excess -= 1
            return true
        }
    }

    private func write() {
        guard !closed else { return }
        lastActivityWrite = Self.ms(clock.now())
        guard let data = try? JSONEncoder().encode(current), let raw = String(data: data, encoding: .utf8) else { return }
        storage.setString(raw, forKey: sessionStorageKey)
    }

    private func writeRetired() {
        guard !closed else { return }
        guard let data = try? JSONEncoder().encode(retired), let raw = String(data: data, encoding: .utf8) else { return }
        storage.setString(raw, forKey: retiredStorageKey)
    }

    // MARK: - Pure helpers

    private static func mint(now: Int64, decision: ReplaySessionDecision) -> ReplaySessionState {
        ReplaySessionState(
            id: ReplaySessionId.mint(), startedAt: now, lastActivityAt: now,
            lastBackgroundAt: nil, mode: decision.pending ? .off : decision.mode, seq: 0,
            pending: decision.pending, minDurationMs: decision.pending ? 0 : max(0, decision.minDurationMs))
    }

    /// `seq + count`, never past `maxSeq`.
    private static func advance(_ seq: Int, by count: Int) -> Int {
        let sum = seq.addingReportingOverflow(max(0, count))
        return sum.overflow ? ReplaySessionState.maxSeq : min(sum.partialValue, ReplaySessionState.maxSeq)
    }

    /// `now - since >= limit`, without overflow.
    private static func reached(_ now: Int64, since: Int64, _ limit: TimeInterval) -> Bool {
        let elapsed = now.subtractingReportingOverflow(since)
        if elapsed.overflow { return since < 0 }
        return elapsed.partialValue >= Int64(limit * 1000)
    }

    static func ms(_ date: Date) -> Int64 {
        ReplayUtil.millis(date)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// `ReplaySessionDeciding` over a closure of the mode alone.
private final class ClosureSessionDecider: ReplaySessionDeciding {
    private let decideMode: () -> ReplayMode
    init(_ decideMode: @escaping () -> ReplayMode) { self.decideMode = decideMode }
    func decideNewSession() -> ReplaySessionDecision { ReplaySessionDecision(mode: decideMode()) }
}

/// The sampling decision of a new session, once (same rule as the web SDK):
/// `random() < sampleRate` records the whole session; otherwise
/// `random() < onErrorSampleRate` keeps the error buffer; otherwise nothing.
func decideReplayMode(sampleRate: Double, onErrorSampleRate: Double, random: () -> Double) -> ReplayMode {
    if sampleRate > 0, random() < sampleRate { return .session }
    if onErrorSampleRate > 0, random() < onErrorSampleRate { return .error }
    return .off
}
