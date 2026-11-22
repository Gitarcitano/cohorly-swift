#if os(iOS)
import SwiftUI
import UIKit
import XCTest

@_spi(CohorlyReplay) @testable import Cohorly
@testable import CohorlyReplay

/// Screenshot mode's masks, read back from the JPEG it produces. Needs UIKit:
/// runs only on an iOS simulator (`xcodebuild test -scheme Cohorly-Package
/// -destination 'platform=iOS Simulator,name=<device>'`), never in
/// `swift test` on macOS.
///
/// The window is drawn with `layer.render(in:)` instead of `drawHierarchy`:
/// the test host has no scene to show a window in, and what is under test is
/// the masking, which is the same whatever drew the pixels.
final class ScreenshotMaskTests: XCTestCase {
    private struct Pixel {
        var red: Int
        var green: Int
        var blue: Int

        var isMask: Bool { red < 48 && green < 48 && blue < 48 }
    }

    /// Draws the window's subviews (a window that is not shown is hidden,
    /// and a hidden layer renders nothing) over a white background.
    private static let layerDraw: ScreenshotSnapshotSource.Draw = { view, _ in
        guard let context = UIGraphicsGetCurrentContext() else { return false }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(view.bounds)
        for subview in view.subviews {
            context.saveGState()
            context.translateBy(x: subview.frame.minX, y: subview.frame.minY)
            subview.layer.render(in: context)
            context.restoreGState()
        }
        return true
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private static func box(_ frame: CGRect, _ color: UIColor) -> UIView {
        let view = UIView(frame: frame)
        view.backgroundColor = color
        return view
    }

    private struct Screen {
        let window: UIWindow
        let field: CGRect
        let secure: CGRect
        let image: CGRect
        let marked: CGRect
        let token: CGRect
        let plain: CGRect
    }

    private func makeScreen() -> Screen {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let screen = Screen(
            window: window,
            field: CGRect(x: 20, y: 20, width: 200, height: 40),
            secure: CGRect(x: 20, y: 80, width: 200, height: 40),
            image: CGRect(x: 20, y: 140, width: 100, height: 100),
            marked: CGRect(x: 20, y: 260, width: 100, height: 60),
            token: CGRect(x: 160, y: 260, width: 100, height: 60),
            plain: CGRect(x: 160, y: 380, width: 100, height: 60))

        let field = UITextField(frame: screen.field)
        field.backgroundColor = .yellow
        field.text = "typed secret"
        let secure = UITextField(frame: screen.secure)
        secure.backgroundColor = .green
        secure.isSecureTextEntry = true
        secure.text = "hunter2"
        let image = UIImageView(frame: screen.image)
        image.image = Self.solidImage(.red)
        let marked = Self.box(screen.marked, .blue)
        marked.cohorlyNoCapture = true
        let token = Self.box(screen.token, .magenta)
        token.accessibilityIdentifier = "card-cohorly-no-capture"
        let plain = Self.box(screen.plain, .orange)
        for view in [field, secure, image, marked, token, plain] { window.addSubview(view) }
        window.layoutIfNeeded()
        return screen
    }

    private func capture(_ window: UIWindow, maskAllImages: Bool = true) throws -> (ReplaySourceFrame, CGImage) {
        let source = ScreenshotSnapshotSource(maskAllImages: maskAllImages, draw: Self.layerDraw)
        let frame = try XCTUnwrap(source.frame(of: window, href: "MaskTest"))
        let base64 = try XCTUnwrap(frame.wireframes.first?.base64)
        XCTAssertTrue(base64.hasPrefix("data:image/jpeg;base64,"))
        let data = try XCTUnwrap(Data(base64Encoded: String(base64.dropFirst("data:image/jpeg;base64,".count))))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        return (frame, image)
    }

    /// The image's pixels as RGBA8, sRGB.
    private func readPixels(_ image: CGImage) throws -> (bytes: [UInt8], width: Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return (bytes, width)
    }

    private func pixel(_ pixels: (bytes: [UInt8], width: Int), _ x: Int, _ y: Int) -> Pixel {
        let offset = (y * pixels.width + x) * 4
        return Pixel(red: Int(pixels.bytes[offset]), green: Int(pixels.bytes[offset + 1]), blue: Int(pixels.bytes[offset + 2]))
    }

    /// The center and four points 4 px inside the corners (JPEG blurs edges).
    private func samples(_ rect: CGRect) -> [(Int, Int)] {
        let inner = rect.insetBy(dx: 4, dy: 4)
        return [
            (Int(rect.midX), Int(rect.midY)),
            (Int(inner.minX), Int(inner.minY)), (Int(inner.maxX) - 1, Int(inner.minY)),
            (Int(inner.minX), Int(inner.maxY) - 1), (Int(inner.maxX) - 1, Int(inner.maxY) - 1)
        ]
    }

    private func assertMasked(_ rect: CGRect, in pixels: (bytes: [UInt8], width: Int), _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in samples(rect) {
            let value = pixel(pixels, x, y)
            XCTAssertTrue(value.isMask, "\(name) at \(x),\(y) is \(value)", file: file, line: line)
        }
    }

    func testFieldsSecureFieldsImagesAndMarkedViewsArePaintedOverInThePixels() throws {
        let screen = makeScreen()
        let (frame, image) = try capture(screen.window)
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 480)
        XCTAssertEqual(frame.wireframes.count, 1)
        XCTAssertEqual(frame.wireframes.first?.type, "screenshot")
        XCTAssertEqual(frame.wireframes.first?.width, 320)
        XCTAssertEqual(frame.wireframes.first?.height, 480)
        XCTAssertGreaterThanOrEqual(frame.wireframes.first?.id ?? 0, ReplayWireframe.firstId)
        XCTAssertEqual(image.width, 320, "1 pixel per point")
        XCTAssertEqual(image.height, 480)

        let pixels = try readPixels(image)
        assertMasked(screen.field, in: pixels, "text field")
        assertMasked(screen.secure, in: pixels, "secure field")
        assertMasked(screen.image, in: pixels, "image")
        assertMasked(screen.marked, in: pixels, "cohorlyNoCapture view")
        assertMasked(screen.token, in: pixels, "cohorly-no-capture identifier")

        // Outside every mask the pixels are the screen's.
        let orange = pixel(pixels, Int(screen.plain.midX), Int(screen.plain.midY))
        XCTAssertGreaterThan(orange.red, 200, "\(orange)")
        XCTAssertGreaterThan(orange.green, 80, "\(orange)")
        XCTAssertLessThan(orange.blue, 90, "\(orange)")
        let white = pixel(pixels, 300, 200)
        XCTAssertTrue(white.red > 200 && white.green > 200 && white.blue > 200, "\(white)")
    }

