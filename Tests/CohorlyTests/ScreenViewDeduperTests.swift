import XCTest

@testable import Cohorly

// Plain objects named like view controllers: the rule only sees an object and
// its class name, so these run with `swift test` on macOS.
private final class CheckoutViewController: NSObject {}
private final class ProfileViewController: NSObject {}
private final class UINavigationControllerFake: NSObject {}
private final class UIAlertControllerFake: NSObject {}
private final class _PrivateThing: NSObject {}

final class ScreenViewDeduperTests: XCTestCase {
    func testFirstInstanceEmitsItsClassNameWithoutModule() throws {
        let deduper = ScreenViewDeduper()
        let name = try XCTUnwrap(deduper.nameToEmit(for: CheckoutViewController()))
        XCTAssertEqual(name, "CheckoutViewController")
        XCTAssertFalse(name.contains("."))
    }

    func testSameInstanceTwiceEmitsOnce() {
        let deduper = ScreenViewDeduper()
        let checkout = CheckoutViewController()
        XCTAssertEqual(deduper.nameToEmit(for: checkout), "CheckoutViewController")
        XCTAssertNil(deduper.nameToEmit(for: checkout))
    }

    func testGoingBackToAPreviousControllerEmitsAgain() {
        let deduper = ScreenViewDeduper()
        let first = CheckoutViewController()
        let second = ProfileViewController()
        XCTAssertEqual(deduper.nameToEmit(for: first), "CheckoutViewController")
        XCTAssertEqual(deduper.nameToEmit(for: second), "ProfileViewController")
        XCTAssertEqual(deduper.nameToEmit(for: first), "CheckoutViewController")
    }

    func testNewInstanceOfTheSameClassEmits() {
        let deduper = ScreenViewDeduper()
        let first = CheckoutViewController()
        let second = CheckoutViewController()
        XCTAssertEqual(deduper.nameToEmit(for: first), "CheckoutViewController")
        XCTAssertEqual(deduper.nameToEmit(for: second), "CheckoutViewController")
    }

    func testAFreedInstanceDoesNotBlockANewOne() {
        let deduper = ScreenViewDeduper()
        autoreleasepool {
            XCTAssertNotNil(deduper.nameToEmit(for: CheckoutViewController()))
        }
        // The first one is gone (held weakly): whatever the new object's
        // address, it emits.
        XCTAssertEqual(deduper.nameToEmit(for: CheckoutViewController()), "CheckoutViewController")
    }

    func testIgnoredClassNamesEmitNothing() {
        let deduper = ScreenViewDeduper()
        XCTAssertNil(deduper.nameToEmit(for: UINavigationControllerFake()))
        XCTAssertNil(deduper.nameToEmit(for: UIAlertControllerFake()))
        XCTAssertNil(deduper.nameToEmit(for: _PrivateThing()))
        XCTAssertNil(deduper.nameToEmit(for: CheckoutViewController(), className: "UIHostingController<Foo>"))
    }

    func testIgnoredControllersDoNotResetTheDedupe() {
        let deduper = ScreenViewDeduper()
        let checkout = CheckoutViewController()
        XCTAssertEqual(deduper.nameToEmit(for: checkout), "CheckoutViewController")
        XCTAssertNil(deduper.nameToEmit(for: UIAlertControllerFake()))
        XCTAssertNil(deduper.nameToEmit(for: _PrivateThing()))
        // Back on the same controller after the ignored ones: still one `$screen`.
        XCTAssertNil(deduper.nameToEmit(for: checkout))
    }

    func testClassNameThatMerelyContainsUIIsNotIgnored() {
        let deduper = ScreenViewDeduper()
        XCTAssertEqual(deduper.nameToEmit(for: CheckoutViewController(), className: "QuizViewController"), "QuizViewController")
    }

    func testTheSameControllerEmitsAgainAfterItDisappeared() {
        let deduper = ScreenViewDeduper()
        let sheet = CheckoutViewController()
        XCTAssertEqual(deduper.nameToEmit(for: sheet), "CheckoutViewController")
        XCTAssertNil(deduper.nameToEmit(for: sheet))
        deduper.disappeared(sheet)
        XCTAssertEqual(deduper.nameToEmit(for: sheet), "CheckoutViewController")
    }

    func testAnotherControllerDisappearingChangesNothing() {
        let deduper = ScreenViewDeduper()
        let current = CheckoutViewController()
        XCTAssertNotNil(deduper.nameToEmit(for: current))
        deduper.disappeared(ProfileViewController())
        XCTAssertNil(deduper.nameToEmit(for: current))
    }

    func testTheKVORuntimeSubclassPrefixIsDropped() {
        XCTAssertEqual(ScreenViewDeduper.displayName(ofClassNamed: "NSKVONotifying_CheckoutViewController"), "CheckoutViewController")
        XCTAssertEqual(ScreenViewDeduper.displayName(ofClassNamed: "CheckoutViewController"), "CheckoutViewController")
        XCTAssertTrue(ScreenViewDeduper.isIgnored(className: ScreenViewDeduper.displayName(ofClassNamed: "NSKVONotifying_UINavigationController")))
    }
}
