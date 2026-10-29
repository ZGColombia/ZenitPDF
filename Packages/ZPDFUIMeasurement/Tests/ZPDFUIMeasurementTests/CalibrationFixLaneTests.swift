import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Bug hunt 2, calibration: the known-length entry, the imperial grammar and the validator.
///
/// Every sequence here is driven through `CalibrationLengthEntry` — the pure value the length
/// field runs on — and through `resolvingPendingLengths` + `CalibrationValidator`, exactly as
/// the sheet's Apply does, so nothing is put on anybody's screen.
@Suite("Calibration fixes (bug hunt 2)")
struct CalibrationFixLaneTests {

    private func draft(
        length: Double? = nil,
        unit: LengthUnit = .metre,
        from start: PDFPointValue = PDFPointValue(x: 0, y: 0),
        to end: PDFPointValue = PDFPointValue(x: 100, y: 0)
    ) -> CalibrationDraft {
        CalibrationDraft(
            primary: CalibrationAxisInput(start: start, end: end, knownLength: length),
            unitIdentifier: unit.rawValue,
            name: "Plan"
        )
    }

    // MARK: BH-046 — Return republished the rounded echo

    /// Old output: after Return the field rewrote itself to `12' 7"` while still focused, the
    /// text change was published as pending text, and Apply committed 12.5833 ft for a typed
    /// `12' 6 1/2"` (12.5417 ft).
    @Test("BH-046: Return then Apply commits the exact typed length, not the rounded echo")
    func returnKeepsExactLength() throws {
        var entry = CalibrationLengthEntry()
        entry.beginEditing()
        entry.text = "12' 6 1/2\""
        entry.textDidChange(isFocused: true)
        #expect(entry.pendingText == "12' 6 1/2\"")

        entry.commit(unit: .foot, precision: .whole)      // Return
        entry.textDidChange(isFocused: true)              // the view sees its own rewrite
        #expect(entry.text == "12' 7\"", "the display is rounded to whole inches")
        #expect(entry.pendingText == "", "old output: pendingText == \"12' 7\\\"\"")

        let resolved = draft(length: entry.length, unit: .foot)
            .resolvingPendingLengths(primary: entry.pendingText)
        let length = try #require(resolved.primary.knownLength)
        #expect(abs(length - 150.5 / 12) < 1e-12, "old output: 12.5833 ft")
    }

    @Test("BH-046: metric beyond four decimals survives Return too")
    func returnKeepsExactMetricLength() {
        var entry = CalibrationLengthEntry()
        entry.text = "2.123456"
        entry.textDidChange(isFocused: true)
        entry.commit(unit: .metre, precision: .sixteenth)
        entry.textDidChange(isFocused: true)
        #expect(entry.pendingText == "")
        #expect(entry.length == 2.123456)
    }

    // MARK: BH-248 — blur re-parsed the echo

    /// Old output: click back in and tab out without typing, and `2.1235` overwrote `2.123456`.
    @Test("BH-248: focusing and leaving without typing keeps the exact stored length")
    func blurDoesNotReparseEcho() {
        var entry = CalibrationLengthEntry()
        entry.text = "2.123456"
        entry.textDidChange(isFocused: true)
        entry.commit(unit: .metre, precision: .sixteenth)   // blur
        #expect(entry.length == 2.123456)

        entry.beginEditing()                                  // click back in
        entry.commit(unit: .metre, precision: .sixteenth)   // tab out, nothing typed
        #expect(entry.length == 2.123456, "old output: 2.1235")

        // Imperial at 1/16: 10' 3/32" rounds to 10' 1/8" on screen, not in storage.
        var imperial = CalibrationLengthEntry()
        imperial.text = "10' 3/32\""
        imperial.textDidChange(isFocused: true)
        imperial.commit(unit: .foot, precision: .sixteenth)
        let exact = imperial.length
        imperial.beginEditing()
        imperial.commit(unit: .foot, precision: .sixteenth)
        #expect(imperial.length == exact)
    }

