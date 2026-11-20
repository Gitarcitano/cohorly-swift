import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// Error mode end to end: the recorder's default error sink, the error
/// signal (`noteError`), and the runtime's `$exception` observer and
/// `CohorlyReplay.notifyError()`.
final class ReplayErrorModeTests: XCTestCase {
    private var host: FakeRecorderHost!
    private var source: FakeSnapshotSource!
    private var scheduler: ManualScheduler!
    private var recorder: ReplayRecorder!

    override func setUp() {
        super.setUp()
        ReplayChunkQueue.resetProcessGone()
        host = FakeRecorderHost()
        host.state.mode = .error
        source = FakeSnapshotSource()
        scheduler = ManualScheduler()
        let scheduler = self.scheduler!
        recorder = ReplayRecorder(
            host: host, source: source, touchSource: FakeTouchSource(), observesRunLoop: false,
            worker: DispatchQueue(label: "test.replay.error"), monotonicNow: { scheduler.now },
            schedule: scheduler.schedule, chunkMaxAge: 3600, beginBackgroundTask: { _ in {} })
    }

    override func tearDown() {
        recorder.stop()
        recorder = nil
        CohorlyReplay.uninstall()
        ReplayChunkQueue.resetProcessGone()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0) {
        scheduler.advance(by: seconds)
        recorder.drainWorker()
    }

    // MARK: - Recorder

    func testAnErrorModeSessionRecordsButSendsNothingWithoutAnError() {
        recorder.start()
        settle()
        XCTAssertEqual(source.captures, 1, "error mode records")
        source.frame?.wireframes = sampleScreen(label: "Changed")
        recorder.requestCapture(full: false)
        settle(1)
        recorder.didEnterBackground()
        recorder.drainWorker()
        XCTAssertTrue(host.enqueued.isEmpty, "background and flush send nothing in error mode")
    }

    func testAnErrorSendsTheBufferInErrorModeFromAFullSnapshot() throws {
        recorder.start()
        settle()
        source.frame?.wireframes = sampleScreen(label: "Changed")
        recorder.requestCapture(full: false)
        settle(1)
        recorder.noteError()
        recorder.drainWorker()
        XCTAssertEqual(host.enqueued.count, 1)
        let sent = try XCTUnwrap(host.enqueued.first)
        XCTAssertEqual(sent.mode, .error)
        XCTAssertEqual(sent.sessionId, "session-a")
        XCTAssertEqual(sent.distinctId, "user-1")
        XCTAssertEqual(eventTypes(sent.events), [4, 2, 3, 5])
    }

    func testAnErrorInSessionModeSendsNothingExtra() {
        // The error buffer holds a recording before the session leaves error mode.
        recorder.start()
        settle()
        source.frame?.wireframes = sampleScreen(label: "Changed")
        recorder.requestCapture(full: false)
        settle(1)
        host.state.mode = .session
        recorder.requestCapture(full: false)
        settle(1)
        recorder.noteError()
        recorder.drainWorker()
        XCTAssertTrue(host.enqueued.filter { $0.mode == .error }.isEmpty, "session mode delivers on its own schedule")
    }

