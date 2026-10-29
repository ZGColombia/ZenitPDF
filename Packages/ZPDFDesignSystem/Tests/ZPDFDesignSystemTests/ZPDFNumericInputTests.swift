#if canImport(XCTest)
import AppKit
import XCTest
@testable import ZPDFDesignSystem

/// Regressions for the numeric input path and the two measured palette defects.
///
/// Wrapped in `#if canImport(XCTest)` for the same reason the rest of the suite is: the package
/// has to build on a machine that only has the Command Line Tools.
@MainActor
final class ZPDFNumericInputTests: XCTestCase {

    // MARK: - CR-166: not a number is not a number

    /// Old output: `ZPDFNumericField.parse("nan")` returned `nan` through the bare
    /// `Double(string)` fallback, `min(max(nan, 1), 40)` returned `nan` rather than clamping,
    /// and the OCR sheet's `Int($0 ?? 1)` on that value trapped with
    /// "Double value cannot be converted to Int because it is either infinite or NaN".
    func testNonFiniteTextIsRefusedRatherThanParsed() {
        for text in ["nan", "NaN", "-nan", "inf", "-inf", "Infinity", "1e", "0x1p3", "  nan  "] {
            XCTAssertNil(ZPDFNumericField.parse(text), "\(text) was accepted as a number")
        }
    }