    @Test("BH-248: retyping exactly the rounded echo commits what was typed")
    func retypingTheEchoIsAnEdit() {
        var entry = CalibrationLengthEntry()
        entry.text = "2.123456"
        entry.textDidChange(isFocused: true)
        entry.commit(unit: .metre, precision: .sixteenth)
        let echo = entry.text
        entry.beginEditing()
        entry.text = ""
        entry.textDidChange(isFocused: true)
        entry.text = echo
        entry.textDidChange(isFocused: true)
        #expect(entry.pendingText == echo)
        entry.commit(unit: .metre, precision: .sixteenth)
        #expect(entry.length != 2.123456, "typed over, so the typed value wins")
    }

    @Test("BH-248: a real edit after the echo is still committed")
    func realEditAfterEchoCommits() {
        var entry = CalibrationLengthEntry()
        entry.text = "2.123456"
        entry.textDidChange(isFocused: true)
        entry.commit(unit: .metre, precision: .sixteenth)
        entry.beginEditing()
        entry.text = "3"
        entry.textDidChange(isFocused: true)
        #expect(entry.pendingText == "3")
        entry.commit(unit: .metre, precision: .sixteenth)
        #expect(entry.length == 3)
    }

    // MARK: BH-249 — the range was only a glyph

    /// Old output: 1 500 000 mm over 500 pt is 3 m/pt, inside the plausible band, so no issue
    /// was raised and Apply committed a length the field itself called out of range.
    @Test("BH-249: an out-of-range positive length blocks Apply")
    func outOfRangeBlocks() {
        let validation = CalibrationValidator.validate(
            draft(length: 1_500_000, unit: .millimetre, to: PDFPointValue(x: 500, y: 0))
        )
        #expect(validation.issues.contains(.outOfRangePrimaryLength))
        #expect(!validation.canApply, "old output: canApply == true")
    }

    @Test("BH-249: the range warning survives the blur that syncs the field")
    func rangeWarningSurvivesSync() {
        var entry = CalibrationLengthEntry()
        entry.text = "1500000"
        entry.textDidChange(isFocused: true)
        entry.commit(unit: .millimetre, precision: .sixteenth)
        #expect(entry.hasRangeError)
        entry.lengthDidChange(to: 1_500_000, isFocused: false, unit: .millimetre, precision: .sixteenth)
        #expect(entry.hasRangeError, "old output: syncFromLength cleared hasRangeError")
    }

    // MARK: BH-250 — identical-point floor

    /// Old output: 2.5 pt apart earned only `.shortPrimaryBaseline`, and Apply was live for a
    /// calibration `ScaleTransform.calibratedTwoPoint` refuses below 4 pt.
    @Test("BH-250: points closer than the contract's 4 pt floor are blocked")
    func contractFloorIsHonoured() {
        let validation = CalibrationValidator.validate(
            draft(length: 1, to: PDFPointValue(x: 2.5, y: 0))
        )
        #expect(validation.issues.contains(.identicalPrimaryPoints))
        #expect(!validation.canApply)
        #expect(CalibrationValidator.identicalPointTolerance == 4.0)
    }

    // MARK: BH-251 — confirmations

    @Test("BH-251: a ticked confirmation stays listed and can be taken back")
    func tickedConfirmationStaysListed() {
        var extreme = draft(length: 5, unit: .kilometre)
        extreme.confirmsExtremeScale = true
        let validation = CalibrationValidator.validate(extreme)
        #expect(validation.issues.contains(.extremeScale), "old output: the issue vanished with its checkbox")
        #expect(validation.canApply)
    }

