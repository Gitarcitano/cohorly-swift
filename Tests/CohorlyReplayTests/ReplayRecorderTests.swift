import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

final class FakeRecorderHost: ReplayRecorderHost {
    struct Enqueued {
        var events: [ReplayJSON]
        var mode: ReplayChunkMode
        var sessionId: String
        var distinctId: String
    }

    private let lock = NSLock()
    private var _state = ReplayRecordingState(mode: .session, sessionId: "session-a", distinctId: "user-1")
    /// Read on the recorder's worker too.
    var state: ReplayRecordingState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }
    var droppedChunks = 0
    var nowMs: Int64 = 1_800_000_000_000
    var admission = ReplayAdmission.queued
    private var _enqueued: [Enqueued] = []
    private var _activities = 0

    var enqueued: [Enqueued] {
        lock.lock(); defer { lock.unlock() }
        return _enqueued
    }

    var activities: Int {
        lock.lock(); defer { lock.unlock() }
        return _activities
    }

    func recordingState() -> ReplayRecordingState { state }

    func enqueueRecorded(_ events: [ReplayJSON], mode: ReplayChunkMode, sessionId: String, distinctId: String) -> ReplayAdmission {
        lock.lock(); defer { lock.unlock() }
        _enqueued.append(Enqueued(events: events, mode: mode, sessionId: sessionId, distinctId: distinctId))
        return admission
    }

    func noteActivity() {
        lock.lock(); _activities += 1; lock.unlock()
    }

    func afterPendingWrites(_ completion: @escaping () -> Void) { completion() }
}

final class FakeSnapshotSource: ReplaySnapshotSource {
    var frame: ReplaySourceFrame? = ReplaySourceFrame(
        windowKey: 1, width: 390, height: 844, href: "FormViewController", wireframes: sampleScreen())
    var foreground = true
    var fingerprint = 1
    var onCapture: (() -> Void)?
    private(set) var captures = 0

    func isInForeground() -> Bool { foreground }

    func captureFrame() -> ReplaySourceFrame? {
        captures += 1
        onCapture?()
        return frame
    }

    func structureFingerprint() -> Int? { fingerprint }
}

final class FakeTouchSource: ReplayTouchSource {
    private(set) var handler: (([ReplayRawTouch]) -> Void)?
    func start(_ handler: @escaping ([ReplayRawTouch]) -> Void) { self.handler = handler }
    func stop() { handler = nil }
    func send(_ touches: [ReplayRawTouch]) { handler?(touches) }
}

/// Counts background tasks begun and ended.
final class FakeBackgroundTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var _begun = 0
    private var _ended = 0
    var begun: Int { lock.lock(); defer { lock.unlock() }; return _begun }
    var ended: Int { lock.lock(); defer { lock.unlock() }; return _ended }

    var starter: ReplayBackgroundTaskStarter {
        { [self] _ in
            lock.lock(); _begun += 1; lock.unlock()
            return { [self] in lock.lock(); _ended += 1; lock.unlock() }
        }
    }
}

/// A sink that keeps every group it gets.
final class RecordingSink: ReplayEventSink {
    var groups: [[ReplayJSON]] = []
    var flushes = 0
    func add(_ group: [ReplayJSON], sessionId: String, distinctId: String, generation: UInt64) { groups.append(group) }
    func flush() { flushes += 1 }
    func discard() { groups = [] }
}

/// The recorder with fakes around it, driven from the test (main) thread:
/// the throttle runs when `scheduler` is advanced, the worker is drained by
/// hand (or suspended to hold a capture between the main thread and it).
final class ReplayRecorderTests: XCTestCase {
    private var host: FakeRecorderHost!
    private var source: FakeSnapshotSource!
    private var touches: FakeTouchSource!
    private var scheduler: ManualScheduler!
    private var tasks: FakeBackgroundTasks!
    private var worker: DispatchQueue!
    private var recorder: ReplayRecorder!

