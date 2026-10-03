import XCTest

/// The prompt's layout.
///
/// The user's report (2026-10-03): 「输入密码的密码框宽度应该和弹出的宽度一样，当前的只有一半宽度」.
/// The cause was a vertical `NSStackView`, which sizes an arranged subview to its
/// intrinsic width — for a text field that is just the placeholder — so the field
/// came out roughly half the dialog wide. These tests pin the layout so it cannot
/// silently regress to placeholder width.
final class ArchivePasswordPrompterTests: XCTestCase {
    private func prompt(afterFailedAttempt: Bool = false) -> ArchivePasswordPrompter.Prompt {
        ArchivePasswordPrompter.makePrompt(
            text: { Localization.text($0, language: .simplifiedChinese) },
            archiveName: "webp_images.zip",
            afterFailedAttempt: afterFailedAttempt
        )
    }

    func testThePasswordFieldIsAsWideAsTheAccessoryItSitsIn() {
        let prompt = prompt()
        guard let accessory = prompt.field.superview else {
            return XCTFail("the password field should sit in the alert's accessory view")
        }
        // Let the accessory lay itself out first: a stack view only shrinks the
        // field to its intrinsic width once it has laid out its arranged subviews.
        accessory.layoutSubtreeIfNeeded()
        prompt.alert.window.layoutIfNeeded()
        // The bug: a vertical `NSStackView` sizes an arranged subview to its
        // intrinsic width — for a text field that is the placeholder — so the
        // password box came out half the dialog wide. The controls are placed by
        // frame instead, which is what lets the field span the dialog.
        XCTAssertFalse(
            accessory is NSStackView,
            "a stack view shrinks the field to its placeholder width — lay the controls out by frame"
        )
        XCTAssertEqual(
            prompt.field.frame.width,
            accessory.frame.width,
            accuracy: 0.5,
            "the field must span the accessory, not shrink to its placeholder"
        )
        XCTAssertGreaterThanOrEqual(prompt.field.frame.width, 300)
        XCTAssertTrue(
            prompt.field.autoresizingMask.contains(.width),
            "if AppKit stretches the accessory, the field has to follow it"
        )
    }

    func testTheFieldKeepsTheFullWidthOnceTheAlertIsLaidOut() throws {
        let prompt = prompt()
        prompt.alert.window.layoutIfNeeded()
        guard let content = prompt.alert.window.contentView, content.frame.width > 200 else {
            throw XCTSkip("outside a modal session the alert window has no laid-out geometry")
        }
        XCTAssertGreaterThanOrEqual(
            prompt.field.frame.width,
            content.frame.width * 0.85,
            "the field should take the dialog's content width (minus its margins)"
        )
    }

    /// The two controls stack: password box on top, the remember checkbox under it.
    func testTheRememberCheckboxSitsUnderTheFieldAndStaysNarrow() {
        let prompt = prompt()
        XCTAssertEqual(prompt.remember.frame.maxY, prompt.field.frame.minY - 8, accuracy: 1)
        XCTAssertLessThan(prompt.remember.frame.width, prompt.field.frame.width)
        XCTAssertEqual(prompt.remember.title, Localization.text(.archiveUnlockRemember, language: .simplifiedChinese))
    }

    func testARetrySaysThePasswordWasWrong() {
        let first = prompt()
        let retry = prompt(afterFailedAttempt: true)
        XCTAssertTrue(first.alert.informativeText.contains("webp_images.zip"))
        XCTAssertEqual(
            retry.alert.informativeText,
            Localization.text(.archiveUnlockWrongMessage, language: .simplifiedChinese)
        )
        XCTAssertNotEqual(first.alert.informativeText, retry.alert.informativeText)
        XCTAssertEqual(retry.alert.messageText, Localization.text(.archiveUnlockTitle, language: .simplifiedChinese))
        XCTAssertEqual(retry.alert.buttons.count, 2)
    }
}
