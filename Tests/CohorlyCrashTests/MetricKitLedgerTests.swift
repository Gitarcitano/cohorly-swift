import XCTest
@testable import CohorlyCrash

/// The MetricKit path from converted diagnostics to the outbox
/// (`CrashReporter.enqueueMetricKitEvents`), with a real `CrashUploader` on a
/// temporary directory. Its endpoint is a closed local port, so an upload can
/// only fail and the files stay in the outbox; nothing waits on the network.
final class MetricKitLedgerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var root: URL!
    private var sessions: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MetricKitLedgerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MetricKitLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        sessions.forEach(CrashUploader.cancelAll(identifier:))
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A new uploader is a new launch: its own session, nothing in flight.
    private func launch(directory: URL) -> CrashUploader {
        let identifier = "MetricKitLedgerTests.\(UUID().uuidString)"
        sessions.append(identifier)
        return CrashUploader(
            identifier: identifier,
            directory: directory,
            endpoint: CrashEndpoint(token: "tok", host: "http://127.0.0.1:9")!,
            onDelete: { _ in }
        )
    }

    private func deliver(_ ids: [String], to uploader: CrashUploader, ledger: MetricKitLedger) {
        let events = ids.map { (insertId: $0, body: Data(#"{"event":"$exception"}"#.utf8)) }
        CrashReporter.enqueueMetricKitEvents(events, uploader: uploader, ledger: ledger)
        // The uploader's queue is serial: once this runs, every write above is done.
        let drained = expectation(description: "uploader queue drained")
        uploader.withInFlight { _ in drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    private func outboxIds(_ directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
    }

    func testADiagnosticDeliveredTwiceIsWrittenToTheOutboxOnce() {
        let outbox = root.appendingPathComponent("outbox")
        let ledger = MetricKitLedger(defaults: defaults)
        // didReceive: a (twice in one delivery) and b.
        deliver(["a", "a", "b"], to: launch(directory: outbox), ledger: ledger)
        XCTAssertEqual(outboxIds(outbox), ["mk-a", "mk-b"])
        XCTAssertEqual(ledger.unseen(["a", "b"]), [])

        // Both uploaded and deleted; the past payloads of the next launch
        // carry b again (inside another payload) next to a new c.
        try? FileManager.default.removeItem(at: outbox)
        deliver(["b", "c"], to: launch(directory: outbox), ledger: ledger)
        XCTAssertEqual(outboxIds(outbox), ["mk-c"])
    }

    func testAFailedOutboxWriteIsNotRecordedAndTheNextDeliveryRetries() throws {
        // A file where the outbox directory should be: every write fails.
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let ledger = MetricKitLedger(defaults: defaults)
        deliver(["a"], to: launch(directory: blocked), ledger: ledger)
        XCTAssertEqual(ledger.unseen(["a"]), ["a"])

        let outbox = root.appendingPathComponent("outbox")
        deliver(["a"], to: launch(directory: outbox), ledger: ledger)
        XCTAssertEqual(outboxIds(outbox), ["mk-a"])
        XCTAssertEqual(ledger.unseen(["a"]), [])
    }

    func testTheLedgerOutlivesTheProcess() {
        MetricKitLedger(defaults: defaults).record("a")
        // A later launch: a new ledger over the same defaults.
        XCTAssertEqual(MetricKitLedger(defaults: defaults).unseen(["a", "b", "b"]), ["b"])
    }

    func testOnlyTheMostRecentKeysAreKept() {
        let ledger = MetricKitLedger(defaults: defaults, capacity: 2)
        ["a", "b", "c", "c"].forEach(ledger.record)
        XCTAssertEqual(defaults.stringArray(forKey: MetricKitLedger.defaultsKey), ["b", "c"])
        // "a" fell out of the window, so it is new again.
        XCTAssertEqual(ledger.unseen(["a", "c"]), ["a"])
    }
}
