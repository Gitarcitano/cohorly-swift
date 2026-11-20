import ObjectiveC
import XCTest

@testable import Cohorly

/// A class of its own per test, so hooking it never touches another test.
private final class AppearRecorder: NSObject {
    var calls: [String] = []
    @objc dynamic func appear(_ animated: Bool) {
        calls.append("original \(animated)")
    }
}

/// The runtime part of the `viewDidAppear` swizzle, on a plain class so it runs
/// with `swift test` on macOS.
final class ScreenViewHookTests: XCTestCase {
    func testHookCallsTheReplacedImplementationFirstWithTheSameArgument() {
        let selector = #selector(AppearRecorder.appear(_:))
        XCTAssertTrue(ScreenViewSwizzle.hook(AppearRecorder.self, selector) { object in
            (object as? AppearRecorder)?.calls.append("after")
        })
        let recorder = AppearRecorder()
        recorder.appear(true)
        recorder.appear(false)
        XCTAssertEqual(recorder.calls, ["original true", "after", "original false", "after"])
    }

    func testHookIsRefusedForAMissingMethod() {
        XCTAssertFalse(ScreenViewSwizzle.hook(NSObject.self, NSSelectorFromString("noSuchMethod:")) { _ in })
    }
}
