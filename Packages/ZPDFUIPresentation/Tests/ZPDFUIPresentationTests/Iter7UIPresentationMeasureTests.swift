import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Quality-loop iteration 7, area "ui-presentation-measure": an area's headline is its net area
/// and the two area fields carry the ledger's names (X-037); an Angle row's Value comes from the
/// producer's stored cell, not from a Slope Angle column the tool never writes (X-038).
@Suite("Iteration 7 ui-presentation-measure (area headline, angle Value)")
@MainActor
struct Iter7UIPresentationMeasureTests {

    // MARK: - X-037

    @Test("X-037: an area tool's headline is the net area; a cutout's is its own area")
    func areaHeadlineField() {
        // Old output: .planArea for all five.
        #expect(MeasurementKind.area.primaryField == .netArea)
        #expect(MeasurementKind.rectangleArea.primaryField == .netArea)
        #expect(MeasurementKind.ellipseArea.primaryField == .netArea)
        #expect(MeasurementKind.polygonCutout.primaryField == .planArea)
        #expect(MeasurementKind.ellipseCutout.primaryField == .planArea)
        // Every other headline is unchanged.
        #expect(MeasurementKind.wallArea.primaryField == .wallArea)
        #expect(MeasurementKind.trueSlopedArea.primaryField == .trueArea)
        #expect(MeasurementKind.volume.primaryField == .volume)
    }

    @Test("X-037: the area fields take the ledger's column names, Plan Area (net) and Gross Area")
    func areaFieldNames() {
        // Old output: planArea "Plan Area" (the gross outline), netArea "Net Area".
        #expect(MeasurementField.planArea.displayName == "Gross Area")
        #expect(MeasurementField.netArea.displayName == "Plan Area")
        let net = MeasurementFieldSummary(field: .netArea, quantity: .squareMetres(84), displayText: "84.00", displayUnitSymbol: "m²")
        #expect(net.accessibilityValue == "Plan Area, 84.00 m²")
    }

    /// A slab with an opening: outline 100 m², net 84 m² (hand-derived: 10 × 10 − 4 × 4).
    private static func slab() -> MarkupSummary {
        MarkupSummary(
            id: UUID(), kind: .measurement, measurementKind: .area,
            subject: "Slab", label: "Slab A", pageLabel: "A-101", pageID: UUID(), pageIndex: 0,
            author: "A. Berg", colorRGBA: ColorRGBA(red: 0, green: 0.5, blue: 1, alpha: 1),
            measurementFields: [
                MeasurementFieldSummary(field: .planArea, quantity: .squareMetres(100), displayText: "100.00",
                                        displayUnitSymbol: "m²", isDerived: true),
                MeasurementFieldSummary(field: .netArea, quantity: .squareMetres(84), displayText: "84.00",
                                        displayUnitSymbol: "m²"),
                MeasurementFieldSummary(field: .perimeter, quantity: .metres(40), displayText: "40.00",
                                        displayUnitSymbol: "m", isDerived: true)
            ],
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: .zero
        )
    }

    @Test("X-037: the markup's headline and its VoiceOver label read the net 84.00 m²")
    func markupHeadlineIsNet() throws {
        let slab = Self.slab()
        let headline = try #require(slab.primaryField)
        // Old output: the planArea field, "100.00 m²".
        #expect(headline.field == .netArea)
        #expect(headline.displayTextWithUnit == "84.00 m²")
        #expect(slab.accessibilityLabel.contains("84.00 m²"), "\(slab.accessibilityLabel)")
        #expect(!slab.accessibilityLabel.contains("100.00"), "old output: the outline was spoken")
    }

    @Test("X-037: the sample's Plan Area value facts name the net field the column reads")
    func sampleValueFactsNameTheNetField() throws {
        let ledger = MockLedgerPresenter()
        let row = try #require((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }
            .first { $0.measurementKind == .area && $0.quantity(.planArea) != nil })
        let model = try #require(ledger.derivation(for: row.markupID))
        let keys = model.sections.first { $0.key == "values" }?.facts.map(\.key) ?? []
        #expect(keys.contains("value.netArea.si"), "\(keys)")
        #expect(!keys.contains("value.planArea.si"), "old output: the net column's value named the gross field")
    }

    // MARK: - X-038

    @Test("X-038: an angle has no candidate column; it no longer claims Slope Angle")
    func angleHasNoCandidateColumn() {
        // Old output: [.slopeAngle], a column the Angle tool has never written (ADR-0019 §2.1).
        #expect(LedgerDefaultColumns.primaryCandidates(for: .angle).isEmpty)
        #expect(LedgerDefaultColumns.primaryCandidates(for: .slope).contains(.slopeAngle))
    }

    @Test("X-038: a row's stored Value cell is its primary quantity, as its Value text is")
    func storedValueCellIsThePrimaryQuantity() throws {
        // 90° in radians, as the engine stores it; the producer wrote the Value and Unit cells.
        let rightAngle = DecimalQuantity(value: Decimal(Double.pi / 2), dimension: .angle)
        let row = LedgerRow(
            markupID: UUID(),
            values: [LedgerDefaultColumns.valueColumnID: .quantity(rightAngle)],
            displayValues: [LedgerDefaultColumns.valueColumnID: "90.00", LedgerDefaultColumns.unitColumnID: "°"],
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), kind: .measurement, measurementKind: .angle
        )
        #expect(LedgerDefaultColumns.valueText(for: row) == "90.00")
        #expect(LedgerDefaultColumns.unitText(for: row) == "°")
        // Old output: nil — the text said 90.00 while the quantity behind it was missing.
        #expect(LedgerDefaultColumns.primaryQuantity(for: row) == rightAngle)

        // A row with no stored Value still reads its candidate columns.
        let length = LedgerRow(
            markupID: UUID(), values: [.planLength: .quantity(.metres(12))], displayValues: [.planLength: "12.00 m"],
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), kind: .measurement, measurementKind: .length
        )
        #expect(LedgerDefaultColumns.primaryQuantity(for: length) == .metres(12))
    }
}
