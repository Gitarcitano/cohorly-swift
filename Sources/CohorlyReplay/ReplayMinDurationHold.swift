import Foundation

/// Keeps a `session` mode recording in memory until it is `minDurationMs`
/// long (the last event's timestamp minus the first's), then hands
/// everything held to the queue in order (VEL-2234, same rule as the web
/// SDK). A recording that never gets there sends nothing and takes no seq.
/// Past `maxHeldBytes` held it is sent anyway. The minimum duration is the
/// one the chunk's own session was decided with: a session that ended
/// (rotated out) short drops what it held and every later chunk of it, and
/// a chunk of the live session drops what any other session still held.
/// `error` mode never goes through here.
final class ReplayMinDurationHold: @unchecked Sendable {
    static let maxHeldBytes = 5 * 1024 * 1024
    /// Ended sessions remembered as dropped, oldest forgotten first.
    static let maxDropped = 50

    struct Chunk: Equatable {
        var events: [ReplayJSON]
        var distinctId: String
    }

    /// What the session store knows of a chunk's session.
    struct Session: Equatable {
        /// The minimum duration it was decided with.
        var minDurationMs: Int64
        /// It took a seq already (it sent a chunk, or a relaunch continues
        /// it), so it is not held again.
        var alreadySent: Bool
        /// Rotated out: no later chunk can make it longer.
        var ended: Bool
    }

    enum Outcome: Equatable {
        /// Send this chunk now (no hold, or the hold is over).
        case pass
        /// Kept in memory.
        case held
        /// The hold is over: send these, in order (this chunk last).
        case release([Chunk])
        /// The session ended short: nothing of it is sent.
        case drop
    }

    private struct State {
        var minDurationMs: Int64
        var reached: Bool
        var held: [Chunk] = []
        var firstTimestamp: Int64?
        var lastTimestamp: Int64?
        var bytes = 0
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var dropped: [String] = []

    func admit(_ events: [ReplayJSON], sessionId: String, distinctId: String, session: Session) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if dropped.contains(sessionId) { return .drop }
        if !session.ended {
            for (id, state) in states where id != sessionId {
                states[id] = nil
                if !state.reached { remember(dropped: id) }
            }
        }
        var current = states[sessionId] ?? State(
            minDurationMs: session.minDurationMs, reached: session.minDurationMs <= 0 || session.alreadySent)
        guard !current.reached else {
            states[sessionId] = current
            return .pass
        }
        current.held.append(Chunk(events: events, distinctId: distinctId))
        current.bytes += Self.bytes(events)
        for event in events {
            guard let timestamp = Self.timestamp(event) else { continue }
            current.firstTimestamp = min(current.firstTimestamp ?? timestamp, timestamp)
            current.lastTimestamp = max(current.lastTimestamp ?? timestamp, timestamp)
        }
        let duration = (current.lastTimestamp ?? 0).subtractingReportingOverflow(current.firstTimestamp ?? 0)
        let longEnough = !duration.overflow && duration.partialValue >= current.minDurationMs
        if longEnough || current.bytes > Self.maxHeldBytes {
            let held = current.held
            current.held = []
            current.bytes = 0
            current.reached = true
            states[sessionId] = current
            return .release(held)
        }
        if session.ended {
            states[sessionId] = nil
            remember(dropped: sessionId)
            return .drop
        }
        states[sessionId] = current
        return .held
    }

    /// Drops what is held (opt-out, stop).
    func discard() {
        lock.lock()
        states = [:]
        dropped = []
        lock.unlock()
    }

    /// Must hold `lock`.
    private func remember(dropped id: String) {
        dropped.append(id)
        if dropped.count > Self.maxDropped { dropped.removeFirst(dropped.count - Self.maxDropped) }
    }

    private static func timestamp(_ event: ReplayJSON) -> Int64? {
        guard case .object(let object) = event else { return nil }
        switch object["timestamp"] {
        case .int(let value)?: return Int64(value)
        case .double(let value)? where value.isFinite && abs(value) < 9e15: return Int64(value)
        default: return nil
        }
    }

    private static func bytes(_ events: [ReplayJSON]) -> Int {
        let encoder = JSONEncoder()
        return events.reduce(0) { total, event in total + ((try? encoder.encode(event))?.count ?? 0) }
    }
}