    func testAReactNativeTextInputIsPaintedOverAndAPlainReadOnlyTextViewIsNot() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let inputFrame = CGRect(x: 20, y: 20, width: 200, height: 80)
        let termsFrame = CGRect(x: 20, y: 200, width: 200, height: 80)
        let input = FakeReactNativeTextView(frame: inputFrame)
        input.backgroundColor = .orange
        input.text = "read-only secret"
        input.isEditable = false
        let terms = UITextView(frame: termsFrame)
        terms.backgroundColor = .orange
        terms.isEditable = false
        for view in [input, terms] { window.addSubview(view) }
        window.layoutIfNeeded()

        let pixels = try readPixels(capture(window).1)
        assertMasked(inputFrame, in: pixels, "React Native TextInput")
        let center = pixel(pixels, Int(termsFrame.midX), Int(termsFrame.midY))
        XCTAssertGreaterThan(center.red, 200, "a plain read-only text view keeps its pixels: \(center)")
    }

    func testAMaskIsRoundedOutwardAndGrownByOnePixel() throws {
        let renderer = ReplayImageRenderer(size: CGSize(width: 32, height: 32), scale: 1)
        let image = renderer.image { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            ScreenshotSnapshotSource.paint([CGRect(x: 10.5, y: 10.5, width: 5, height: 5)], in: context)
            return true
        }
        let pixels = try readPixels(try XCTUnwrap(image?.cgImage))
        // 10.5...15.5 rounds out to pixels 10...15, then one more on each side.
        XCTAssertTrue(pixel(pixels, 9, 9).isMask)
        XCTAssertTrue(pixel(pixels, 16, 16).isMask)
        XCTAssertFalse(pixel(pixels, 8, 8).isMask)
        XCTAssertFalse(pixel(pixels, 17, 17).isMask)
        XCTAssertFalse(pixel(pixels, 9, 17).isMask)
    }

    func testImagesKeepTheirPixelsWhenMaskAllImagesIsOff() throws {
        let screen = makeScreen()
        let (_, image) = try capture(screen.window, maskAllImages: false)
        let pixels = try readPixels(image)
        let red = pixel(pixels, Int(screen.image.midX), Int(screen.image.midY))
        XCTAssertTrue(red.red > 200 && red.green < 80 && red.blue < 80, "\(red)")
        // Fields stay masked whatever the option.
        assertMasked(screen.field, in: pixels, "text field")
        assertMasked(screen.secure, in: pixels, "secure field")
    }

    func testAFreshScreenThatComesOutBlankIsDrawnAgainAfterScreenUpdates() throws {
        let screen = makeScreen()
        var calls: [Bool] = []
        let source = ScreenshotSnapshotSource(maskAllImages: true) { view, afterScreenUpdates in
            calls.append(afterScreenUpdates)
            // A just-presented screen: nothing to copy until the layout is committed.
            return afterScreenUpdates ? Self.layerDraw(view, afterScreenUpdates) : true
        }
        XCTAssertNotNil(source.frame(of: screen.window, href: "Fresh"))
        XCTAssertEqual(calls, [false, true])

        // A screen that stays blank: never sent, and drawn after screen
        // updates only on its first attempt.
        calls = []
        let blank = ScreenshotSnapshotSource(maskAllImages: true) { _, afterScreenUpdates in
            calls.append(afterScreenUpdates)
            return true
        }
        XCTAssertNil(blank.frame(of: screen.window, href: "Blank"), "a blank frame is never sent")
        XCTAssertEqual(calls, [false, true])
        calls = []
        XCTAssertNil(blank.frame(of: screen.window, href: "Blank"))
        XCTAssertEqual(calls, [false])
    }

    func testANearlyTransparentMarkedViewIsStillPaintedOver() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let rect = CGRect(x: 40, y: 40, width: 120, height: 80)
        let faint = Self.box(rect, .blue)
        faint.alpha = 0.02
        faint.cohorlyNoCapture = true
        window.addSubview(faint)
        window.layoutIfNeeded()
        let pixels = try readPixels(try capture(window).1)
        assertMasked(rect, in: pixels, "cohorlyNoCapture view at alpha 0.02")
    }

    func testAFieldInsideANearlyTransparentContainerIsStillPaintedOver() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        container.alpha = 0.005
        let fieldRect = CGRect(x: 20, y: 20, width: 200, height: 40)
        let field = UITextField(frame: fieldRect)
        field.backgroundColor = .yellow
        field.text = "typed secret"
        container.addSubview(field)
        window.addSubview(container)
        window.layoutIfNeeded()
        let pixels = try readPixels(try capture(window).1)
        assertMasked(fieldRect, in: pixels, "text field in a container at alpha 0.005")
    }

    /// The area is where the layout puts it, not where the marker registry
    /// says: a green 120 x 80 at (40, 100) from the top left, safe area ignored.
    private static let swiftUIArea = CGRect(x: 40, y: 100, width: 120, height: 80)

    private func swiftUIWindow(noCapture: Bool) -> (UIWindow, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let area = Self.swiftUIArea
        let content = SwiftUI.Color.green
            .frame(width: area.width, height: area.height)
            .cohorlyNoCapture(noCapture)
            .padding(.leading, area.minX)
            .padding(.top, area.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        let host = UIHostingController(rootView: content)
        host.view.frame = window.bounds
        host.view.backgroundColor = .white
        window.addSubview(host.view)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    func testASwiftUINoCaptureAreaIsPaintedOver() throws {
        let area = Self.swiftUIArea
        let (plainWindow, plainHost) = swiftUIWindow(noCapture: false)
        let plain = try readPixels(try capture(plainWindow).1)
        withExtendedLifetime(plainHost) {}
        let green = pixel(plain, Int(area.midX), Int(area.midY))
        try XCTSkipUnless(green.green > 100 && green.red < 120 && green.blue < 120,
                          "SwiftUI did not render in this test host: \(green)")
        for (x, y) in samples(area) {
            XCTAssertFalse(pixel(plain, x, y).isMask, "disabled, the area is recorded as usual at \(x),\(y)")
        }

        let (window, host) = swiftUIWindow(noCapture: true)
        let masked = try readPixels(try capture(window).1)
        withExtendedLifetime(host) {}
        assertMasked(area, in: masked, "SwiftUI .cohorlyNoCapture()")
        let outside = pixel(masked, 10, 10)
        XCTAssertFalse(outside.isMask, "\(outside)")
        let below = pixel(masked, Int(area.midX), Int(area.maxY) + 20)
        XCTAssertFalse(below.isMask, "\(below)")
    }
}
#endif