    override func setUp() {
        super.setUp()
        host = FakeRecorderHost()
        source = FakeSnapshotSource()
        touches = FakeTouchSource()
        scheduler = ManualScheduler()
        tasks = FakeBackgroundTasks()
        worker = DispatchQueue(label: "test.replay.recorder")
        recorder = makeRecorder()
    }

    override func tearDown() {
        recorder.stop()
        recorder = nil
        super.tearDown()
    }

    private func makeRecorder(sinkFor: ReplaySinkFactory? = nil) -> ReplayRecorder {
        let scheduler = self.scheduler!
        return ReplayRecorder(
            host: host, source: source, touchSource: touches, observesRunLoop: false, worker: worker,
            monotonicNow: { scheduler.now }, schedule: scheduler.schedule, chunkMaxAge: 3600,
            sinkFor: sinkFor, beginBackgroundTask: tasks.starter)
    }

    /// Lets the throttle fire and the worker finish.
    private func settle(_ seconds: TimeInterval = 0) {
        scheduler.advance(by: seconds)
        recorder.drainWorker()
    }

    /// What the buffer held, delivered now (the app going to the background).
    private func flushed() -> [FakeRecorderHost.Enqueued] {
        recorder.didEnterBackground()
        recorder.drainWorker()
        recorder.willEnterForeground()
        return host.enqueued
    }

    private func json(_ events: [ReplayJSON]) throws -> String {
        String(bytes: try JSONEncoder().encode(events), encoding: .utf8) ?? ""
    }

    private func touchData(_ events: [ReplayJSON]) throws -> [[String: Any]] {
        try events.filter { ReplayEvents.type(of: $0) == 3 }.map { try XCTUnwrap(try jsonObject($0)["data"] as? [String: Any]) }
    }

