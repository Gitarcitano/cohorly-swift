import Foundation

/// The events recorded since the last chunk, all of one session, one
/// distinct id and one consent generation. Delivered as one chunk `maxAge`
/// after its first event, on `flush()`, before an event of another session,
/// distinct id or generation is added (a chunk never mixes them), and before
/// a group that would take it past `maxBytes` of JSON or `maxEvents` events
/// (a group bigger than that goes alone). A Meta and its FullSnapshot are
/// one group, so they always travel in the same chunk. Recorder queue only:
/// `schedule` runs on it.
final class ReplayChunkBuffer: ReplayEventSink {
    typealias Schedule = ReplaySchedule
    /// Queues a chunk; anything but `.queued` lost events.
    typealias Deliver = (_ events: [ReplayJSON], _ sessionId: String, _ distinctId: String, _ generation: UInt64) -> ReplayAdmission

    static let defaultMaxAge: TimeInterval = 10
    /// Below the queue's 1 MB per chunk, envelope included, so the queue
    /// never splits what the buffer grouped.
    static let defaultMaxBytes = 900_000
    static let defaultMaxEvents = ReplayChunkQueue.maxChunkEvents

    private let schedule: Schedule
    private let deliver: Deliver
    private let maxAge: TimeInterval
    private let maxBytes: Int
    private let maxEvents: Int
    private let encoder = JSONEncoder()

    private struct Owner: Equatable {
        var sessionId: String
        var distinctId: String
        var generation: UInt64
    }

    private var owner: Owner?
    private var events: [ReplayJSON] = []
    private var bytes = 0
    /// Bumped by every delivery or discard: a timer armed for an earlier
    /// chunk does nothing.
    private var timerGeneration: UInt64 = 0

    /// Called after a delivery that was not `.queued`, with its session.
    var onAdmission: ((ReplayAdmission, String) -> Void)?

    init(
        schedule: @escaping Schedule, deliver: @escaping Deliver,
        maxAge: TimeInterval = ReplayChunkBuffer.defaultMaxAge,
        maxBytes: Int = ReplayChunkBuffer.defaultMaxBytes,
        maxEvents: Int = ReplayChunkBuffer.defaultMaxEvents
    ) {
        self.schedule = schedule
        self.deliver = deliver
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        self.maxEvents = maxEvents
    }

    var count: Int { events.count }

    func add(_ group: [ReplayJSON], sessionId: String, distinctId: String, generation: UInt64) {
        guard !group.isEmpty else { return }
        if let owner, owner.sessionId != sessionId || owner.distinctId != distinctId || owner.generation != generation {
            flush()
        }
        // The JSON as the queue will write it (commas aside).
        let groupBytes = group.reduce(0) { $0 + ((try? encoder.encode($1).count) ?? 0) }
        if !events.isEmpty, bytes + groupBytes > maxBytes || events.count + group.count > maxEvents { flush() }
        owner = Owner(sessionId: sessionId, distinctId: distinctId, generation: generation)
        events.append(contentsOf: group)
        bytes += groupBytes
        if events.count == group.count {
            let armed = timerGeneration
            schedule(maxAge) { [weak self] in
                guard let self, armed == self.timerGeneration else { return }
                self.flush()
            }
        }
        if bytes >= maxBytes || events.count >= maxEvents { flush() }
    }

    func flush() {
        guard let owner, !events.isEmpty else { return }
        let chunk = events
        clear()
        let admission = deliver(chunk, owner.sessionId, owner.distinctId, owner.generation)
        switch admission {
        case .queued:
            return
        case .refused:
            ReplayLog.log("session replay dropped a chunk of \(chunk.count) events (session ended, opted out or paused)")
        case .snapshotDropped:
            ReplayLog.log("session replay dropped a full snapshot over the chunk limit; images go without pixels for this session")
        }
        onAdmission?(admission, owner.sessionId)
    }

    func discard() {
        clear()
    }

    private func clear() {
        events = []
        bytes = 0
        owner = nil
        timerGeneration &+= 1
    }
}
