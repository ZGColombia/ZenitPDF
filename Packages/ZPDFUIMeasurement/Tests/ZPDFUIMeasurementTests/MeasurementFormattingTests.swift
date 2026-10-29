import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Covers the imperial half of calibration entry, the display formatter and the option models
/// the measurement surfaces are driven by.
@Suite("Measurement formatting and options")
struct MeasurementFormattingTests {

    private func metres(feet: Double = 0, inches: Double = 0) -> Double {
        feet * 0.3048 + inches * ImperialLengthFormatter.metresPerInch
    }

    // MARK: Imperial formatting

    @Test("Feet and inches are written with a reduced fraction")
    func reducedFraction() {
        #expect(
            ImperialLengthFormatter.string(metres: metres(feet: 12, inches: 6.5), precision: .sixteenth)
                == "12' 6 1/2\""
        )
    }

    @Test("Whole feet carry no inch part")
    func wholeFeet() {
        #expect(ImperialLengthFormatter.string(metres: metres(feet: 9), precision: .sixteenth) == "9'")
    }

    @Test("Inches-only formatting for the inch unit")
    func inchesOnly() {
        #expect(
            ImperialLengthFormatter.string(metres: metres(inches: 6.25), precision: .quarter, showsFeet: false)
                == "6 1/4\""
        )
    }

    @Test("Precision controls the rounding, from whole to a sixteenth")
    func precisionRounding() {
        let value = metres(inches: 6.3)
        #expect(ImperialLengthFormatter.string(metres: value, precision: .whole, showsFeet: false) == "6\"")
        #expect(ImperialLengthFormatter.string(metres: value, precision: .quarter, showsFeet: false) == "6 1/4\"")
        #expect(ImperialLengthFormatter.string(metres: value, precision: .sixteenth, showsFeet: false) == "6 5/16\"")
    }

    @Test("A sixty-fourth is representable")
    func sixtyFourth() {
        #expect(
            ImperialLengthFormatter.string(
                metres: metres(inches: 1 + 1.0 / 64.0),
                precision: .sixtyFourth,
                showsFeet: false
            ) == "1 1/64\""
        )
    }

    @Test("Rounding up carries into the next foot")
    func carriesIntoNextFoot() {
        #expect(
            ImperialLengthFormatter.string(metres: metres(feet: 11, inches: 11.99), precision: .half) == "12'"
        )
    }

    @Test("Negative values keep their sign")
    func negativeKeepsSign() {
        #expect(
            ImperialLengthFormatter.string(metres: -metres(feet: 2, inches: 3), precision: .quarter) == "-2' 3\""
        )
    }

    // MARK: Imperial parsing

    @Test("The full feet-inch-fraction form parses")
    func parsesFullForm() {
        #expect(abs((ImperialLengthFormatter.parseInches("12' 6 1/2\"") ?? 0) - 150.5) < 1e-9)
    }

    @Test("The hyphenated form parses")
    func parsesHyphenated() {
        #expect(abs((ImperialLengthFormatter.parseInches("12'-6\"") ?? 0) - 150) < 1e-9)
    }

    @Test("Word units parse")
    func parsesWordUnits() {
        #expect(abs((ImperialLengthFormatter.parseInches("12 ft 6 in") ?? 0) - 150) < 1e-9)
        #expect(abs((ImperialLengthFormatter.parseInches("3 feet") ?? 0) - 36) < 1e-9)
    }

    @Test("A bare number is read as inches and a bare fraction works")
    func parsesBareForms() {
        #expect(abs((ImperialLengthFormatter.parseInches("18") ?? 0) - 18) < 1e-9)
        #expect(abs((ImperialLengthFormatter.parseInches("3/8") ?? 0) - 0.375) < 1e-9)
    }

    @Test("Smart quotes parse")
    func parsesSmartQuotes() {
        #expect(abs((ImperialLengthFormatter.parseInches("4\u{2019} 3\u{201D}") ?? 0) - 51) < 1e-9)
    }

    @Test("A negative entry stays negative so the validator can block it")
    func negativeEntryStaysNegative() {
        let inches = ImperialLengthFormatter.parseInches("-2' 6\"")
        #expect(inches != nil)
        #expect((inches ?? 0) < 0)
    }

    @Test("Text that is not a length is rejected rather than guessed")
    func rejectsNonLengths() {
        #expect(ImperialLengthFormatter.parseInches("about six feet") == nil)
        #expect(ImperialLengthFormatter.parseInches("") == nil)
        #expect(ImperialLengthFormatter.parseInches("   ") == nil)
        #expect(ImperialLengthFormatter.parseInches("6/0") == nil)
    }

    @Test("Formatting and parsing round-trip at 1/64")
    func roundTrip() {
        let original = metres(feet: 7, inches: 4 + 37.0 / 64.0)
        let inches = ImperialLengthFormatter.parseInches(
            ImperialLengthFormatter.string(metres: original, precision: .sixtyFourth)
        )
        #expect(abs((inches ?? 0) * ImperialLengthFormatter.metresPerInch - original) < 1e-9)
    }

    // MARK: Value formatter

    @Test("The ratio string matches the standard architectural scales")
    func ratioString() {
        let fifty = MeasurementUnitCatalog.metresPerPagePoint * 50
        #expect(MeasurementValueFormatter.ratioString(metresPerPagePoint: fifty) == "1:50")
    }

    @Test("An uncalibrated page does not get a fake ratio")
    func uncalibratedRatio() {
        #expect(!MeasurementValueFormatter.ratioString(metresPerPagePoint: 0).hasPrefix("1:"))
    }

    // MARK: Bulk scale target

    @Test("A reversed or out-of-bounds page range is refused")
    func pageRangeValidation() {
        #expect(!BulkScaleSelection(kind: .pageRange, rangeStart: 8, rangeEnd: 3).isRangeValid(pageCount: 20))
        #expect(!BulkScaleSelection(kind: .pageRange, rangeStart: 1, rangeEnd: 21).isRangeValid(pageCount: 20))
        #expect(!BulkScaleSelection(kind: .pageRange, rangeStart: nil, rangeEnd: 4).isRangeValid(pageCount: 20))
        #expect(BulkScaleSelection(kind: .pageRange, rangeStart: 3, rangeEnd: 8).isRangeValid(pageCount: 20))
    }

    @Test("Non-range targets ignore the range fields")
    func nonRangeTargets() {
        #expect(BulkScaleSelection(kind: .entireDocument).isRangeValid(pageCount: 20))
        #expect(BulkScaleSelection(kind: .currentPage).rangeIssue(pageCount: 20) == nil)
    }

    // MARK: Crossing outcomes

    @Test("A crossing offers exactly the three legal outcomes")
    func crossingOutcomes() {
        let pageID = UUID()
        let scale = ScaleSummary(
            id: UUID(),
            name: "Plan",
            displayString: "1:50",
            isUniform: true,
            sx: 0.0176,
            sy: 0.0176,
            unit: .metre,
            version: 1,
            locked: false
        )
        let region = ScaleRegionSummary(
            id: UUID(),
            name: "Detail",
            pageID: pageID,
            pageLabel: "A-201",
            scale: scale,
            boundary: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 10, y: 0), PDFPointValue(x: 10, y: 10)],
            priority: 10,
            locked: false,
            colorRGBA: ColorRGBA(hex: 0x50D6DE)
        )
        let crossing = ScaleRegionCrossing(
            id: UUID(),
            measurementName: "Area",
            pageLabel: "A-201",
            regions: [region],
            canSplitAtBoundary: true,
            pageDefaultScale: scale
        )

        let options = crossing.offeredResolutions
        #expect(options.contains(.splitAtBoundary))
        #expect(options.contains(.useScale(regionID: region.id)))
        #expect(options.contains(.useScale(regionID: nil)))
        #expect(options.contains(.block))
    }

    @Test("Geometry that cannot be cut is not offered a split")
    func crossingWithoutSplit() {
        let crossing = ScaleRegionCrossing(
            id: UUID(),
            measurementName: "Count",
            pageLabel: "A-201",
            regions: [],
            canSplitAtBoundary: false,
            pageDefaultScale: nil
        )
        #expect(!crossing.offeredResolutions.contains(.splitAtBoundary))
        #expect(crossing.offeredResolutions == [.block])
    }
}
