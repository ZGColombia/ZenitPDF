#if canImport(XCTest)
import AppKit
import XCTest
@testable import ZPDFDesignSystem
import ZPDFUIPresentation

/// Bug hunt 2: the numeric field's display and its parser must agree in every locale, and what
/// the field shows after a commit must be what was stored.
@MainActor
final class Fix2NumericFieldTests: XCTestCase {

    // MARK: - BH-019

    /// Old output (sv_SE): `format(-3.25, 2)` was "−3,25" with U+2212, and
    /// `parse("−3,25")` returned nil — the field showed its own stored slope as
    /// "not a valid number". ar_SA gave "؜-٣٫٢٥" and fa_IR "‎−۳٫۲۵", both nil.
    func testEveryLocaleReadsBackItsOwnDisplay() {
        let locales = ["sv_SE", "fi_FI", "nb_NO", "et_EE", "ar_SA", "fa_IR", "de_DE", "en_US", "hi_IN@numbers=deva"]
        for identifier in locales {
            let locale = Locale(identifier: identifier)
            for value in [-3.25, -1000, 0, 12.5, 4218.75] {
                let shown = ZPDFNumericField.format(value, fractionDigits: 2, locale: locale)
                XCTAssertEqual(
                    ZPDFNumericField.parse(shown), value,
                    "\(identifier): \(value) displayed as \(shown) did not read back"
                )
            }
        }
    }

    /// Old output: `parse("−4")` (typed with the system minus key on a Swedish Mac) was nil.
    func testUnicodeMinusAndNativeDigitsParse() {
        XCTAssertEqual(ZPDFDecimalParser.double("\u{2212}4"), -4)
        XCTAssertEqual(ZPDFDecimalParser.double("\u{2212} 3,5"), -3.5)
        XCTAssertEqual(ZPDFDecimalParser.double("\u{061C}-\u{0663}\u{066B}\u{0662}\u{0665}"), -3.25)
        XCTAssertEqual(ZPDFDecimalParser.double("\u{200E}\u{2212}\u{06F3}\u{066B}\u{06F2}\u{06F5}"), -3.25)
        XCTAssertEqual(ZPDFDecimalParser.double("\u{0967}\u{0968}"), 12)
        // Refusals are unchanged.
        XCTAssertNil(ZPDFDecimalParser.double("1,200.50"))
        XCTAssertNil(ZPDFDecimalParser.double("nan"))
        XCTAssertNil(ZPDFDecimalParser.double("\u{00BD}"), "a vulgar fraction is not a decimal digit")
    }

    // MARK: - BH-130

    /// Old output: `format(2.5, fractionDigits: 0)` was "2" (half-even) while every caller
    /// stores `Int(2.5.rounded())` = 3.
    func testTiesRoundAwayFromZeroLikeTheCallers() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(ZPDFNumericField.format(2.5, fractionDigits: 0, locale: posix), "3")
        XCTAssertEqual(ZPDFNumericField.format(-2.5, fractionDigits: 0, locale: posix), "-3")
        XCTAssertEqual(ZPDFNumericField.format(0.125, fractionDigits: 2, locale: posix), "0.13")
    }

    /// Old output: typing 0 into Depth (0.0001...10000, three decimals) committed 0.0001 and
    /// showed "0".
    func testAClampedSmallValueIsNotShownAsZero() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(ZPDFNumericField.formatBound(0.0001, fractionDigits: 3, locale: posix), "0.0001")
        XCTAssertEqual(ZPDFNumericField.formatBound(0, fractionDigits: 3, locale: posix), "0")
        XCTAssertEqual(ZPDFNumericField.formatBound(12.3456, fractionDigits: 2, locale: posix), "12.35")
        guard case let .value(clamped) = ZPDFNumericField.commitOutcome(
            text: "0", committedText: "", range: 0.0001...10000
        ) else { return XCTFail("0 should clamp") }
        XCTAssertNotEqual(ZPDFNumericField.committedDisplayText(clamped: clamped, readBack: clamped, fractionDigits: 3), "0")
    }

    // MARK: - BH-129 / BH-130 read-back

    /// Old output: after committing 2.5 to a binding that stores `Int(2.5.rounded())`, the field
    /// displayed "2" (its own half-even text) while the getter returned 3.
    func testCommitShowsTheBindingsReadBackValue() {
        XCTAssertEqual(
            ZPDFNumericField.committedDisplayText(clamped: 2.5, readBack: 3, fractionDigits: 0),
            ZPDFNumericField.formatBound(3, fractionDigits: 0)
        )
        XCTAssertEqual(
            ZPDFNumericField.committedDisplayText(clamped: 2.5, readBack: nil, fractionDigits: 1),
            ZPDFNumericField.formatBound(2.5, fractionDigits: 1)
        )
    }

    /// Old output: `.onChange(of: value)` resynced only when unfocused, so a normalising binding
    /// was never reflected while the field kept focus. An untouched focused field now resyncs;
    /// a half-typed edit is still kept.
    func testFocusedFieldResyncsOnlyWhenUntouched() {
        XCTAssertTrue(ZPDFNumericField.shouldResync(isFocused: false, text: "7", committedText: "3"))
        XCTAssertTrue(ZPDFNumericField.shouldResync(isFocused: true, text: "3", committedText: "3"))
        XCTAssertFalse(ZPDFNumericField.shouldResync(isFocused: true, text: "3.", committedText: "3"))
    }

    // MARK: - BH-131

    /// Old output: a colour with no sRGB conversion fell back to `NSColor.white` (Generic Gray)
    /// and `redComponent` raised NSInvalidArgumentException, terminating the process.
    func testAnUnconvertibleColourFallsBackToOpaqueWhite() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let pattern = NSColor(patternImage: image)
        XCTAssertNil(pattern.usingColorSpace(.sRGB), "the fixture must be unconvertible or this proves nothing")
        let rgba = ColorRGBA(nsColor: pattern)
        XCTAssertEqual(rgba, ColorRGBA(red: 1, green: 1, blue: 1, alpha: 1))
    }

    // MARK: - BH-501

    /// Old output: the range floor 0.0001 printed at three decimals as "0", so the help said
    /// "Depth (0 to 10000)" and the invalid reason "outside the allowed range 0 to 10000".
    func testRangeBoundsAreNotDisplayRounded() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(ZPDFNumericField.formatBound(0.0001, fractionDigits: 3, locale: posix), "0.0001")
        XCTAssertEqual(ZPDFNumericField.formatBound(10000, fractionDigits: 3, locale: posix), "10000")
    }
}
#endif
