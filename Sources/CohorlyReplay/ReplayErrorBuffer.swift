import Cohorly
import Foundation

/// The sink of error mode (`onErrorSampleRate`, or a session-mode session
/// during the quota pause): the rules of `@cohorly/web`'s `pushToBuffer` /
/// `sendErrorBuffer` and of Android's `ErrorBuffer` (docs/SESSION-REPLAY.md
/// section 2). The session's recent events stay in memory and only an error
/// (`errorOccurred`) sends them: `flush()` sends nothing, so a session that
/// never errs never leaves the device, not on background, rotation or a
/// change of mode either.
///
/// The buffer is a list of segments. Each starts at a Meta event (the start
/// of a full snapshot) and holds every event after it until the next Meta.
/// Its leading Meta and FullSnapshot are screen state (`lead`); anything
/// else (a Mutation, a touch) is activity. An event with no segment open is
/// dropped (unusable on its own) and asks for a checkout.
///
/// A send (`cut`) always starts at a Meta + FullSnapshot, covers at least
/// `minWindowMs` when the recording is that old, never holds activity older
/// than `windowMs`, and ends now with a Custom `error` event, so the player
/// shows the moment of the error. A segment that began before the window
/// with no activity before it (a still screen) is still the screen at the
/// window's start: its state events go stamped there. While there is
/// activity, a full snapshot is asked for every `checkoutEveryMs`, so such a
/// start exists. Two sends are at least `sendGapMs` apart: an error inside
/// that gap waits and goes with the next send (never lost, never twice).
///
/// An error of a session with no snapshot in the buffer yet (before the
/// first capture, or an `$exception` that rotated the session) waits for
/// that session's first Meta and goes then; one waiting for another session
/// is dropped once the buffer moves on to a third.
///
/// Memory is bounded by `maxBytes` of event JSON: the oldest segments go
/// whole first, never the current one; a single segment over the bound asks
/// for a checkout instead.
///
/// Not thread-safe: the recorder's serial queue only (`schedule` runs on
/// it). Nothing is written from a crash handler (docs/SESSION-REPLAY.md
/// "iOS error buffer").
final class ReplayErrorBuffer: ReplayEventSink {
    typealias Schedule = ReplayChunkBuffer.Schedule
    typealias Deliver = ReplayChunkBuffer.Deliver

    /// No activity older than this before the error is ever sent.
    static let windowMs: Int64 = 60_000
    /// A send covers at least this much when the recording is that old.
    static let minWindowMs: Int64 = 30_000
    /// A full snapshot is asked for this often while there is activity.
    static let checkoutEveryMs: Int64 = 30_000
    /// Minimum time between two sends.
    static let sendGapMs: Int64 = 5_000
    static let defaultMaxBytes = 5 * 1024 * 1024
    /// Tag of the Custom event that closes every send, at the moment of the error.
    static let errorTag = "error"

    private struct Segment {
        var start: Int64
        var events: [ReplayJSON] = []
        /// How many leading events are screen state (Meta, FullSnapshot).
        var lead = 0
        /// Timestamp of the first activity event, nil while there is none.
        var firstActivity: Int64?
        var bytes = 0
    }

    private struct Owner: Equatable {
        var sessionId: String
        var distinctId: String
        var generation: UInt64
    }

    private let schedule: Schedule
    private let deliver: Deliver
    private let requestFullSnapshot: () -> Void
    private let now: () -> Int64
    private let maxBytes: Int
    private let encoder = JSONEncoder()

    private var owner: Owner?
    private var segments: [Segment] = []
    private(set) var bytes = 0
    /// Activity buffered since the last segment started.
    private var dirtySinceCheckout = false
    /// Activity buffered since the last send (true at first: a still screen
    /// is worth one send).
    private var dirtySinceSend = true
    /// A new segment is needed now: one went over `maxBytes`, or activity
    /// came with none open.
    private var needsCheckout = false
    /// A full snapshot was asked for and has not arrived.
    private var checkoutRequested = false
    /// The `data` of the last full snapshot buffered: another one is a screen
    /// change, so something a send must carry.
    private var lastFullSnapshot: ReplayJSON?
    /// When the last send happened. Kept across sessions, like the web SDK.
    private var lastSendAt: Int64?
    /// The session a delayed send is armed for.
    private var scheduledSend: String?
    /// The session whose send waits for its next full snapshot.
    private var retryOnSnapshot: String?
    /// An error of a session the buffer holds no snapshot of: sent at that
    /// session's first Meta. Survives `reset`, which that Meta may cause.
    private var pendingError: String?
    private var checkoutTimerArmed = false
    /// Bumped by `discard`: timers armed before do nothing.
    private var timerGeneration: UInt64 = 0

    /// Called after a delivery that was not `.queued`, with its session.
    var onAdmission: ((ReplayAdmission, String) -> Void)?