    /// Old output: the tick survived a change to a different, also-extreme length, and Apply
    /// committed it with no warning.
    @Test("BH-251: changing what decides the scale clears the confirmation")
    func confirmationClearsOnScaleChange() {
        var extreme = draft(length: 5, unit: .kilometre)
        extreme.confirmsExtremeScale = true
        let before = extreme.scaleInputs

        extreme.primary.knownLength = 50
        extreme.clearConfirmationsIfScaleChanged(from: before)
        #expect(!extreme.confirmsExtremeScale)
        #expect(!CalibrationValidator.validate(extreme).canApply)

        // Renaming changes no number, so the tick stays.
        var renamed = draft(length: 5, unit: .kilometre)
        renamed.confirmsExtremeScale = true
        let unchanged = renamed.scaleInputs
        renamed.name = "Site"
        renamed.clearConfirmationsIfScaleChanged(from: unchanged)
        #expect(renamed.confirmsExtremeScale)
    }

    // MARK: BH-252 — separate axes solve for the page axes

    /// A drawing stretched 10 % in Y: 0.01 m/pt along X, 0.011 m/pt along Y.
    private func realLength(dx: Double, dy: Double, sx: Double = 0.01, sy: Double = 0.011) -> Double {
        ((sx * dx) * (sx * dx) + (sy * dy) * (sy * dy)).squareRoot()
    }