    /// The consequence the crash came from: a clamp is only a clamp if the input is finite.
    func testCommitClampsIntoRangeAndNeverYieldsNaN() {
        let range: ClosedRange<Double> = 1...40

        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "nan", committedText: "", range: range),
            .invalid
        )
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "999", committedText: "", range: range),
            .value(40)
        )
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "-5", committedText: "", range: range),
            .value(1)
        )

        // Whatever comes out of a commit is safe to hand to `Int(_:)`, which is what the OCR
        // sheet's page-bound bindings do with it.
        guard case let .value(clamped) = ZPDFNumericField.commitOutcome(
            text: "12", committedText: "", range: range
        ) else { return XCTFail("a finite entry did not produce a value") }
        XCTAssertTrue(clamped.isFinite)
        XCTAssertEqual(Int(clamped), 12)
    }

    // MARK: - CR-173: a blur is not an edit

    /// Old output: a stored depth of 0.2005 m displays rounded at three decimals — "0,2" on
    /// this machine's locale, "0.2" on a point-decimal one — and losing focus re-parsed that
    /// string and wrote 0.2 back over the 0.2005 the estimator had entered, firing
    /// `onCommit(0.2)` for an edit nobody made. `commitOutcome` now answers `.unchanged`.
    func testBlurringAnUntouchedFieldCommitsNothing() {
        let stored = 0.2005
        let displayed = ZPDFNumericField.format(stored, fractionDigits: 3)

        // The lossy round trip this defect rode on, pinned rather than assumed: what the field
        // shows does not parse back to what the field holds.
        let reparsed = ZPDFNumericField.parse(displayed)
        XCTAssertNotNil(reparsed)
        XCTAssertNotEqual(reparsed, stored, "the display rounding this defect depends on changed")

        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: displayed, committedText: displayed, range: nil),
            .unchanged
        )
        // Trailing whitespace from a paste is still not an edit.
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: displayed + "  ", committedText: displayed, range: nil),
            .unchanged
        )
    }

    /// An untouched empty field — and an untouched Mixed field, which also renders empty — used
    /// to commit `nil` on every tab through it, clearing the whole multi-selection.
    func testBlurringAnUntouchedEmptyFieldDoesNotClearTheValue() {
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "", committedText: "", range: nil),
            .unchanged
        )
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "   ", committedText: "", range: nil),
            .unchanged
        )
    }

    /// The other half of the rule: a real edit still commits, and a real clear still clears.
    func testARealEditStillCommits() {
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "0.25", committedText: "0.201", range: nil),
            .value(0.25)
        )
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "", committedText: "0.201", range: nil),
            .cleared
        )
        XCTAssertEqual(
            ZPDFNumericField.commitOutcome(text: "wide", committedText: "0.201", range: nil),
            .invalid
        )
    }

    // MARK: - CR-184: one grammar, everywhere

    /// Old output: under `en_US` the field's `NumberFormatter` read "1,234" as 1234 while the
    /// tool-preset field beside it read the same text as 1.234 — a factor of a thousand between
    /// two boxes in one sheet — and "12,5" was rejected by two of the four parsers.
    func testOneCommaIsADecimalMarkAndSpacesAreGrouping() {
        XCTAssertEqual(ZPDFDecimalParser.double("12,5"), 12.5)
        XCTAssertEqual(ZPDFDecimalParser.double("12.5"), 12.5)
        XCTAssertEqual(ZPDFDecimalParser.double("1,234"), 1.234)
        XCTAssertEqual(ZPDFDecimalParser.double("1 200"), 1200)
        XCTAssertEqual(ZPDFDecimalParser.double("1\u{00A0}200"), 1200)
        XCTAssertEqual(ZPDFDecimalParser.double("1\u{202F}200,5"), 1200.5)
        XCTAssertEqual(ZPDFDecimalParser.double("-3.25"), -3.25)
        XCTAssertEqual(ZPDFDecimalParser.decimal("0.2"), Decimal(string: "0.2"))
    }

    /// Ambiguity is refused rather than resolved by luck.
    func testAmbiguousAndNonNumericTextIsRefused() {
        for text in ["1,200.50", "1,200,300", "910x2100", "PLAN 2", "", "   ", "-", "nan", "inf"] {
            XCTAssertNil(ZPDFDecimalParser.double(text), "\(text) was accepted")
            XCTAssertNil(ZPDFDecimalParser.decimal(text), "\(text) was accepted as a Decimal")
        }
    }

    /// The two conversions are one grammar plus a cast, so they cannot disagree.
    func testDoubleAndDecimalAgreeOnWhatIsANumber() {
        let samples = ["0", "5", "12,5", "12.5", "1 200", "1,200.50", "nan", ".5", "5.", "abc", "-0.001"]
        for text in samples {
            XCTAssertEqual(
                ZPDFDecimalParser.double(text) == nil,
                ZPDFDecimalParser.decimal(text) == nil,
                "the two parsers disagree about \(text)"
            )
        }
    }

    /// Exponents are opt-in: a numeric field may take one, a schedule cell may not.
    func testExponentsAreOptIn() {
        XCTAssertNil(ZPDFDecimalParser.double("1e5"))
        XCTAssertEqual(ZPDFDecimalParser.double("1e5", allowingExponent: true), 100_000)
        XCTAssertNil(ZPDFDecimalParser.double("1e999", allowingExponent: true), "an overflow is not finite")
        XCTAssertNotNil(ZPDFNumericField.parse("1e-3"), "the numeric field still takes an exponent")
    }

    /// The grammar does not move when the machine's locale does.
    func testTheGrammarIsLocaleIndependent() {
        // `ZPDFDecimalParser` never touches `Locale.current`, so the assertion that matters is
        // that no locale-shaped input changes the answer.
        XCTAssertEqual(ZPDFDecimalParser.normalized("12,5"), "12.5")
        XCTAssertEqual(ZPDFDecimalParser.normalized("12.5"), "12.5")
        XCTAssertNil(ZPDFDecimalParser.normalized("12'5"))
    }

    // MARK: - CR-194: the Increase Contrast hairline, as rendered

    /// Old output: `border` in `darkHighContrast` was white at alpha 0.28, which composites to
    /// #4B4C4F over the background (2.36:1), #515458 over surface (2.48:1) and #5B6067 over
    /// elevated (2.52:1) — all below the 3:1 WCAG 1.4.11 asks of a control boundary. The old
    /// self-check never measured it because `contrastRatio` ignores alpha, so the declared
    /// pure white scored 18:1.
    func testHighContrastBorderClearsThreeToOneAsRendered() {
        let report = ZPDFSelfCheck.verifyHighContrastBorders()
        XCTAssertGreaterThanOrEqual(report.assertionCount, 6)
        XCTAssertTrue(
            report.passed,
            "border contrast failures:\n" + report.failures.map(\.description).joined(separator: "\n")
        )

        // The measurement itself, pinned, so a palette edit that undoes the fix is visible here
        // rather than only inside the self-check.
        let border = ZPDFColor.rgba(.border, .darkHighContrast)
        XCTAssertEqual(border.alpha, 0.36, accuracy: 0.001)
        for ground in ZPDFSelfCheck.groundTokens {
            let groundValue = ZPDFColor.rgba(ground, .darkHighContrast)
            let ratio = border.composited(over: groundValue).contrastRatio(against: groundValue)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "border on \(ground.rawValue) is \(ratio):1")
        }
    }

    /// The compositing itself, because the whole finding turned on measuring the wrong colour.
    func testCompositingRespectsAlpha() {
        let ground = ZPDFRGBA(hex: 0x000000)
        let half = ZPDFRGBA(hex: 0xFFFFFF, alpha: 0.5).composited(over: ground)
        XCTAssertEqual(half.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(half.alpha, 1)
        XCTAssertEqual(
            ZPDFRGBA(hex: 0x123456).composited(over: ground),
            ZPDFRGBA(hex: 0x123456),
            "an opaque colour must come back untouched"
        )
    }

    // MARK: - CR-195: three grounds, not two

    /// Old output: `background` and `surface` were both #FFFFFF in `lightHighContrast`, so the
    /// canvas backdrop and the panels standing on it were one flat white field in exactly the
    /// appearance chosen by people who need that edge to be obvious.
    func testEveryVariantHasADistinctBackgroundAndSurface() {
        let report = ZPDFSelfCheck.verifyGroundsAreDistinguishable()
        XCTAssertEqual(report.assertionCount, ZPDFAppearanceVariant.allCases.count)
        XCTAssertTrue(
            report.passed,
            "ground failures:\n" + report.failures.map(\.description).joined(separator: "\n")
        )

        for variant in ZPDFAppearanceVariant.allCases {
            XCTAssertNotEqual(
                ZPDFColor.rgba(.background, variant),
                ZPDFColor.rgba(.surface, variant),
                "background == surface in \(variant.rawValue)"
            )
        }
    }

    /// The new background tone still carries text and its own hairline.
    func testTheNewLightHighContrastBackgroundStillCarriesItsContent() {
        let background = ZPDFColor.rgba(.background, .lightHighContrast)
        XCTAssertGreaterThanOrEqual(
            ZPDFColor.rgba(.textPrimary, .lightHighContrast).contrastRatio(against: background),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            ZPDFColor.rgba(.textSecondary, .lightHighContrast).contrastRatio(against: background),
            3.0
        )
    }
}
#endif
