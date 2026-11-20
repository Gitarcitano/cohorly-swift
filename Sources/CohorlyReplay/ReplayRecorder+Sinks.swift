import Foundation

/// The Swift SDK's sinks: the recorder (Recorder/, shared with the React
/// Native pod) takes a sink factory; this is the one `ReplayRuntime` gives it.
extension ReplayRecorder {
    /// A recorder whose sinks are `defaultSink` (or `sinkFor`, when given).
    ///
    /// - Parameters:
    ///   - chunkMaxAge: the default session sink's chunk age.
    ///   - sinkFor: the sink of each mode; nil uses `defaultSink`.
    convenience init(
        host: ReplayRecorderHost,
        source: ReplaySnapshotSource,
        touchSource: ReplayTouchSource?,
        observesRunLoop: Bool = true,
        worker: DispatchQueue = DispatchQueue(label: "com.cohorly.replay.recorder"),
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping ReplayThrottle.Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        chunkMaxAge: TimeInterval = ReplayChunkBuffer.defaultMaxAge,
        sinkFor: ReplaySinkFactory? = nil,
        beginBackgroundTask: @escaping ReplayBackgroundTaskStarter = ReplayRecorder.systemBackgroundTask
    ) {
        let factory: ReplaySinkFactory = sinkFor ?? { mode, context in
            ReplayRecorder.defaultSink(mode: mode, context: context, maxAge: chunkMaxAge)
        }
        self.init(
            host: host, source: source, touchSource: touchSource, observesRunLoop: observesRunLoop,
            worker: worker, monotonicNow: monotonicNow, schedule: schedule, sinks: factory,
            beginBackgroundTask: beginBackgroundTask)
    }

    /// The sinks of this version: `.session` chunks events for the queue on
    /// disk; `.error` keeps them in memory until an error (`ReplayErrorBuffer`).
    static func defaultSink(
        mode: ReplayMode, context: ReplaySinkContext, maxAge: TimeInterval = ReplayChunkBuffer.defaultMaxAge
    ) -> ReplayEventSink? {
        if mode == .error {
            let buffer = ReplayErrorBuffer(
                schedule: context.schedule,
                deliver: { events, sessionId, distinctId, generation in
                    context.deliver(events, .error, sessionId, distinctId, generation)
                },
                requestFullSnapshot: context.requestFullSnapshot,
                now: context.nowMs)
            buffer.onAdmission = context.report
            return buffer
        }
        guard mode == .session else { return nil }
        let buffer = ReplayChunkBuffer(
            schedule: context.schedule,
            deliver: { events, sessionId, distinctId, generation in
                context.deliver(events, .session, sessionId, distinctId, generation)
            },
            maxAge: maxAge)
        buffer.onAdmission = context.report
        return buffer
    }
}