    /// Old output: a 45° and a 135° line of equal page length gave sx == sy and a 0.00 %
    /// residual on a genuinely stretched drawing, and Apply committed both wrong scales.
    @Test("BH-252: mirror-image lines cannot separate the axes and are blocked")
    func mirroredLinesAreBlocked() {
        let length = realLength(dx: 100, dy: 100)
        let mirrored = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0), end: PDFPointValue(x: 100, y: 100), knownLength: length
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 100, y: 0), end: PDFPointValue(x: 0, y: 100), knownLength: length
            ),
            name: "Stretched"
        )
        let validation = CalibrationValidator.validate(mirrored)
        #expect(validation.issues.contains(.mirroredAxes))
        #expect(!validation.canApply, "old output: canApply == true with sx == sy")
    }

    @Test("BH-252: tilted lines recover the true page-axis scales")
    func tiltedLinesRecoverAxisScales() throws {
        let tilted = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0), end: PDFPointValue(x: 100, y: 20),
                knownLength: realLength(dx: 100, dy: 20)
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0), end: PDFPointValue(x: 10, y: 100),
                knownLength: realLength(dx: 10, dy: 100)
            ),
            name: "Stretched"
        )
        let validation = CalibrationValidator.validate(tilted)
        #expect(validation.canApply, "Issues: \(validation.issues.map(\.rawValue))")
        let preview = try #require(validation.preview)
        #expect(abs(preview.sx - 0.01) < 1e-12)
        #expect(abs(preview.sy - 0.011) < 1e-12)
        // Old output: sx = L1 / |line1| ≈ 0.010038, sy = L2 / |line2| ≈ 0.010950.
    }

    @Test("BH-252: lengths no axis stretch can satisfy are refused")
    func inconsistentLengthsAreRefused() {
        let draft = CalibrationDraft(
            mode: .separateAxes,
            primary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0), end: PDFPointValue(x: 100, y: 0), knownLength: 1
            ),
            secondary: CalibrationAxisInput(
                start: PDFPointValue(x: 0, y: 0), end: PDFPointValue(x: 100, y: 100), knownLength: 0.5
            ),
            name: "Wrong"
        )
        #expect(CalibrationValidator.validate(draft).issues.contains(.inconsistentAxes))
    }

    // MARK: BH-742 — yards and miles

    /// Old output: `180"` next to a `yd` suffix, and `63360"` next to `mi`.
    @Test("BH-742: yards and miles render in their own unit")
    func yardsAndMilesRenderInTheirUnit() {
        let yards = CalibrationLengthEntry.displayText(5, unit: .yard, precision: .sixteenth, locale: Locale(identifier: "en_US"))
        let miles = CalibrationLengthEntry.displayText(1, unit: .mile, precision: .sixteenth, locale: Locale(identifier: "en_US"))
        #expect(yards == "5")
        #expect(miles == "1")
        #expect(CalibrationLengthEntry.roundingEcho(length: 5, unit: .yard, precision: .sixteenth) == nil)
        #expect(CalibrationLengthEntry.roundingEcho(length: 5, unit: .foot, precision: .sixteenth) != nil)
    }

    // MARK: BH-743 — non-ASCII digits

    /// Old output: under `ar_SA` the echo was `١٢٫٥`, which the ASCII grammar reads as not a
    /// length, so the next blur blocked Apply.
    @Test("BH-743: the metric echo re-parses under every locale")
    func metricEchoReparses() {
        for identifier in ["ar_SA", "fa_IR", "sv_SE", "en_US", "de_DE", "hi_IN@numbers=deva"] {
            let text = CalibrationLengthField.metricString(12.5, locale: Locale(identifier: identifier))
            #expect(ZPDFDecimalParser.double(text) == 12.5, "\(identifier): \(text)")
        }
        #expect(CalibrationLengthField.metricString(12.5, locale: Locale(identifier: "sv_SE")) == "12,5")
    }

    // MARK: BH-049 / BH-050 — no-break spaces

    /// Old output: `.length(100)` — 1 200 inches, a twelfth of the intended scale.
    @Test("BH-049: an NBSP-grouped number under feet is refused like its plain-space twin")
    func nbspGroupedNumberIsRefused() {
        #expect(CalibrationPendingLength.reading("1\u{00A0}200", unit: .foot) == .unusable)
        #expect(CalibrationPendingLength.reading("1\u{202F}200", unit: .foot) == .unusable)
        #expect(CalibrationPendingLength.reading("1 200", unit: .foot) == .unusable)
    }

    /// Old output: 30.5 inches (`61/2`).
    @Test("BH-050: an NBSP inside a mixed number splits it")
    func nbspMixedNumberParses() throws {
        let inches = try #require(ImperialLengthFormatter.parseInches("6\u{00A0}1/2\""))
        #expect(abs(inches - 6.5) < 1e-12)
        let feet = try #require(ImperialLengthFormatter.parseInches("12'\u{00A0}6\u{202F}1/2\""))
        #expect(abs(feet - 150.5) < 1e-12)
    }

    // MARK: BH-247 — a mixed number is the popup's unit

    /// Old output: `6 1/2` under feet was 6.5 inches (0.5417 ft) while `6.5` was 6.5 ft.
    @Test("BH-247: 6 1/2 and 6.5 mean the same thing under a feet popup")
    func mixedNumberUsesPopupUnit() {
        #expect(CalibrationPendingLength.reading("6 1/2", unit: .foot) == .length(6.5))
        #expect(CalibrationPendingLength.reading("6.5", unit: .foot) == .length(6.5))
        #expect(CalibrationPendingLength.reading("1/2", unit: .yard) == .length(0.5))
        // A mark still says inches.
        switch CalibrationPendingLength.reading("6 1/2\"", unit: .foot) {
        case let .length(value): #expect(abs(value - 6.5 / 12) < 1e-12)
        default: Issue.record("a marked inch entry stopped parsing")
        }
        #expect(CalibrationPendingLength.reading("12 6", unit: .foot) == .unusable)
    }

    // MARK: BH-752 — non-finite imperial values

    /// Old output: `Int(ticks)` trapped and took the process down.
    @Test("BH-752: NaN, infinite and huge lengths format without trapping")
    func nonFiniteImperialFormatting() {
        #expect(ImperialLengthFormatter.string(metres: .nan, precision: .sixteenth) == "NaN")
        #expect(ImperialLengthFormatter.string(metres: .infinity, precision: .sixteenth) == "∞")
        #expect(ImperialLengthFormatter.string(metres: -.infinity, precision: .sixteenth) == "-∞")
        #expect(!ImperialLengthFormatter.string(metres: 1e20, precision: .sixtyFourth).isEmpty)
    }

    // MARK: IM-017 — say what is wrong

    @Test("IM-017: unreadable text is reported as unreadable, not as missing")
    func unparseableIsNotMissing() {
        let resolved = draft().resolvingPendingLengths(primary: "12x")
        let issues = CalibrationValidator.validate(resolved).issues
        #expect(issues.contains(.unparseablePrimaryLength))
        #expect(!issues.contains(.missingPrimaryLength))

        var entry = CalibrationLengthEntry()
        entry.text = "12x"
        entry.textDidChange(isFocused: true)
        entry.commit(unit: .foot, precision: .sixteenth)
        let message = entry.errorMessage(unit: .foot) ?? ""
        #expect(message.contains("12x"))
        #expect(message.contains("12' 6 1/2\""))
        #expect(entry.errorMessage(unit: .metre)?.contains("5.5") == true)
    }

    // MARK: IM-101 — seed from the last scale

    @Test("IM-101: a new draft starts in the unit and mode of the last scale")
    func seededDraft() {
        let last = ScaleSummary(
            id: UUID(), name: "Plan", displayString: "1/8\" = 1'-0\"", isUniform: true,
            sx: 0.0254 / 72 * 96, sy: 0.0254 / 72 * 96, unit: .foot, version: 1, locked: false
        )
        let seeded = CalibrationDraft.seeded(from: last, precision: .eighth)
        #expect(seeded.unitIdentifier == LengthUnit.foot.rawValue)
        #expect(seeded.showsImperialPrecision)
        #expect(seeded.mode == .uniform)
        #expect(seeded.imperialPrecision == .eighth)
        #expect(CalibrationDraft.seeded(from: nil).unitIdentifier == LengthUnit.metre.rawValue)
    }

    // MARK: IM-102 — focus the length when the last point lands

    @Test("IM-102: the length field takes focus when picking finishes")
    func focusMovesToLength() {
        let uniform = draft()
        #expect(CalibrationSheet.lengthFieldToFocus(from: .primaryEnd, to: .done, draft: uniform) == .primary)
        #expect(CalibrationSheet.lengthFieldToFocus(from: .primaryStart, to: .primaryEnd, draft: uniform) == nil)
        #expect(CalibrationSheet.lengthFieldToFocus(from: .done, to: .done, draft: uniform) == nil)

        var separate = draft(length: 4)
        separate.mode = .separateAxes
        #expect(CalibrationSheet.lengthFieldToFocus(from: .yAxisEnd, to: .done, draft: separate) == .secondary)
    }

    // MARK: IM-016 — drawing scale

    @Test("IM-016: 1:50 on an A1 sheet calibrates with no points picked")
    func drawingScaleOnA1() throws {
        var draft = CalibrationDraft(
            mode: .drawingScale,
            name: "Plan",
            drawingScaleDenominator: 50,
            pageSizePoints: PDFSizeValue(width: 2384, height: 1684)
        )
        #expect(draft.nextPickStep == .done)
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.canApply, "Issues: \(validation.issues.map(\.rawValue))")
        #expect(!validation.issues.contains { $0.severity == .advisory })
        let scale = try #require(CalibrationValidator.makeScaleSummary(from: draft))
        #expect(abs(scale.sx - 50 * 0.0254 / 72) < 1e-15)
        #expect(scale.sy == scale.sx)
        #expect(scale.displayString == "1:50")

        draft.drawingScaleDenominator = nil
        #expect(CalibrationValidator.validate(draft).issues == [.missingDrawingScale])
    }

    @Test("IM-016: a non-standard page size earns the true-paper-size advisory")
    func drawingScaleOnOddPage() {
        let draft = CalibrationDraft(
            mode: .drawingScale,
            drawingScaleDenominator: 96,
            pageSizePoints: PDFSizeValue(width: 1000, height: 700)
        )
        let validation = CalibrationValidator.validate(draft)
        #expect(validation.issues.contains(.nonStandardPaperSize))
        #expect(validation.canApply, "an advisory, not a block")
        #expect(StandardPaperSize.match(PDFSizeValue(width: 792, height: 612)) == "ANSI A")
        #expect(DrawingScalePreset.imperial.contains { $0.denominator == 96 })
    }
}