    /// Runs `body` on a background queue and waits for it.
    private func onBackgroundQueue(_ body: @escaping @Sendable () -> Void) {
        let done = expectation(description: "background call")
        DispatchQueue.global().async {
            body()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testAnErrorFromABackgroundQueueReachesTheErrorSinkOnlyInErrorMode() {
        recorder.stop()
        let errorSink = ErrorSignalSink()
        let scheduler = self.scheduler!
        recorder = ReplayRecorder(
            host: host, source: source, touchSource: FakeTouchSource(), observesRunLoop: false,
            worker: DispatchQueue(label: "test.replay.error.signal"), monotonicNow: { scheduler.now },
            schedule: scheduler.schedule,
            sinkFor: { mode, context in
                mode == .error ? errorSink as ReplayEventSink : ReplayRecorder.defaultSink(mode: mode, context: context)
            },
            beginBackgroundTask: { _ in {} })
        recorder.start()
        settle()
        let signaled = self.recorder!
        onBackgroundQueue { signaled.noteError() }
        signaled.drainWorker()
        XCTAssertEqual(errorSink.errors, ["session-a"], "nil is the live session")
        onBackgroundQueue { signaled.noteError(sessionId: "session-b") }
        signaled.drainWorker()
        XCTAssertEqual(errorSink.errors, ["session-a", "session-b"], "the stamped session wins")

        host.state.mode = .session
        onBackgroundQueue { signaled.noteError() }
        signaled.drainWorker()
        XCTAssertEqual(errorSink.errors.count, 2, "no error signal outside error mode")
    }

    func testAnErrorAfterStopOrOptOutSendsNothing() {
        recorder.start()
        settle()
        recorder.setPaused(true)
        recorder.noteError()
        recorder.drainWorker()
        recorder.stop()
        recorder.noteError()
        XCTAssertTrue(host.enqueued.isEmpty)
    }

    // MARK: - Runtime

    private struct Installed {
        let harness: ReplayHarness
        let cohorly: Cohorly
        let runtime: ReplayRuntime
        let recorder: ReplayRecorder
        let scheduler: ManualScheduler
        let source: FakeSnapshotSource
    }

    /// An install drawn for error mode, its recorder on a fake source.
    private func installErrorMode() throws -> Installed {
        let harness = ReplayHarness()
        let installSource = FakeSnapshotSource()
        let installScheduler = ManualScheduler()
        var built: ReplayRecorder?
        var environment = harness.environment
        environment.makeRecorder = { runtime in
            let recorder = ReplayRecorder(
                host: runtime, source: installSource, touchSource: FakeTouchSource(), observesRunLoop: false,
                monotonicNow: { installScheduler.now }, schedule: installScheduler.schedule, chunkMaxAge: 3600,
                beginBackgroundTask: { _ in {} })
            built = recorder
            return recorder
        }
        let cohorly = harness.makeCohorly()
        let runtime = try XCTUnwrap(CohorlyReplay.install(
            cohorly: cohorly, config: CohorlyReplayConfig(sampleRate: 0, onErrorSampleRate: 1), environment: environment))
        XCTAssertEqual(runtime.sessions.session.mode, .error)
        let recorder = try XCTUnwrap(built)
        installScheduler.advance(by: 0) // the first capture: Meta + Full snapshot into the error buffer
        recorder.drainWorker()
        XCTAssertEqual(installSource.captures, 1)
        return Installed(
            harness: harness, cohorly: cohorly, runtime: runtime, recorder: recorder, scheduler: installScheduler,
            source: installSource)
    }

    /// Lets the SDK queue, the recorder and the chunk queue finish.
    @MainActor
    private func settle(_ installed: Installed) async {
        await installed.cohorly.flush()
        installed.recorder.drainWorker()
        await installed.runtime.chunks.flush()
    }

    @MainActor
    func testATrackedExceptionSendsTheErrorBufferAndAnotherEventDoesNot() async throws {
        let installed = try installErrorMode()
        installed.cohorly.track("purchase", properties: ["plan": "pro"])
        await settle(installed)
        XCTAssertTrue(installed.harness.transport.chunks.isEmpty, "nothing leaves without an error")

        installed.cohorly.track("$exception", properties: ["$exception_list": [["type": "DemoError", "value": "boom"]]])
        await settle(installed)
        let chunks = installed.harness.transport.chunks
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.mode, .error)
        XCTAssertEqual(chunks.first?.sessionId, installed.runtime.sessions.session.id)
        XCTAssertEqual(chunks.first?.lib, "ios")
        XCTAssertEqual(eventTypes(chunks.first?.events ?? []), [4, 2, 5])
    }

    @MainActor
    func testNotifyErrorSendsTheErrorBuffer() async throws {
        let installed = try installErrorMode()
        CohorlyReplay.notifyError()
        await settle(installed)
        let chunks = installed.harness.transport.chunks
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.mode, .error)
        XCTAssertEqual(Array(eventTypes(chunks.first?.events ?? []).prefix(2)), [4, 2])
    }

    @MainActor
    func testNotifyErrorFromABackgroundQueueSendsTheErrorBuffer() async throws {
        let installed = try installErrorMode()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                CohorlyReplay.notifyError()
                continuation.resume()
            }
        }
        await settle(installed)
        let chunks = installed.harness.transport.chunks.filter { $0.mode == .error }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.sessionId, installed.runtime.sessions.session.id)
    }

    @MainActor
    func testAnExceptionThatRotatesTheSessionSendsUnderItsStampedSession() async throws {
        let installed = try installErrorMode()
        let before = installed.runtime.sessions.session.id
        // Idle past the timeout: the `$exception` is the new session's first event.
        installed.harness.clock.advance(by: ReplaySessionStore.idleTimeout + 60)
        installed.cohorly.track("$exception", properties: ["$exception_list": [["type": "DemoError", "value": "boom"]]])
        await installed.cohorly.flush()
        installed.recorder.drainWorker()

        // The new session's first capture: its request reaches the throttle
        // through the main queue.
        let deadline = Date().addingTimeInterval(10)
        while installed.source.captures < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            installed.scheduler.advance(by: ReplayRecorder.throttleInterval)
        }
        XCTAssertEqual(installed.source.captures, 2)
        await settle(installed)

        let exception = try XCTUnwrap(installed.harness.track.events.last { $0.event == "$exception" })
        guard case .string(let stamped)? = exception.properties["$session_id"] else {
            return XCTFail("the exception carries no $session_id")
        }
        XCTAssertNotEqual(stamped, before, "the exception rotated the session")
        let chunks = installed.harness.transport.chunks.filter { $0.mode == .error }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.sessionId, stamped)
        let types = eventTypes(chunks.first?.events ?? [])
        XCTAssertEqual(types.first, 4)
        XCTAssertEqual(types.last, 5)
    }

    func testNotifyErrorWithoutAnInstallDoesNothing() {
        CohorlyReplay.uninstall()
        CohorlyReplay.notifyError()
        XCTAssertFalse(CohorlyReplay.isInstalled)
    }
}

/// An error sink that only records the error signals it gets.
final class ErrorSignalSink: ReplayEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _errors: [String] = []

    var errors: [String] {
        lock.lock(); defer { lock.unlock() }
        return _errors
    }

    func add(_ group: [ReplayJSON], sessionId: String, distinctId: String, generation: UInt64) {}
    func flush() {}
    func discard() {}
    func errorOccurred(sessionId: String, distinctId: String?) {
        lock.lock(); _errors.append(sessionId); lock.unlock()
    }
}
