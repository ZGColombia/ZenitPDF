import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

/// The value crossings between the contract vocabulary and the presentation vocabulary.
///
/// Two packages define a `DecimalQuantity`, a `MarkupKind` and a set of units, and this
/// package is the only place they meet. A silent mistake in one of these switches is a
/// square metre displayed as a metre, so each mapping is asserted total and round-trip
/// stable rather than trusted to look right.
@Suite("Bridges")
struct BridgeTests {

    @Test("Every engine tool has a palette entry and every palette entry an engine tool")
    func toolMappingIsABijection() {
        for tool in MeasurementTool.allCases {
            #expect(MeasurementTool(shown: MeasurementKind(domain: tool)) == tool)
        }
        for kind in MeasurementKind.allCases {
            #expect(MeasurementKind(domain: MeasurementTool(shown: kind)) == kind)
        }
    }

    @Test("Every markup family round-trips")
    func markupKindMappingIsABijection() {
        for kind in ZPDFContracts.MarkupKind.allCases {
            #expect(ZPDFContracts.MarkupKind(shown: ZPDFUIPresentation.MarkupKind(domain: kind)) == kind)
        }
    }

    @Test("Every snap kind round-trips")
    func snapKindMappingIsABijection() {
        for kind in SnapKind.allCases {
            #expect(SnapKind(shown: SnapCandidateKind(domain: kind)) == kind)
        }
    }

    @Test("Every presentation measurement field has a contract origin, and back again")
    func measurementFieldMapping() {
        for field in ZPDFUIPresentation.MeasurementField.allCases {
            let domain = ZPDFContracts.MeasurementField(shown: field)
            #expect(ZPDFUIPresentation.MeasurementField(domain: domain) == field)
            // And the dimensions agree, which is what stops a slope percent being summed
            // into an area.
            #expect(domain.dimension.lengthPower == field.dimension.lengthPower)
            #expect(domain.dimension.angle == field.dimension.angle)
        }
    }

    @Test("The four contract fields with no UI field are the documented four")
    func fieldsWithoutAUICounterpart() {
        let dropped = ZPDFContracts.MeasurementField.allCases.filter {
            ZPDFUIPresentation.MeasurementField(domain: $0) == nil
        }
        #expect(Set(dropped) == [.truePerimeter, .cutoutArea, .planWallArea, .wallArea])
    }

    /// NL-COLLAB-03 / bug GeometryBridge.swift:213. Old output: `cancelled` was shown as
    /// `.rejected`, `resolved` as `.completed` and `inProgress` as `.inReview`, so the same
    /// markup read "Cancelled" in the ledger and "Rejected" in the Inspector.
    @Test("The status picker has the contract's eight states, mapped one to one both ways")
    func statusMapping() {
        #expect(ZPDFUIPresentation.MarkupStatus.allCases.count == ZPDFContracts.MarkupStatus.allCases.count)
        for status in ZPDFContracts.MarkupStatus.allCases {
            let shown = ZPDFUIPresentation.MarkupStatus(domain: status)
            #expect(shown.rawValue == status.rawValue, "\(status) is shown as itself")
            #expect(ZPDFContracts.MarkupStatus(shown: shown) == status, "picking a state writes exactly it")
        }
        #expect(ZPDFUIPresentation.MarkupStatus(domain: .cancelled) == .cancelled)
        #expect(ZPDFUIPresentation.MarkupStatus(domain: .resolved) == .resolved)
        // Tool presets written by older builds stored the in-progress state as "inReview".
        #expect(ZPDFUIPresentation.MarkupStatus(storedValue: "inReview") == .inProgress)
    }

    // MARK: Formatting

