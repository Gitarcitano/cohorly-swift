#if os(iOS)
import MapKit
import SwiftUI
import UIKit
import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

private final class CheckoutViewController: UIViewController {}

/// A UIKit view inside SwiftUI: a label wider than the area it is laid out
/// in, sticking out on both sides (the container does not clip).
private struct OverflowingLabel: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let label = UILabel(frame: CGRect(x: -40, y: 0, width: 200, height: 20))
        label.text = text
        container.addSubview(label)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Stands in for `UIApplication` in the swizzle test: same selector, no
/// process-wide effect.
private final class FakeApplication: NSObject {
    private(set) var originalCalls = 0
    @objc func sendEvent(_ event: UIEvent) { originalCalls += 1 }
}

private final class FakeTouchEvent: UIEvent {
    override var type: UIEvent.EventType { .touches }
}

/// The UIKit half of the recorder, on a real view hierarchy. Runs with
/// `xcodebuild test -scheme Cohorly-Package -destination 'platform=iOS Simulator,...'`
/// (UIKit does not exist under `swift test` on macOS).
final class WireframeBuilderTests: XCTestCase {
    private var window: UIWindow!
    private var root: UIView!

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        root = controller.view
        root.frame = window.bounds
        root.backgroundColor = .white
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        root = nil
        super.tearDown()
    }

    private func build(maskAllImages: Bool = true) -> [ReplayWireframe] {
        window.layoutIfNeeded()
        return WireframeBuilder(maskAllImages: maskAllImages).build(window: window)
    }

    private func find(_ view: UIView, in wireframes: [ReplayWireframe]) -> ReplayWireframe? {
        let id = ReplayViewIds.id(for: view)
        return wireframes.flattened().first { $0.id == id }
    }

    private func add<V: UIView>(_ view: V, _ frame: CGRect) -> V {
        view.frame = frame
        root.addSubview(view)
        return view
    }

    private func json(_ wireframes: [ReplayWireframe]) throws -> String {
        let data = try JSONEncoder().encode(ReplayEvents.fullSnapshot(wireframes, timestamp: 1))
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func testAButtonWithAMarkedTitleLabelNeverRecordsTheTitle() throws {
        for marker in ["property", "identifier"] {
            root.subviews.forEach { $0.removeFromSuperview() }
            let button = add(UIButton(type: .system), CGRect(x: 16, y: 100, width: 200, height: 44))
            button.setTitle("Pay 4242", for: .normal)
            button.layoutIfNeeded()
            let title = try XCTUnwrap(button.titleLabel)
            if marker == "property" { title.cohorlyNoCapture = true } else { title.accessibilityIdentifier = "cohorly-no-capture" }
            let wireframes = build()
            XCTAssertFalse(try json(wireframes).contains("4242"), marker)
            XCTAssertNil(try XCTUnwrap(find(button, in: wireframes)).value, marker)
        }
    }

    func testAChildCrossingAClippingParentIsRecordedClipped() throws {
        let scroll = add(UIView(), CGRect(x: 0, y: 100, width: 390, height: 200))
        scroll.clipsToBounds = true
        let cell = UIView(frame: CGRect(x: 10, y: 150, width: 300, height: 100))
        cell.backgroundColor = .blue
        scroll.addSubview(cell)
        let wireframe = try XCTUnwrap(find(cell, in: build()))
        XCTAssertEqual(wireframe.x, 10)
        XCTAssertEqual(wireframe.y, 250)
        XCTAssertEqual(wireframe.width, 300)
        XCTAssertEqual(wireframe.height, 50, "only the 50 points inside the parent")
    }

    func testLabelsShowTheirTextWithStyle() throws {
        let label = add(UILabel(), CGRect(x: 16, y: 100, width: 200, height: 20))
        label.text = "Welcome back"
        label.textColor = .red
        label.font = .systemFont(ofSize: 17)
        label.textAlignment = .center
        let wireframe = try XCTUnwrap(find(label, in: build()))
        XCTAssertEqual(wireframe.type, "text")
        XCTAssertEqual(wireframe.text, "Welcome back")
        XCTAssertEqual(wireframe.x, 16)
        XCTAssertEqual(wireframe.y, 100)
        XCTAssertEqual(wireframe.style?.color, "#FF0000")
        XCTAssertEqual(wireframe.style?.fontSize, 17)
        XCTAssertEqual(wireframe.style?.horizontalAlign, "center")
    }

    func testTextFieldsAreAlwaysAsterisksAndSecureOnesArePasswords() throws {
        let field = add(UITextField(), CGRect(x: 16, y: 150, width: 300, height: 44))
        field.text = "maria@example.com"
        let secure = add(UITextField(), CGRect(x: 16, y: 200, width: 300, height: 44))
        secure.text = "hunter2"
        secure.isSecureTextEntry = true
        let code = add(UITextField(), CGRect(x: 16, y: 250, width: 300, height: 44))
        code.text = "123456"
        code.textContentType = .oneTimeCode
        let notes = add(UITextView(), CGRect(x: 16, y: 300, width: 300, height: 80))
        notes.text = "private notes"
        let search = add(UISearchBar(), CGRect(x: 0, y: 400, width: 390, height: 56))
        search.text = "secret search"

        let wireframes = build(maskAllImages: false)
        let fieldFrame = try XCTUnwrap(find(field, in: wireframes))
        XCTAssertEqual(fieldFrame.type, "input")
        XCTAssertEqual(fieldFrame.inputType, "text")
        XCTAssertEqual(fieldFrame.value, .string(String(repeating: "*", count: 17)))
        XCTAssertNil(fieldFrame.childWireframes, "never walked into: its internal label holds the text")
        XCTAssertEqual(find(secure, in: wireframes)?.inputType, "password")
        XCTAssertEqual(find(secure, in: wireframes)?.value, .string("*******"))
        XCTAssertEqual(find(code, in: wireframes)?.inputType, "password")
        XCTAssertEqual(find(notes, in: wireframes)?.inputType, "text_area")
        XCTAssertEqual(find(search, in: wireframes)?.inputType, "search")

        let all = try json(wireframes)
        for typed in ["maria@example.com", "hunter2", "123456", "private notes", "secret search"] {
            XCTAssertFalse(all.contains(typed), "\(typed) reached the snapshot")
        }
    }

    func testATextViewOnceEditableStaysMaskedAfterTurningReadOnly() throws {
        let notes = add(UITextView(), CGRect(x: 16, y: 100, width: 300, height: 80))
        notes.text = "typed secret 5555"
        XCTAssertEqual(find(notes, in: build())?.type, "input")
        notes.isEditable = false
        let wireframes = build()
        let wireframe = try XCTUnwrap(find(notes, in: wireframes))
        XCTAssertEqual(wireframe.type, "input")
        XCTAssertEqual(wireframe.value, .string(String(repeating: "*", count: 17)))
        XCTAssertFalse(try json(wireframes).contains("5555"))
    }

    func testACardNumberFieldIsAPasswordOfAsterisks() throws {
        let card = add(UITextField(), CGRect(x: 16, y: 150, width: 300, height: 44))
        card.textContentType = .creditCardNumber
        card.text = "4242424242424242"
        let wireframes = build()
        let wireframe = try XCTUnwrap(find(card, in: wireframes))
        XCTAssertEqual(wireframe.inputType, "password")
        XCTAssertEqual(wireframe.value, .string(String(repeating: "*", count: 16)))
        XCTAssertFalse(try json(wireframes).contains("4242"))
    }

    func testAReadOnlyTextViewShowsItsText() {
        let terms = add(UITextView(), CGRect(x: 16, y: 100, width: 300, height: 80))
        terms.text = "Terms of use"
        terms.isEditable = false
        let wireframe = find(terms, in: build())
        XCTAssertEqual(wireframe?.type, "text")
        XCTAssertEqual(wireframe?.text, "Terms of use")
    }

    func testImagesHaveNoPixelsByDefaultAndAJPEGWhenAllowed() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let imageView = add(UIImageView(image: image), CGRect(x: 0, y: 500, width: 100, height: 100))
        let masked = try XCTUnwrap(find(imageView, in: build()))
        XCTAssertEqual(masked.type, "image")
        XCTAssertNil(masked.base64)
        let shown = try XCTUnwrap(find(imageView, in: build(maskAllImages: false)))
        let prefix = "data:image/jpeg;base64,"
        let base64 = try XCTUnwrap(shown.base64)
        XCTAssertTrue(base64.hasPrefix(prefix))
        let jpeg = try XCTUnwrap(Data(base64Encoded: String(base64.dropFirst(prefix.count))))
        let decoded = try XCTUnwrap(UIImage(data: jpeg), "a real JPEG")
        XCTAssertEqual(decoded.size.width * decoded.scale, 100, "drawn at the view size")
        XCTAssertEqual(decoded.size.height * decoded.scale, 100)
    }

    func testAMarkedViewAndItsSubtreeAreOnePlaceholder() throws {
        let card = add(UIView(), CGRect(x: 0, y: 100, width: 390, height: 200))
        card.cohorlyNoCapture = true
        let inner = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 20))
        inner.text = "Card 4242"
        card.addSubview(inner)
        let image = UIImage()
        let photo = UIImageView(image: image)
        photo.frame = CGRect(x: 10, y: 40, width: 50, height: 50)
        card.addSubview(photo)

        let byIdentifier = add(UIView(), CGRect(x: 0, y: 400, width: 390, height: 100))
        byIdentifier.accessibilityIdentifier = "balance cohorly-no-capture"
        let balance = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        balance.text = "$1,234"
        byIdentifier.addSubview(balance)

        let wireframes = build(maskAllImages: false)
        let placeholder = try XCTUnwrap(find(card, in: wireframes))
        XCTAssertEqual(placeholder.type, "placeholder")
        XCTAssertNil(placeholder.childWireframes)
        XCTAssertNil(placeholder.label)
        XCTAssertEqual(find(byIdentifier, in: wireframes)?.type, "placeholder")
        XCTAssertNil(find(inner, in: wireframes))
        XCTAssertNil(find(balance, in: wireframes))
        let all = try json(wireframes)
        XCTAssertFalse(all.contains("4242"))
        XCTAssertFalse(all.contains("1,234"))
    }

    func testAMarkedSecureFieldIsAPlaceholderToo() {
        let field = add(UITextField(), CGRect(x: 16, y: 150, width: 300, height: 44))
        field.isSecureTextEntry = true
        field.text = "pw"
        field.cohorlyNoCapture = true
        XCTAssertEqual(find(field, in: build())?.type, "placeholder")
    }

    func testTheWalkStopsAtAMapView() throws {
        let map = add(MKMapView(), CGRect(x: 0, y: 100, width: 390, height: 400))
        let sentinel = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 20))
        sentinel.text = "SENTINEL in the map"
        map.addSubview(sentinel)
        let wireframes = build()
        let wireframe = try XCTUnwrap(find(map, in: wireframes))
        XCTAssertEqual(wireframe.type, "placeholder")
        XCTAssertEqual(wireframe.label, "Map")
        XCTAssertNil(wireframe.childWireframes)
        XCTAssertFalse(try json(wireframes).contains("SENTINEL"))
    }

    func testAZeroSizeMarkedOrOpaqueParentHidesAVisibleChildOutsideItsBounds() throws {
        let marked = add(UIView(), CGRect(x: 0, y: 100, width: 0, height: 0))
        marked.cohorlyNoCapture = true
        let markedChild = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 20))
        markedChild.text = "Marked child 1111"
        marked.addSubview(markedChild)

        let byToken = add(UIView(), CGRect(x: 0, y: 200, width: 0, height: 0))
        byToken.accessibilityIdentifier = "cohorly-no-capture"
        let tokenChild = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 20))
        tokenChild.text = "Token child 2222"
        byToken.addSubview(tokenChild)

        let map = add(MKMapView(), CGRect(x: 0, y: 300, width: 0, height: 0))
        let mapChild = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 20))
        mapChild.text = "Map child 3333"
        map.addSubview(mapChild)

        let wireframes = build()
        let all = try json(wireframes)
        for secret in ["1111", "2222", "3333"] {
            XCTAssertFalse(all.contains(secret), secret)
        }
        XCTAssertNil(find(markedChild, in: wireframes))
        XCTAssertNil(find(tokenChild, in: wireframes))
        XCTAssertNil(find(mapChild, in: wireframes))
    }

    func testAStructureFingerprintIgnoresWhatChangesInsideAMarkedOrOpaqueView() {
        let marked = add(UIView(), CGRect(x: 0, y: 100, width: 200, height: 100))
        marked.cohorlyNoCapture = true
        let inside = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        inside.text = "a"
        marked.addSubview(inside)
        let map = add(MKMapView(), CGRect(x: 0, y: 300, width: 200, height: 100))
        let inMap = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        inMap.text = "a"
        map.addSubview(inMap)
        window.layoutIfNeeded()
        let before = WireframeBuilder.structureFingerprint(of: window)
        inside.text = "b"
        inMap.text = "b"
        inMap.frame.origin.y = 40
        XCTAssertEqual(WireframeBuilder.structureFingerprint(of: window), before)
        let outside = add(UILabel(), CGRect(x: 0, y: 500, width: 100, height: 20))
        outside.text = "c"
        XCTAssertNotEqual(WireframeBuilder.structureFingerprint(of: window), before)
    }

    func testHiddenTransparentEmptyAndOffScreenViewsAreLeftOut() {
        let hidden = add(UIView(), CGRect(x: 0, y: 0, width: 50, height: 50))
        hidden.isHidden = true
        let transparent = add(UIView(), CGRect(x: 0, y: 60, width: 50, height: 50))
        transparent.alpha = 0.005
        let empty = add(UIView(), CGRect(x: 0, y: 120, width: 0, height: 0))
        let offScreen = add(UIView(), CGRect(x: 0, y: 2000, width: 50, height: 50))
        let visible = add(UIView(), CGRect(x: 0, y: 200, width: 50, height: 50))
        // A child of the zero-size view still draws (it does not clip).
        let child = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        empty.addSubview(child)

        let wireframes = build()
        XCTAssertNil(find(hidden, in: wireframes))
        XCTAssertNil(find(transparent, in: wireframes))
        XCTAssertNil(find(empty, in: wireframes))
        XCTAssertNil(find(offScreen, in: wireframes))
        XCTAssertNotNil(find(visible, in: wireframes))
        XCTAssertEqual(find(child, in: wireframes)?.parentId, ReplayViewIds.id(for: root))
    }

    func testIdsAreStableLargeAndTheTopParentIsTheScreenRoot() {
        let label = add(UILabel(), CGRect(x: 0, y: 100, width: 100, height: 20))
        label.text = "a"
        let first = build()
        label.text = "b"
        let second = build()
        XCTAssertEqual(find(label, in: first)?.id, find(label, in: second)?.id)
        XCTAssertTrue(second.flattened().allSatisfy { $0.id >= ReplayWireframe.firstId })
        XCTAssertEqual(second.map(\.parentId), [ReplayWireframe.screenRootId])
        XCTAssertEqual(Set(second.flattened().map(\.id)).count, second.flattened().count, "unique in the screen")
    }

    func testAtMostTwoThousandWireframes() {
        for index in 0..<2100 {
            _ = add(UIView(), CGRect(x: index % 390, y: 100, width: 1, height: 1))
        }
        XCTAssertEqual(build().flattened().count, WireframeBuilder.maxWireframes)
    }

    func testASwiftUINoCaptureAreaIsAnOpaquePlaceholderOnTopAndHidesWhatIsInside() throws {
        let content = add(UILabel(), CGRect(x: 20, y: 120, width: 100, height: 20))
        content.text = "IBAN 1234"
        let outside = add(UILabel(), CGRect(x: 20, y: 400, width: 100, height: 20))
        outside.text = "Visible"
        // `.cohorlyNoCapture()` puts the marker behind the content it covers.
        let marker = CohorlyNoCaptureMarkerView(frame: CGRect(x: 0, y: 100, width: 390, height: 60))
        root.insertSubview(marker, at: 0)

        let wireframes = build()
        XCTAssertNil(find(content, in: wireframes))
        XCTAssertNotNil(find(outside, in: wireframes))
        let cover = try XCTUnwrap(wireframes.last)
        XCTAssertEqual(cover.id, ReplayViewIds.id(for: marker))
        XCTAssertEqual(cover.type, "placeholder")
        XCTAssertEqual(cover.parentId, ReplayWireframe.screenRootId)
        XCTAssertEqual(cover.y, 100)
        XCTAssertNotNil(cover.style?.backgroundColor)
    }

    func testTheSwiftUIModifierMasksAUIKitLabelOnlyPartlyInsideItsArea() throws {
        let host = UIHostingController(rootView:
            OverflowingLabel(text: "IBAN 9876 5432")
                .frame(width: 100, height: 40)
                .cohorlyNoCapture())
        host.view.frame = CGRect(x: 100, y: 200, width: 190, height: 100)
        root.addSubview(host.view)
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()

        let label = try XCTUnwrap(allSubviews(of: host.view).compactMap { $0 as? UILabel }.first { $0.text == "IBAN 9876 5432" },
                                  "SwiftUI built the representable")
        let labelFrame = label.convert(label.bounds, to: window)
        let marker = try XCTUnwrap(allSubviews(of: host.view).first { $0 is CohorlyNoCaptureMarkerView })
        let area = marker.convert(marker.bounds, to: window)
        XCTAssertTrue(area.intersects(labelFrame) && !area.contains(labelFrame), "the label is only partly inside the area")

        let wireframes = build()
        XCTAssertEqual(wireframes.last?.id, ReplayViewIds.id(for: marker), "the cover is drawn on top")
        XCTAssertFalse(try json(wireframes).contains("9876"))
        XCTAssertFalse(try json(wireframes).contains("IBAN"))
    }

    func testCoversAreKeptWhenTheScreenPassesTheWireframeLimit() throws {
        for index in 0..<2100 {
            _ = add(UIView(), CGRect(x: index % 390, y: 100, width: 1, height: 1))
        }
        let marker = CohorlyNoCaptureMarkerView(frame: CGRect(x: 0, y: 600, width: 390, height: 60))
        root.addSubview(marker) // last in the tree: the walk reaches it after the limit
        let wireframes = build()
        XCTAssertEqual(wireframes.flattened().count, WireframeBuilder.maxWireframes)
        XCTAssertEqual(wireframes.last?.id, ReplayViewIds.id(for: marker))
    }

    func testTheKeyWindowFallsBackToTheApplicationWindowsWithoutScenes() {
        let sceneKey = UIWindow()
        let appKey = UIWindow()
        let other = UIWindow()
        let keys: Set<ObjectIdentifier> = [ObjectIdentifier(sceneKey), ObjectIdentifier(appKey)]
        let isKey: (UIWindow) -> Bool = { keys.contains(ObjectIdentifier($0)) }
        XCTAssertTrue(WireframeSnapshotSource.chooseWindow(
            foregroundKeyWindows: [], sceneWindows: [], applicationWindows: [other, appKey], isKey: isKey) === appKey,
            "no scene: the application's key window")
        XCTAssertTrue(WireframeSnapshotSource.chooseWindow(
            foregroundKeyWindows: [], sceneWindows: [other, sceneKey], applicationWindows: [appKey], isKey: isKey) === sceneKey)
        XCTAssertTrue(WireframeSnapshotSource.chooseWindow(
            foregroundKeyWindows: [other], sceneWindows: [sceneKey], applicationWindows: [appKey], isKey: isKey) === other)
        XCTAssertNil(WireframeSnapshotSource.chooseWindow(
            foregroundKeyWindows: [], sceneWindows: [other], applicationWindows: [other], isKey: isKey))
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    func testControls() {
        let toggle = add(UISwitch(), CGRect(x: 0, y: 100, width: 51, height: 31))
        toggle.isOn = true
        let button = add(UIButton(type: .system), CGRect(x: 0, y: 150, width: 120, height: 44))
        button.setTitle("Continue", for: .normal)
        let slider = add(UISlider(), CGRect(x: 0, y: 200, width: 200, height: 31))
        slider.value = 0.25
        let wireframes = build()
        XCTAssertEqual(find(toggle, in: wireframes)?.inputType, "toggle")
        XCTAssertEqual(find(toggle, in: wireframes)?.checked, true)
        XCTAssertEqual(find(button, in: wireframes)?.inputType, "button")
        XCTAssertEqual(find(button, in: wireframes)?.value, .string("Continue"))
        XCTAssertNil(find(button.titleLabel!, in: wireframes), "the title is drawn once, as the value")
        XCTAssertEqual(find(slider, in: wireframes)?.inputType, "progress")
        XCTAssertEqual(find(slider, in: wireframes)?.value, .double(0.25))
    }

    func testScreenNameIsTheTopViewControllerClassWithoutModule() {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(CheckoutViewController(), animated: false)
        window.rootViewController = navigation
        XCTAssertEqual(WireframeSnapshotSource.screenName(window), "CheckoutViewController")
    }

    func testSecureContentTypesIncludeTheUIKitConstants() {
        for type in [UITextContentType.password, .newPassword, .oneTimeCode, .creditCardNumber] {
            XCTAssertTrue(ReplaySecureContentTypes.all.contains(type.rawValue), type.rawValue)
        }
    }

    func testTheTouchSwizzleReplacesTheImplementationAndKeepsCallingTheOneBefore() throws {
        typealias SendEvent = @convention(c) (AnyObject, Selector, UIEvent) -> Void
        let selector = #selector(UIApplication.sendEvent(_:))
        let method = try XCTUnwrap(class_getInstanceMethod(FakeApplication.self, selector))
        // Another library's swizzle, installed first.
        var previousCalls = 0
        let original = unsafeBitCast(method_getImplementation(method), to: SendEvent.self)
        let previous: @convention(block) (AnyObject, UIEvent) -> Void = { target, event in
            previousCalls += 1
            original(target, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(previous))
        let before = method_getImplementation(method)

        let publisher = ReplayTouchPublisher(targetClass: FakeApplication.self)
        var published = 0
        let id = publisher.subscribe { _ in published += 1 }
        XCTAssertNotEqual(method_getImplementation(method), before, "swizzled")

        let application = FakeApplication()
        application.perform(selector, with: FakeTouchEvent())
        XCTAssertEqual(published, 1)
        XCTAssertEqual(previousCalls, 1, "the swizzle installed before still runs")
        XCTAssertEqual(application.originalCalls, 1, "and so does the original")
        publisher.unsubscribe(id)
    }

    func testTheTouchSwizzleIsInstalledOnceAndKept() throws {
        let selector = #selector(UIApplication.sendEvent(_:))
        let first = ReplayTouchPublisher.shared.subscribe { _ in }
        let method = try XCTUnwrap(class_getInstanceMethod(UIApplication.self, selector))
        let installed = method_getImplementation(method)
        let second = ReplayTouchPublisher.shared.subscribe { _ in }
        XCTAssertEqual(method_getImplementation(method), installed, "a second subscriber does not swizzle again")
        ReplayTouchPublisher.shared.unsubscribe(first)
        ReplayTouchPublisher.shared.unsubscribe(second)
        XCTAssertEqual(method_getImplementation(method), installed, "never unswizzled")
    }
}
#endif