    /// - Parameters:
    ///   - requestFullSnapshot: asks the recorder for a Meta + FullSnapshot.
    ///   - now: unix ms, the clock of the events' timestamps.
    init(
        schedule: @escaping Schedule, deliver: @escaping Deliver, requestFullSnapshot: @escaping () -> Void,
        now: @escaping () -> Int64, maxBytes: Int = ReplayErrorBuffer.defaultMaxBytes
    ) {
        self.schedule = schedule
        self.deliver = deliver
        self.requestFullSnapshot = requestFullSnapshot
        self.now = now
        self.maxBytes = maxBytes
    }

    /// The session the buffered events belong to.
    var sessionId: String? { owner?.sessionId }

    var segmentCount: Int { segments.count }

    // MARK: - ReplayEventSink

    func add(_ group: [ReplayJSON], sessionId: String, distinctId: String, generation: UInt64) {
        guard !group.isEmpty else { return }
        if owner?.sessionId != sessionId, let pending = pendingError, pending != sessionId {
            // The buffer moves on to a session other than the one waiting.
            pendingError = nil
        }
        if let owner, owner.sessionId != sessionId || owner.generation != generation {
            // Another session's buffer is useless to this one; another
            // generation means an opt-out or pause came between.
            reset()
        }
        // The latest distinct id: the error belongs to whoever is identified now.
        owner = Owner(sessionId: sessionId, distinctId: distinctId, generation: generation)
        let startsSnapshot = group.first.map(ReplayEvents.isMeta) ?? false
        if startsSnapshot { checkoutRequested = false }
        for event in group { push(event) }
        enforceBound()
        armCheckoutTimer()
        requestCheckoutIfDue()
        if startsSnapshot, let waiting = retryOnSnapshot, waiting == sessionId {
            retryOnSnapshot = nil
            send(sessionId)
        }
        if startsSnapshot, pendingError == sessionId {
            pendingError = nil
            errorOccurred(sessionId: sessionId)
        }
    }

    /// Sends nothing: only an error does.
    func flush() {}

    func discard() {
        reset()
        pendingError = nil
        timerGeneration &+= 1
        checkoutTimerArmed = false
        scheduledSend = nil
    }

    /// Sends the buffer now, or once `sendGapMs` after the previous send is
    /// over; an error while a send is armed goes with it. An error of a
    /// session the buffer holds nothing of waits for its first snapshot.
    func errorOccurred(sessionId: String) {
        errorOccurred(sessionId: sessionId, distinctId: nil)
    }

    func errorOccurred(sessionId: String, distinctId: String?) {
        if let distinctId, owner?.sessionId == sessionId { owner?.distinctId = distinctId }
        guard owner?.sessionId == sessionId else {
            pendingError = sessionId
            requestFullSnapshot()
            return
        }
        if scheduledSend != nil {
            scheduledSend = sessionId
            return
        }
        let wait = nextSendDelayMs()
        guard wait > 0 else {
            send(sessionId)
            return
        }
        scheduledSend = sessionId
        let armed = timerGeneration
        schedule(TimeInterval(wait) / 1000) { [weak self] in
            guard let self, armed == self.timerGeneration, let target = self.scheduledSend else { return }
            self.scheduledSend = nil
            self.send(target)
        }
    }

    // MARK: - Rules

    /// True when a full snapshot is due: activity since the last segment
    /// began at least `checkoutEveryMs` ago, or `needsCheckout`. Never true
    /// without activity.
    func checkoutDue() -> Bool {
        if needsCheckout { return true }
        guard let last = segments.last else { return false }
        return dirtySinceCheckout && now() - last.start >= Self.checkoutEveryMs
    }

    /// Ms until a send may happen after the previous one; 0 = now.
    func nextSendDelayMs() -> Int64 {
        guard let last = lastSendAt else { return 0 }
        return max(0, last + Self.sendGapMs - now())
    }

    /// The events an error now sends, or nil when `sessionId` is not the
    /// buffered session, nothing was buffered since the last send, or no
    /// segment can start it (a checkout is then asked for). It starts at the
    /// newest segment that began at least `minWindowMs` ago when that one is
    /// usable (began inside the window, or had no activity before it), else
    /// at the oldest segment that began less than `minWindowMs` ago. A cut
    /// empties the buffer and starts the send gap; it ignores the gap itself.
    func cut(sessionId: String) -> [ReplayJSON]? {
        guard sessionId == owner?.sessionId, dirtySinceSend else { return nil }
        let current = now()
        let cutoff = current - Self.windowMs
        let target = current - Self.minWindowMs
        func usable(_ segment: Segment) -> Bool {
            segment.start >= cutoff || (segment.firstActivity.map { $0 >= cutoff } ?? true)
        }
        var first = segments.lastIndex { $0.start <= target }
        if let index = first, !usable(segments[index]) { first = nil }
        if first == nil { first = segments.firstIndex { $0.start > target } }
        guard let start = first else {
            needsCheckout = true
            return nil
        }
        var out: [ReplayJSON] = []
        for (index, segment) in segments.enumerated() where index >= start {
            guard index == start, segment.start < cutoff else {
                out.append(contentsOf: segment.events)
                continue
            }
            for (position, event) in segment.events.enumerated() {
                let timestamp = ReplayEvents.timestamp(of: event) ?? cutoff
                if position < segment.lead {
                    // A still screen: its snapshot is the screen at the cutoff.
                    out.append(ReplayEvents.restamped(event, at: max(timestamp, cutoff)))
                } else if timestamp >= cutoff {
                    // Out-of-order activity from before the cutoff never goes.
                    out.append(event)
                }
            }
        }
        // The recording ends at the error, not at the last change before it.
        out.append(ReplayEvents.custom(tag: Self.errorTag, timestamp: current))
        segments = []
        bytes = 0
        dirtySinceSend = false
        dirtySinceCheckout = false
        needsCheckout = false
        lastSendAt = current
        return out
    }