    @Test("A metric quantity converts exactly and carries its unit")
    func metricFormatting() {
        let formatter = QuantityFormatter(units: .metric)
        let area = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "498.4")!, dimension: .area)
        #expect(formatter.text(area) == "498.40")
        #expect(formatter.symbol(area) == "m²")
        #expect(formatter.textWithUnit(area) == "498.40 m²")

        let length = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "12.3456")!, dimension: .length)
        #expect(formatter.text(length) == "12.35", "half-even at two places")
    }

    @Test("Millimetres and square feet convert through exact Decimal factors")
    func unitConversion() {
        var units = DisplayUnitSelection.metric
        units.length = .millimetre
        let millimetres = QuantityFormatter(units: units)
        let metre = ZPDFUIPresentation.DecimalQuantity(value: 1, dimension: .length)
        #expect(millimetres.converted(metre) == 1000)
        #expect(millimetres.symbol(metre) == "mm")

        let imperial = QuantityFormatter(units: .imperial)
        let squareMetre = ZPDFUIPresentation.DecimalQuantity(value: 1, dimension: .area)
        // 1 m² = 10.7639104167097 ft², exactly, from 0.3048 m per foot.
        #expect(imperial.symbol(squareMetre) == "ft²")
        let feet = imperial.converted(squareMetre)
        #expect(abs((feet as NSDecimalNumber).doubleValue - 10.76391041670972) < 1e-9)
    }

    @Test("An imperial length reads as feet, inches and a reduced fraction")
    func imperialLengthFormatting() {
        let formatter = QuantityFormatter(units: .imperial)
        func text(_ metres: String) -> String {
            formatter.text(
                ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: metres)!, dimension: .length)
            )
        }
        // 0.3048 m is exactly one foot.
        #expect(text("0.3048") == "1'-0\"")
        // 0.3048 + 0.0254 × 6.5 = 0.4699 m = one foot six and a half inches.
        #expect(text("0.4699") == "1'-6 1/2\"")
        // 0.47625 m = 18.75 in, which reduces 12/16 to 3/4.
        #expect(text("0.47625") == "1'-6 3/4\"")
        // 0.0254 × 0.25 = a quarter inch, reduced from 4/16.
        #expect(text("0.00635") == "0'-0 1/4\"")
        // Below the smallest fraction but not zero: say so rather than printing 0'-0".
        #expect(text("0.00001") == "< 1/16\"")
    }

    @Test("A slope is written in the selected form, from the ratio and never from an angle")
    func slopeFormatting() {
        func text(_ mode: SlopeDisplayMode, ratio: String) -> String {
            var units = DisplayUnitSelection.metric
            units.slope = mode
            return QuantityFormatter(units: units).slopeText(ratio: Decimal(string: ratio)!)
        }
        #expect(text(.percent, ratio: "0.25") == "25.0 %")
        #expect(text(.ratioNToOne, ratio: "0.25") == "0.25:1")
        #expect(text(.ratioOneToN, ratio: "0.25") == "1:4.00")
        #expect(text(.decimal, ratio: "0.25") == "0.2500")
        #expect(text(.degrees, ratio: "1") == "45.0°")
        #expect(text(.ratioOneToN, ratio: "0") == "1:∞", "a flat surface has no 1:n form")
    }

    @Test("Display text does not depend on the process locale")
    func formattingIsLocaleStable() {
        let quantity = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "1234.5")!, dimension: .area)
        let posix = QuantityFormatter(units: .metric, localeIdentifier: "en_US_POSIX")
        let swedish = QuantityFormatter(units: .metric, localeIdentifier: "sv_SE")
        #expect(posix.text(quantity) == "1,234.50")
        #expect(swedish.text(quantity) != posix.text(quantity), "the locale is honoured…")
        #expect(posix.text(quantity) == QuantityFormatter(units: .metric).text(quantity),
                "…and the default is fixed, not inherited from the process")
    }

    @Test("A scale ratio is derived from metres per point, not stored")
    func scaleRatio() throws {
        #expect(ScaleBridge.denominator(metresPerPoint: 0.1) == 283)
        #expect(ScaleBridge.denominator(metresPerPoint: 0) == 1, "a degenerate scale cannot print 1:0")
        #expect(ScaleBridge.denominator(metresPerPoint: .nan) == 1)

        let separate = try ScaleTransform.separateXY(
            id: ScaleID(UUID()),
            metresPerPointX: Decimal(string: "0.1")!,
            metresPerPointY: Decimal(string: "0.2")!,
            units: .metric,
            source: .calibrationXY
        )
        #expect(ScaleBridge.ratioText(for: separate) == "1:283 × 1:567")
    }

    @Test("Colours clamp and round-trip")
    func colourRoundTrip() {
        let colour = RGBAColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let shown = ColorRGBA(domain: colour)
        #expect(shown.red == 0.25)
        #expect(RGBAColor(shown: shown) == colour)

        let outOfRange = RGBAColor(red: 2, green: -1, blue: 0.5, alpha: 3)
        let clamped = ColorRGBA(domain: outOfRange)
        #expect(clamped.red == 1)
        #expect(clamped.green == 0)
        #expect(clamped.alpha == 1)
    }

    @Test("Page geometry crosses unchanged, including a negative crop origin")
    func pageGeometry() throws {
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: DocumentID(UUID()),
            index: 3,
            label: "A-104",
            boxes: PageBoxes(
                media: PDFRect(x: -20, y: -14, width: 2384, height: 1684),
                crop: PDFRect(x: -20, y: -14, width: 2384, height: 1684)
            ),
            rotation: .degrees90
        )
        let shown = ZPDFUIPresentation.PageDescriptor(domain: page)
        #expect(shown.index == 3)
        #expect(shown.label == "A-104")
        #expect(shown.cropBox.origin.x == -20, "a negative crop origin is legal and preserved")
        #expect(shown.rotation == .degrees90)
        #expect(shown.rotatedVisibleSize.width == 1684, "the rotation swaps the axes")
    }

    @Test("A measurement result becomes formatted fields, with the headline first-class")
    func measurementFields() {
        let result = MeasurementResult(values: [
            .planArea: .area(Decimal(string: "518.4")!),
            .netArea: .area(Decimal(string: "498.4")!),
            .perimeter: .length(Decimal(string: "93.6")!)
        ])
        let fields = MarkupBridge.fields(of: result, tool: .area, formatter: QuantityFormatter())
        #expect(fields.count == 3)

        let planArea = fields.first { $0.field == .planArea }
        #expect(planArea?.displayText == "518.40")
        #expect(planArea?.displayUnitSymbol == "m²")
        // X-037: the headline is the net area, the ledger's Plan Area (ADR-0016); the gross
        // outline is a secondary field. Old output: planArea isDerived false, netArea true.
        #expect(planArea?.isDerived == true, "the gross outline is not the Area tool's headline")
        let netArea = fields.first { $0.field == .netArea }
        #expect(netArea?.displayText == "498.40")
        #expect(netArea?.isDerived == false, "netArea is the Area tool's headline")

        let perimeter = fields.first { $0.field == .perimeter }
        #expect(perimeter?.isDerived == true)
        #expect(perimeter?.displayUnitSymbol == "m")

        // The raw SI value travels with the text, so a unit change never needs the engine.
        #expect(planArea?.quantity.value == Decimal(string: "518.4"))
    }

    @Test("Engine warnings the UI has no copy for are dropped, not shown as raw codes")
    func warningMapping() {
        #expect(MeasurementWarningSummary(domain: .selfIntersectingPolygon) == .selfIntersecting)
        #expect(MeasurementWarningSummary(domain: .degenerateArea) == .degenerateGeometry)
        #expect(MeasurementWarningSummary(domain: .numericalPrecisionLoss) == nil)

        let result = MeasurementResult(
            values: [.planArea: .area(1)],
            warnings: [
                MeasurementWarning(code: .selfIntersectingPolygon),
                MeasurementWarning(code: .polygonNormalized),
                MeasurementWarning(code: .numericalPrecisionLoss)
            ]
        )
        // Two codes collapse to one UI warning and the third has no copy, so one survives.
        #expect(MarkupBridge.warnings(of: result) == [.selfIntersecting])
    }

    // MARK: Revision Compare

    /// A comparison result with nothing in it but the alignment the bridge is asked about.
    private static func comparison(
        alignment: AlignmentSolution,
        metrics: AutoAlignmentMetrics? = nil,
        renderScale: Double = 2
    ) -> RevisionComparisonResult {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        return RevisionComparisonResult(
            baselineLabel: "A",
            revisedLabel: "B",
            alignment: alignment,
            autoAlignmentMetrics: metrics,
            autoAlignmentRejection: nil,
            renderScale: renderScale,
            frame: RasterFrame(
                boxRect: box,
                renderedRegion: box,
                rotation: 0,
                scale: renderScale,
                pixelWidth: Int(box.width * renderScale),
                pixelHeight: Int(box.height * renderScale)
            ),
            rasterRegions: [],
            rasterStatistics: RasterDiffStatistics(
                comparedPixelCount: 40_000,
                differingPixelCount: 0,
                addedPixelCount: 0,
                removedPixelCount: 0,
                groupedRegionCount: 0,
                discardedRegionCount: 0
            ),
            vector: nil,
            elapsedNanoseconds: 0,
            wasTruncated: false
        )
    }

    /// What the automatic aligner builds: no correspondences, so no page-point residual,
    /// and the gray-level agreement it measured in its own field (CR-131).
    private static func visionSolution(pixelDissimilarity: Double?) -> AlignmentSolution {
        AlignmentSolution(
            transform: .translation(dx: 3, dy: -2),
            model: .affine,
            provenance: .automaticVision,
            residual: .zero,
            correspondenceCount: 0,
            conditioning: 0.9,
            pixelDissimilarity: pixelDissimilarity
        )
    }

    /// The aligner's evidence for the solution above: 3.7 gray levels apart before the
    /// transform, 0.37 after it, so an improvement of 0.9.
    private static let visionMetrics = AutoAlignmentMetrics(
        meanAbsoluteDifferenceBefore: 3.7,
        meanAbsoluteDifferenceAfter: 0.37,
        candidatesEvaluated: 9
    )

    /// CR-131 follow-up. A Vision alignment has no correspondences, so its page-point
    /// residual is `.zero` by construction and the number the aligner measured lives in
    /// `pixelDissimilarity`. The bridge kept reading the residual.
    ///
    /// Old code: `medianReprojectionErrorPixels: solution.residual.rootMeanSquare *
    /// result.renderScale` — `0 × 2`, whatever the aligner measured. Measured against it:
    /// `Expectation failed: (error → 0.0) == 0.37` here, and the same `(error → 0.0)` for
    /// the metrics fallback below.
    @Test("An automatic alignment reports the gray-level dissimilarity the aligner measured")
    func visionAlignmentReportsItsPixelDissimilarity() {
        let result = Self.comparison(
            alignment: Self.visionSolution(pixelDissimilarity: 0.37),
            metrics: Self.visionMetrics
        )
        guard case let .automatic(inlierRatio, error) = CompareBridge.alignmentState(of: result) else {
            Issue.record("a Vision alignment is presented as automatic")
            return
        }
        #expect(error == 0.37, "the error field carries the measured dissimilarity, not the empty residual")
        #expect(abs(inlierRatio - 0.9) < 1e-12, "the ratio channel is untouched: it is still the improvement")
    }

    /// The comparator rebuilds Vision's refinement in page space, and a rebuilt solution can
    /// arrive here without the field. The metrics recorded the same measurement when the
    /// registration was accepted, so the bridge reads it from there rather than showing 0.
    @Test("A Vision solution without its own measurement reads it from the metrics")
    func visionAlignmentWithoutItsOwnMeasurementFallsBackToTheMetrics() {
        let result = Self.comparison(
            alignment: Self.visionSolution(pixelDissimilarity: nil),
            metrics: Self.visionMetrics
        )
        guard case let .automatic(_, error) = CompareBridge.alignmentState(of: result) else {
            Issue.record("a Vision alignment is presented as automatic")
            return
        }
        #expect(error == 0.37, "the metrics' after-value is the same measurement")
    }

    /// The point-based provenances still report the page-point residual, in rendered
    /// pixels, and a translation-only manual alignment is still presented as the two-point
    /// state with its residual.
    @Test("Point-based alignments keep their reprojection residual, scaled to pixels")
    func pointBasedAlignmentsKeepTheirResidual() {
        func solution(
            _ provenance: AlignmentProvenance, rms: Double, pixelDissimilarity: Double? = nil
        ) -> AlignmentSolution {
            AlignmentSolution(
                transform: .translation(dx: 1, dy: 1),
                model: .similarity,
                provenance: provenance,
                residual: AlignmentResidual(rootMeanSquare: rms, maximum: rms, perCorrespondence: [rms, rms]),
                correspondenceCount: 2,
                conditioning: 1,
                pixelDissimilarity: pixelDissimilarity
            )
        }
        func state(_ solution: AlignmentSolution) -> RevisionAlignmentState {
            CompareBridge.alignmentState(of: Self.comparison(alignment: solution))
        }
        #expect(state(solution(.manualTwoPoint, rms: 0.5)) == .manualTwoPoint(residualPixels: 1.0))
        #expect(state(solution(.manualThreePoint, rms: 0.25)) == .manualThreePoint(residualPixels: 0.5))
        #expect(state(solution(.manualTranslation, rms: 0.75)) == .manualTwoPoint(residualPixels: 1.5))
        // A stray pixel measurement on a point solve does not displace its residual.
        #expect(state(solution(.manualTwoPoint, rms: 0.5, pixelDissimilarity: 9)) == .manualTwoPoint(residualPixels: 1.0))
    }
}
