import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// Screenshot mode through the recorder, with a fake source standing in
/// for `ScreenshotSnapshotSource` (its pixels are tested on a simulator, in
/// `ScreenshotMaskTests`): the config, identical frames, touches.
final class ReplayScreenshotModeTests: XCTestCase {
    private static let shotId = 10_000_100

    private var host: FakeRecorderHost!
    private var source: FakeSnapshotSource!
    private var touches: FakeTouchSource!
    private var scheduler: ManualScheduler!
    private var recorder: ReplayRecorder!

    override func setUp() {
        super.setUp()
        host = FakeRecorderHost()
        source = FakeSnapshotSource()
        source.frame = Self.frame(image: "AAAA")
        touches = FakeTouchSource()
        scheduler = ManualScheduler()
        let scheduler = self.scheduler!
        recorder = ReplayRecorder(
            host: host, source: source, touchSource: touches, observesRunLoop: false,
            worker: DispatchQueue(label: "test.replay.screenshot"), monotonicNow: { scheduler.now },
            schedule: scheduler.schedule, chunkMaxAge: 3600, beginBackgroundTask: { _ in {} })
    }

    override func tearDown() {
        recorder.stop()
        recorder = nil
        super.tearDown()
    }

    private static func frame(image: String) -> ReplaySourceFrame {
        var shot = ReplayWireframe(id: shotId, x: 0, y: 0, width: 390, height: 844, type: ReplayWireframe.screenshotType)
        shot.base64 = "data:image/jpeg;base64," + image
        return ReplaySourceFrame(windowKey: 1, width: 390, height: 844, href: "Screen", wireframes: [shot])
    }

    private func settle(_ seconds: TimeInterval = 0) {
        scheduler.advance(by: seconds)
        recorder.drainWorker()
    }

    private func flushed() -> [ReplayJSON] {
        recorder.didEnterBackground()
        recorder.drainWorker()
        recorder.willEnterForeground()
        return host.enqueued.flatMap(\.events)
    }

    func testTheModeDefaultsToWireframeAndIsKeptInTheConfig() throws {
        XCTAssertEqual(CohorlyReplayConfig().mode, .wireframe)
        let config = CohorlyReplayConfig(sampleRate: 1, onErrorSampleRate: 0.5, maskAllImages: false, mode: .screenshot)
        XCTAssertEqual(config.mode, .screenshot)
        XCTAssertNotEqual(config, CohorlyReplayConfig(sampleRate: 1, onErrorSampleRate: 0.5, maskAllImages: false))
        XCTAssertEqual(CohorlyReplayMode(rawValue: "screenshot"), .screenshot)

        ReplayChunkQueue.resetProcessGone()
        defer {
            CohorlyReplay.uninstall()
            ReplayChunkQueue.resetProcessGone()
        }
        let harness = ReplayHarness()
        let runtime = try XCTUnwrap(CohorlyReplay.install(
            cohorly: harness.makeCohorly(), config: CohorlyReplayConfig(sampleRate: 1, mode: .screenshot),
            environment: harness.environment))
        XCTAssertEqual(runtime.config.mode, .screenshot)
        #if os(iOS)
        XCTAssertTrue(ReplayRuntime.makeSource(config: CohorlyReplayConfig()) is WireframeSnapshotSource)
        XCTAssertTrue(ReplayRuntime.makeSource(config: runtime.config) is ScreenshotSnapshotSource)
        #endif
    }

    func testAnIdenticalFrameSendsNothingAndFeedsTheBackoff() throws {
        var times: [TimeInterval] = []
        source.onCapture = { [unowned self] in times.append(self.scheduler.now) }
        recorder.start()
        settle()
        for _ in 0..<40 {
            recorder.requestCapture(full: false)
            settle(0.25)
        }
        XCTAssertEqual(Array(zip(times, times.dropFirst()).map { $1 - $0 }.prefix(5)), [1, 1, 1, 2, 4])
        let events = flushed()
        XCTAssertEqual(eventTypes(events), [4, 2])
        let full = try jsonObject(events[1])
        let wireframes = try XCTUnwrap((full["data"] as? [String: Any])?["wireframes"] as? [[String: Any]])
        XCTAssertEqual(wireframes.count, 1)
        XCTAssertEqual(wireframes.first?["type"] as? String, "screenshot")
        XCTAssertEqual(wireframes.first?["id"] as? Int, Self.shotId)
        XCTAssertEqual(wireframes.first?["width"] as? Int, 390)
        XCTAssertEqual(wireframes.first?["height"] as? Int, 844)
    }

    func testANewImageIsAMutationUpdateOfTheSameWireframe() throws {
        recorder.start()
        settle()
        source.frame = Self.frame(image: "BBBB")
        recorder.requestCapture(full: false)
        settle(1)
        let events = flushed()
        XCTAssertEqual(eventTypes(events), [4, 2, 3])
        let data = try XCTUnwrap(try jsonObject(events[2])["data"] as? [String: Any])
        let updates = try XCTUnwrap(data["updates"] as? [[String: Any]])
        XCTAssertEqual(updates.count, 1)
        let wireframe = try XCTUnwrap(updates.first?["wireframe"] as? [String: Any])
        XCTAssertEqual(wireframe["id"] as? Int, Self.shotId)
        XCTAssertEqual(wireframe["base64"] as? String, "data:image/jpeg;base64,BBBB")
        XCTAssertNil(data["adds"])
        XCTAssertNil(data["removes"])
    }

    func testTouchesCarryTheScreenshotsId() throws {
        recorder.start()
        // One before the first snapshot (it waits for it), one after.
        touches.send([ReplayRawTouch(kind: .start, x: 5, y: 6)])
        settle()
        touches.send([ReplayRawTouch(kind: .end, x: 7, y: 8)])
        recorder.drainWorker()
        let events = flushed()
        XCTAssertEqual(eventTypes(events), [4, 2, 3, 3])
        let ids = try events.suffix(2).map { try XCTUnwrap(try jsonObject($0)["data"] as? [String: Any])["id"] as? Int }
        XCTAssertEqual(ids, [Self.shotId, Self.shotId])
    }

    func testTouchesOnWireframesStillCarryTheScreenRoot() throws {
        source.frame = ReplaySourceFrame(windowKey: 1, width: 390, height: 844, href: "Screen", wireframes: sampleScreen())
        recorder.start()
        settle()
        touches.send([ReplayRawTouch(kind: .start, x: 5, y: 6)])
        recorder.drainWorker()
        let events = flushed()
        let data = try XCTUnwrap(try jsonObject(try XCTUnwrap(events.last))["data"] as? [String: Any])
        XCTAssertEqual(data["id"] as? Int, 0)
    }
}