    // MARK: - Private

    private func send(_ sessionId: String) {
        guard let owner, owner.sessionId == sessionId else { return }
        guard let events = cut(sessionId: sessionId) else {
            // No snapshot to start from yet: the send waits for the one asked for.
            if checkoutDue() { retryOnSnapshot = sessionId }
            requestCheckoutIfDue()
            return
        }
        let admission = deliver(events, owner.sessionId, owner.distinctId, owner.generation)
        switch admission {
        case .queued:
            break
        case .refused:
            ReplayLog.log("session replay dropped an error buffer of \(events.count) events (session ended, opted out or paused)")
        case .snapshotDropped:
            ReplayLog.log("session replay dropped a full snapshot of an error buffer over the chunk limit")
        }
        if admission != .queued { onAdmission?(admission, owner.sessionId) }
        // Empty now: buffering goes on from a new full snapshot.
        checkoutRequested = true
        requestFullSnapshot()
    }

    private func push(_ event: ReplayJSON) {
        let size = (try? encoder.encode(event).count) ?? 0
        let type = ReplayEvents.type(of: event)
        let current = now()
        let timestamp = ReplayEvents.timestamp(of: event) ?? current
        if type == ReplayEvents.EventType.meta.rawValue {
            segments.append(Segment(start: timestamp, events: [event], lead: 1, firstActivity: nil, bytes: size))
            bytes += size
            dirtySinceCheckout = false
            needsCheckout = false
            // A cut starts at the newest segment at least `minWindowMs` old,
            // or a later one: nothing before the newest such one can go again.
            if let anchor = segments.lastIndex(where: { $0.start <= current - Self.minWindowMs }), anchor > 0 {
                dropOldest(anchor)
            }
            return
        }
        guard !segments.isEmpty else {
            if type != ReplayEvents.EventType.fullSnapshot.rawValue { needsCheckout = true }
            return
        }
        let last = segments.count - 1
        segments[last].events.append(event)
        segments[last].bytes += size
        bytes += size
        let isState = type == ReplayEvents.EventType.fullSnapshot.rawValue
        if isState, segments[last].firstActivity == nil {
            segments[last].lead += 1
            let data = Self.data(of: event)
            if lastFullSnapshot != nil, data != lastFullSnapshot { dirtySinceSend = true }
            lastFullSnapshot = data
        } else if !isState {
            if segments[last].firstActivity == nil { segments[last].firstActivity = timestamp }
            dirtySinceCheckout = true
            dirtySinceSend = true
        }
    }

    private func enforceBound() {
        guard bytes > maxBytes else { return }
        if segments.count > 1 {
            var drop = 0
            var left = bytes
            while drop < segments.count - 1, left > maxBytes {
                left -= segments[drop].bytes
                drop += 1
            }
            dropOldest(drop)
        }
        // One segment over the bound: a checkout starts a new one, the old one then goes.
        if bytes > maxBytes { needsCheckout = true }
    }

    private func dropOldest(_ count: Int) {
        for segment in segments.prefix(count) { bytes -= segment.bytes }
        segments.removeFirst(count)
    }

    private func requestCheckoutIfDue() {
        guard !checkoutRequested, checkoutDue() else { return }
        checkoutRequested = true
        requestFullSnapshot()
    }

    /// Every `checkoutEveryMs` while something is buffered.
    private func armCheckoutTimer() {
        guard !checkoutTimerArmed, !segments.isEmpty else { return }
        checkoutTimerArmed = true
        let armed = timerGeneration
        schedule(TimeInterval(Self.checkoutEveryMs) / 1000) { [weak self] in
            guard let self, armed == self.timerGeneration else { return }
            self.checkoutTimerArmed = false
            self.requestCheckoutIfDue()
            self.armCheckoutTimer()
        }
    }

    private func reset() {
        owner = nil
        segments = []
        bytes = 0
        dirtySinceCheckout = false
        dirtySinceSend = true
        needsCheckout = false
        checkoutRequested = false
        lastFullSnapshot = nil
        retryOnSnapshot = nil
    }

    private static func data(of event: ReplayJSON) -> ReplayJSON? {
        guard case .object(let object) = event else { return nil }
        return object["data"]
    }
}
