import XCTest

@testable import CohorlyReplay

final class ReplayMaskingTests: XCTestCase {
    private func decide(_ traits: ReplayViewTraits, maskAllImages: Bool = true) -> ReplayMaskDecision {
        ReplayMasking.decide(traits, maskAllImages: maskAllImages)
    }

    func testTextInputsAreAlwaysMaskedWithTheirInputType() {
        XCTAssertEqual(decide(ReplayViewTraits(kind: .textField, isEditable: true)),
                       ReplayMaskDecision(content: .maskedText, inputType: "text"))
        XCTAssertEqual(decide(ReplayViewTraits(kind: .textView, isEditable: true)),
                       ReplayMaskDecision(content: .maskedText, inputType: "text_area"))
        XCTAssertEqual(decide(ReplayViewTraits(kind: .searchBar, isEditable: true)),
                       ReplayMaskDecision(content: .maskedText, inputType: "search"))
        // No option changes that: images unmasked is about images only.
        XCTAssertEqual(decide(ReplayViewTraits(kind: .textField, isEditable: true), maskAllImages: false).content, .maskedText)
    }

    func testSecureFieldsArePasswordsWhateverElseIsSet() {
        let secureEntry = ReplayViewTraits(kind: .textField, isEditable: true, isSecureTextEntry: true)
        XCTAssertEqual(decide(secureEntry), ReplayMaskDecision(content: .maskedText, inputType: "password"))
        XCTAssertEqual(decide(secureEntry, maskAllImages: false), ReplayMaskDecision(content: .maskedText, inputType: "password"))
        for type in ["password", "new-password", "one-time-code", "cc-number", "cc-csc"] {
            let traits = ReplayViewTraits(kind: .textField, isEditable: true, textContentType: type)
            XCTAssertTrue(ReplayMasking.isSecure(traits), type)
            XCTAssertEqual(decide(traits).inputType, "password", type)
        }
        // A secure text view stays masked even when it is not editable.
        let readOnly = ReplayViewTraits(kind: .textView, isEditable: false, textContentType: "one-time-code")
        XCTAssertEqual(decide(readOnly).content, .maskedText)
        // Only secrets are passwords: an e-mail field is a (masked) text input.
        let email = ReplayViewTraits(kind: .textField, isEditable: true, textContentType: "email")
        XCTAssertEqual(decide(email), ReplayMaskDecision(content: .maskedText, inputType: "text"))
    }

    func testSecureContentTypesComeFromTheCallerToo() {
        let traits = ReplayViewTraits(kind: .textField, isEditable: true, textContentType: "some-future-secret")
        XCTAssertFalse(ReplayMasking.isSecure(traits))
        XCTAssertTrue(ReplayMasking.isSecure(traits, secureContentTypes: ["some-future-secret"]))
    }

    func testLabelsAndReadOnlyTextViewsShowTheirText() {
        XCTAssertEqual(decide(ReplayViewTraits(kind: .label)).content, .text)
        XCTAssertEqual(decide(ReplayViewTraits(kind: .textView, isEditable: false)).content, .text)
        XCTAssertNil(decide(ReplayViewTraits(kind: .label)).inputType)
    }

    func testImagesFollowMaskAllImages() {
        XCTAssertEqual(decide(ReplayViewTraits(kind: .image)).content, .maskedImage)
        XCTAssertEqual(decide(ReplayViewTraits(kind: .image), maskAllImages: false).content, .image)
    }

    func testAMarkerMakesAnyViewOnePlaceholderInputsAndSecureFieldsIncluded() {
        for kind: ReplayViewTraits.Kind in [.label, .image, .other, .textView, .textField, .searchBar] {
            let traits = ReplayViewTraits(kind: kind, isEditable: true, isSecureTextEntry: true, noCapture: true)
            XCTAssertEqual(decide(traits, maskAllImages: false).content, .placeholder, "\(kind)")
        }
    }

    func testOtherViewsHaveNothingToMask() {
        XCTAssertEqual(decide(ReplayViewTraits(kind: .other)), ReplayMaskDecision(content: .plain, inputType: nil))
    }

    func testMaskKeepsTheLengthOnly() {
        XCTAssertEqual(ReplayUtil.mask("hunter2"), "*******")
        XCTAssertEqual(ReplayUtil.mask(""), "")
        XCTAssertEqual(ReplayUtil.mask("çé"), "**")
    }

    func testHexColors() {
        XCTAssertEqual(ReplayUtil.hex(red: 1, green: 0, blue: 0.5), "#FF0080")
        XCTAssertEqual(ReplayUtil.hex(red: 2, green: -1, blue: .nan), "#FF0000")
    }
}