    func testStartCapturesAFullSnapshotIntoOneSessionChunk() {
        recorder.start()
        settle()
        XCTAssertEqual(source.captures, 1)
        let chunks = flushed()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].mode, .session)
        XCTAssertEqual(chunks[0].sessionId, "session-a")
        XCTAssertEqual(chunks[0].distinctId, "user-1")
        XCTAssertEqual(eventTypes(chunks[0].events), [4, 2])
    }

    /// A recorder whose factory gives only session mode a sink.
    private func makeSessionOnlyRecorder() -> ReplayRecorder {
        makeRecorder { mode, context in
            mode == .session ? ReplayRecorder.defaultSink(mode: mode, context: context, maxAge: 3600) : nil
        }
    }

    func testOnlyModesWithASinkAreRecorded() {
        recorder.stop()
        recorder = makeSessionOnlyRecorder()
        for mode in [ReplayMode.error, .off] {
            host.state.mode = mode
            recorder.start()
            settle()
            recorder.requestCapture(full: true)
            settle(2)
            XCTAssertEqual(source.captures, 0, "\(mode)")
        }
        // Back to session mode: the first capture is full.
        host.state.mode = .session
        recorder.requestCapture(full: false)
        settle(2)
        XCTAssertEqual(eventTypes(flushed().flatMap(\.events)), [4, 2])
    }

    func testTheSinkFactoryIsAskedPerModeAndAnErrorSinkRecordsInErrorMode() throws {
        recorder.stop()
        var asked: [ReplayMode] = []
        let errorSink = RecordingSink()
        recorder = makeRecorder { mode, _ in
            asked.append(mode)
            return mode == .error ? errorSink : nil
        }
        XCTAssertEqual(asked, [.session, .error])
        host.state.mode = .error
        recorder.start()
        settle()
        XCTAssertEqual(errorSink.groups.map(eventTypes), [[4, 2]])
        host.state.mode = .session
        recorder.requestCapture(full: true)
        settle(2)
        XCTAssertEqual(source.captures, 1, "session mode has no sink in this recorder")

        // The default factory: a chunk buffer for session mode, the error buffer for error mode.
        let context = ReplaySinkContext(schedule: { _, _ in }, deliver: { _, _, _, _, _ in .queued }, report: { _, _ in })
        XCTAssertTrue(ReplayRecorder.defaultSink(mode: .session, context: context) is ReplayChunkBuffer)
        XCTAssertTrue(ReplayRecorder.defaultSink(mode: .error, context: context) is ReplayErrorBuffer)
        XCTAssertNil(ReplayRecorder.defaultSink(mode: .off, context: context))
    }

    func testRequestsAreThrottledToOneCapturePerSecond() {
        recorder.start()
        settle()
        for _ in 0..<10 {
            recorder.requestCapture(full: false)
            settle(0.125)
        }
        // 1.25 s after the first capture: one more, at 1 s.
        XCTAssertEqual(source.captures, 2)
    }

    func testAStillScreenIsCapturedOneOneOneTwoFourEightEightSecondsApartAndSendsNothing() {
        var times: [TimeInterval] = []
        source.onCapture = { [unowned self] in times.append(self.scheduler.now) }
        recorder.start()
        settle()
        // An opportunity every 0.25 s for 26 s, on a screen that never changes.
        for _ in 0..<104 {
            recorder.requestCapture(full: false)
            settle(0.25)
        }
        XCTAssertEqual(zip(times, times.dropFirst()).map { $1 - $0 }, [1, 1, 1, 2, 4, 8, 8])
        XCTAssertEqual(eventTypes(flushed().flatMap(\.events)), [4, 2], "no Mutation for an unchanged screen")
    }

    func testATouchThroughTheRecorderBringsTheCadenceBackToOneSecond() {
        var times: [TimeInterval] = []
        source.onCapture = { [unowned self] in times.append(self.scheduler.now) }
        recorder.start()
        settle()
        for _ in 0..<48 { // up to 12 s: backed off, last capture at 9 s, next due at 17 s
            recorder.requestCapture(full: false)
            settle(0.25)
        }
        XCTAssertEqual(times.last, 1009)
        touches.send([ReplayRawTouch(kind: .start, x: 5, y: 5)])
        settle(1)
        XCTAssertEqual(times.last, 1013)
    }

    func testARefusedCaptureRearmsOnlyUntilTheMaximumIdleIntervalAfterTheLastRequest() {
        var times: [TimeInterval] = []
        source.onCapture = { [unowned self] in times.append(self.scheduler.now) }
        recorder.start()
        settle()
        for _ in 0..<40 { // requests up to 9.75 s
            recorder.requestCapture(full: false)
            settle(0.25)
        }
        // Silence: no request, nothing on screen.
        for _ in 0..<120 { settle(0.25) }
        XCTAssertEqual(scheduler.pendingCount, 0, "no wake-up left")
        XCTAssertLessThanOrEqual(times.last ?? 0, 1009.75 + ReplayCaptureBackoff.maxIdleInterval)
        XCTAssertEqual(times.last, 1017, "the last request still got its capture")
    }

    func testAChangedScreenIsAMutationAndAnActivity() {
        recorder.start()
        settle()
        let before = host.activities
        source.frame?.wireframes = sampleScreen(label: "Changed")
        recorder.requestCapture(full: false)
        settle(1)
        XCTAssertEqual(host.activities, before + 1)
        XCTAssertEqual(eventTypes(flushed().flatMap(\.events)), [4, 2, 3])
    }

    func testTouchesBeforeTheFirstFullSnapshotFollowItInOrder() throws {
        recorder.start()
        // Touches before the first capture ran.
        touches.send([ReplayRawTouch(kind: .start, x: 10.4, y: 20.6), ReplayRawTouch(kind: .end, x: 30, y: 41)])
        recorder.drainWorker()
        XCTAssertTrue(host.enqueued.isEmpty)
        XCTAssertEqual(host.activities, 1)
        settle()
        let events = flushed().flatMap(\.events)
        XCTAssertEqual(eventTypes(events), [4, 2, 3, 3])
        let data = try touchData(events)
        XCTAssertEqual(data.map { $0["type"] as? Int }, [7, 9])
        XCTAssertEqual(data.map { $0["x"] as? Int }, [10, 30])
        XCTAssertEqual(data.map { $0["y"] as? Int }, [21, 41])
    }

    func testATouchOutsideARecordedModeIsIgnored() {
        recorder.stop()
        recorder = makeSessionOnlyRecorder()
        recorder.start()
        settle()
        host.state.mode = .error
        touches.send([ReplayRawTouch(kind: .start, x: 1, y: 1)])
        recorder.drainWorker()
        host.state.mode = .session
        XCTAssertEqual(eventTypes(flushed().flatMap(\.events)), [4, 2])
    }

    func testOnlyTouchesOfTheRecordedWindowAreKept() throws {
        recorder.start()
        settle() // records window 1
        touches.send([ReplayRawTouch(kind: .start, x: 1, y: 1, windowKey: 2)])
        touches.send([ReplayRawTouch(kind: .start, x: 7, y: 7, windowKey: 1)])
        recorder.drainWorker()
        let events = flushed().flatMap(\.events)
        XCTAssertEqual(eventTypes(events), [4, 2, 3])
        XCTAssertEqual(try touchData(events).map { $0["x"] as? Int }, [7])
    }

    func testARotationKeepsTheOldSessionsEventsUnderItsId() {
        recorder.start()
        settle()
        host.state.sessionId = "session-b"
        recorder.requestCapture(full: false)
        settle(1)
        let chunks = flushed()
        XCTAssertEqual(chunks.map(\.sessionId), ["session-a", "session-b"])
        XCTAssertEqual(chunks.map { eventTypes($0.events) }, [[4, 2], [4, 2]])
    }

    func testARotationDeliversTheOldSessionsBufferAtOnce() {
        recorder.start()
        settle()
        host.state.sessionId = "session-b"
        recorder.sessionDidRotate()
        recorder.drainWorker()
        // No background, no 10 s: the rotation alone delivered it.
        XCTAssertEqual(host.enqueued.map(\.sessionId), ["session-a"])
        settle(1)
        XCTAssertEqual(flushed().map(\.sessionId), ["session-a", "session-b"])
    }

    func testLeavingSessionModeDeliversTheBufferAtOnce() {
        recorder.start()
        settle()
        host.state.mode = .error
        recorder.requestCapture(full: false)
        recorder.drainWorker()
        XCTAssertEqual(host.enqueued.map { eventTypes($0.events) }, [[4, 2]])
    }

    func testTheReturnFromBackgroundIsAFullSnapshot() {
        recorder.start()
        settle()
        _ = flushed() // background + foreground
        settle(1)
        let after = host.enqueued.count
        recorder.didEnterBackground()
        recorder.drainWorker()
        XCTAssertEqual(eventTypes(host.enqueued[after...].flatMap(\.events)), [4, 2])
    }

    func testNothingIsCapturedInTheBackground() {
        recorder.start()
        settle()
        recorder.didEnterBackground()
        recorder.requestCapture(full: true)
        settle(5)
        XCTAssertEqual(source.captures, 1)
    }

    func testAFrameAdmittedBeforeTheBackgroundIsDeliveredUnderABackgroundTask() {
        recorder.start()
        settle()
        worker.suspend()
        source.frame?.wireframes = sampleScreen(label: "Changed")
        recorder.requestCapture(full: false)
        scheduler.advance(by: 1) // read on the main thread, not yet on the worker
        XCTAssertEqual(source.captures, 2)
        recorder.didEnterBackground()
        XCTAssertEqual(tasks.begun, 1)
        XCTAssertEqual(tasks.ended, 0)
        worker.resume()
        recorder.drainWorker()
        XCTAssertEqual(eventTypes(host.enqueued.flatMap(\.events)), [4, 2, 3])
        XCTAssertEqual(tasks.ended, 1, "ended once the chunks were written")
    }

    func testOptOutDropsWaitingTouchesAndOptInStartsWhole() {
        recorder.start()
        // A touch waiting for the first full snapshot.
        touches.send([ReplayRawTouch(kind: .start, x: 1, y: 1)])
        recorder.drainWorker()
        recorder.setPaused(true)
        recorder.drainWorker()
        XCTAssertNil(touches.handler, "touches are no longer followed")
        settle(5)
        XCTAssertEqual(source.captures, 0, "nothing captured while opted out")

        // Same session after the opt-in: the waiting touch would follow its
        // snapshot had it been kept.
        recorder.setPaused(false)
        settle(1)
        let chunks = flushed()
        XCTAssertEqual(chunks.map(\.sessionId), ["session-a"])
        XCTAssertEqual(eventTypes(chunks[0].events), [4, 2], "the waiting touch was dropped")
    }

    func testAFrameCapturedBeforeAnOptOutAndAdmittedAfterTheOptInNeverReachesTheQueue() throws {
        recorder.start()
        worker.suspend()
        source.frame?.wireframes = sampleScreen(label: "Before opt-out")
        scheduler.advance(by: 0) // captured on the main thread, held before the worker
        XCTAssertEqual(source.captures, 1)
        recorder.setPaused(true)
        recorder.setPaused(false)
        source.frame?.wireframes = sampleScreen(label: "After opt-in")
        worker.resume()
        settle(1)
        let all = try json(flushed().flatMap(\.events))
        XCTAssertFalse(all.contains("Before opt-out"))
        XCTAssertTrue(all.contains("After opt-in"))
    }

    func testABufferFlushedAfterAnOptOutAndOptInIsRefused() {
        recorder.start()
        settle() // a full snapshot in the buffer
        worker.suspend()
        recorder.sessionDidRotate() // its flush waits on the worker
        recorder.setPaused(true)
        recorder.setPaused(false)
        worker.resume()
        recorder.drainWorker()
        XCTAssertTrue(host.enqueued.isEmpty, "the generation it was captured in is gone")
    }

    func testADroppedChunkSeenOnTheWorkerMakesTheNextCaptureFull() {
        recorder.start()
        settle()
        worker.suspend()
        source.frame?.wireframes = sampleScreen(label: "Changed")
        recorder.requestCapture(full: false)
        scheduler.advance(by: 1) // read on the main thread with nothing dropped
        host.droppedChunks = 1 // the queue drops a chunk before the worker admits it
        worker.resume()
        recorder.drainWorker()
        XCTAssertEqual(eventTypes(flushed().flatMap(\.events)), [4, 2, 4, 2])
    }

    func testStopRemovesTriggersAndQueuesNothingAfterwards() {
        recorder.start()
        settle()
        recorder.stop()
        XCTAssertNil(touches.handler)
        recorder.requestCapture(full: true)
        recorder.didEnterBackground()
        settle(5)
        XCTAssertTrue(host.enqueued.isEmpty)
        XCTAssertEqual(source.captures, 1)
    }

    func testUninstallStopsTheRecorder() throws {
        ReplayChunkQueue.resetProcessGone()
        let harness = ReplayHarness()
        let installSource = FakeSnapshotSource()
        let installTouches = FakeTouchSource()
        let installScheduler = ManualScheduler()
        var built: ReplayRecorder?
        var environment = harness.environment
        environment.makeRecorder = { runtime in
            let recorder = ReplayRecorder(
                host: runtime, source: installSource, touchSource: installTouches, observesRunLoop: false,
                monotonicNow: { installScheduler.now }, schedule: installScheduler.schedule, chunkMaxAge: 3600,
                beginBackgroundTask: { _ in {} })
            built = recorder
            return recorder
        }
        let cohorly = harness.makeCohorly()
        XCTAssertNotNil(CohorlyReplay.install(cohorly: cohorly, config: CohorlyReplayConfig(sampleRate: 1), environment: environment))
        installScheduler.advance(by: 0)
        built?.drainWorker()
        XCTAssertEqual(installSource.captures, 1)
        XCTAssertNotNil(installTouches.handler)

        CohorlyReplay.uninstall()
        XCTAssertFalse(CohorlyReplay.isInstalled)
        XCTAssertNil(installTouches.handler, "touches are no longer followed")
        built?.requestCapture(full: true)
        installScheduler.advance(by: 5)
        XCTAssertEqual(installSource.captures, 1, "nothing captured after the uninstall")
    }
}
