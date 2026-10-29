import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Bug hunt 2, the formatting and bridging layer: every value here is on the quantity or
/// aggregation path, so each assertion is against a hand-derived number (QUALITY_BAR).
///
/// BH-005, 014, 015, 089, 090, 091, 092, 093, 104, 105, 118, 415, 416, 417, 418, 420, 437, 454,
/// 455, 463.
@Suite("Bug hunt 2: formatting and bridging")
struct BugHunt2BridgeTests {

    private func length(_ metres: String) -> ZPDFUIPresentation.DecimalQuantity {
        ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: metres)!, dimension: .length)
    }

    // MARK: BH-005

    @Test("Inches, yards and miles render in their own unit, not as feet")
    func nonFootImperialUnits() {
        func formatter(_ unit: ZPDFUIPresentation.LengthUnit) -> QuantityFormatter {
            var units = DisplayUnitSelection.imperial
            units.length = unit
            return QuantityFormatter(units: units)
        }
        // 36 in = 0.9144 m exactly. Old output: `36'-0"` (36 read as feet) and `36'-0" in`.
        #expect(formatter(.inch).text(length("0.9144")) == "36\"")
        #expect(formatter(.inch).textWithUnit(length("0.9144")) == "36\"")
        // 0.0254 × 6.5 = 0.1651 m = 6 1/2 in.
        #expect(formatter(.inch).text(length("0.1651")) == "6 1/2\"")
        // 1 yd = 0.9144 m: decimal yards. Old output `1'-0"` — a factor of 3 wrong.
        #expect(formatter(.yard).textWithUnit(length("0.9144")) == "1.00 yd")
        // 1 mi = 1609.344 m. Old output `1'-0"` — a factor of 5280 wrong.
        #expect(formatter(.mile).textWithUnit(length("1609.344")) == "1.00 mi")
        // The foot is unchanged.
        #expect(formatter(.foot).text(length("0.4699")) == "1'-6 1/2\"")
        #expect(formatter(.foot).textWithUnit(length("0.3048")) == "1'-0\"")
    }

    // MARK: BH-420

    @Test("A NaN or astronomical length in feet renders instead of trapping")
    func imperialNonFiniteDoesNotTrap() {
        let formatter = QuantityFormatter(units: .imperial)
        // Old behaviour: `Int(...)` trapped and took the app down.
        #expect(formatter.text(ZPDFUIPresentation.DecimalQuantity(value: .nan, dimension: .length)) == "NaN")
        let huge = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "1e30")!, dimension: .length)
        #expect(formatter.text(huge) == "∞")
    }

    // MARK: BH-089, BH-090, BH-415

    @Test("Successful normalisations and a confirmed extreme scale do not block the commit")
    func warningMapping() {
        // Old output: `.degenerateGeometry` (blocking) for both normalisations.
        #expect(MeasurementWarningSummary(domain: .duplicatePointsCollapsed) == nil)
        #expect(MeasurementWarningSummary(domain: .openPolygonClosedImplicitly) == nil)
        // A genuinely collapsed shape still blocks.
        #expect(MeasurementWarningSummary(domain: .degenerateArea) == .degenerateGeometry)
        #expect(MeasurementWarningSummary(domain: .fewerThanThreeUniquePoints) == .degenerateGeometry)
        // Old output: `.missingScale` — "no calibrated scale", blocking, on a calibrated page.
        #expect(MeasurementWarningSummary(domain: .extremeScale) == nil)
    }

    // MARK: BH-092, BH-093

    @Test("The page's /UserUnit reaches the region panel, the archive name and the trace")
    func userUnitReachesEveryRatio() throws {
        let page = PageID(UUID())
        // 1:100 on a /UserUnit 2 page: 0.0254 × 100 × 2 / 72 m per page unit.
        let factor = Decimal(string: "0.0254")! * 200 / 72
        let scale = try ScaleTransform.uniform(
            id: ScaleID(UUID()), pageID: page, metresPerPoint: factor, units: .metric, source: .preset
        )
        // Old output everywhere: "1:200".
        #expect(ScaleBridge.ratioText(for: scale, userUnit: 2) == "1:100")
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page, name: "Detail",
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)],
            scaleID: scale.id, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0)
        )
        #expect(region.summary(scale: scale, pageLabel: "A", userUnit: 2).scale.displayString == "1:100")
        let row = try TakeoffArchive.scaleRecord(from: scale, pageId: page.rawValue.uuidString, savedAt: "2026-01-01T00:00:00Z", userUnit: 2)
        #expect(row.name == "1:100")
        #expect(MeasurementTraceResolver.text(for: scale, userUnit: 2) == "1:100")
        #expect(ScaleBridge.statusText(for: scale, units: .metric, userUnit: 2) == "1:100 @ 1.00 m")
        // BH-093 old output: "1:200 @ 0.30ft" — a foot's size in metres labelled `ft`.
        #expect(ScaleBridge.statusText(for: scale, units: .imperial, userUnit: 2) == "1:100 @ 1.00 ft")
    }

    // MARK: BH-416, BH-418

    @Test("Rise, run, depth and height get no totals slot; a slope-ratio heading reads like its cells")
    func aggregateRuleAndSlopeHeading() {
        func standard(_ column: StandardLedgerColumn, _ dimension: ZPDFContracts.QuantityDimension) -> LedgerColumnDefinition {
            LedgerColumnDefinition(id: ColumnID(UUID()), key: column.rawValue, title: column.rawValue, kind: .number, standard: column, dimension: dimension)
        }
        // Old output: `.sum` for all four — a labelled, permanently blank totals slot.
        for column in [StandardLedgerColumn.rise, .run, .depth, .height] {
            #expect(LedgerBridge.aggregate(for: standard(column, .length)) == nil, "\(column)")
        }
        #expect(LedgerBridge.aggregate(for: standard(.planLength, .length)) == .sum)
        #expect(LedgerBridge.aggregate(for: standard(.planArea, .area)) == .sum)

        var units = DisplayUnitSelection.metric
        units.slope = .percent
        let heading = LedgerBridge.groupTitle(
            .number(ZPDFContracts.DecimalQuantity(value: Decimal(string: "0.5")!, dimension: .ratio)),
            definition: standard(.slopeRatio, .ratio),
            formatter: QuantityFormatter(units: units)
        )
        // Old output "0.5"; a ratio of 0.5 is 50.0 % in percent mode, as the cells read.
        #expect(heading == "50.0 %")
    }

    // MARK: BH-091, BH-417

    @Test("A mixed-unit total says so; an empty total is not a unit conflict")
    func refusedAndEmptyTotals() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let column = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "custom.extent", title: "Extent", kind: .number, dimension: .length
        )
        try await session.addCustomColumns([column])
        func count(_ value: ZPDFContracts.DecimalQuantity) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .count, tool: .count,
                subject: "Doors", author: "t",
                geometry: MeasurementGeometry(pageID: page.id, countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 1, y: 1))]),
                customValues: [column.id: .number(value)],
                createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        try await session.apply(.addMarkup(count(.init(value: 2, dimension: .length))))
        try await session.apply(.addMarkup(count(.init(value: 3, dimension: .area))))
        let totals = try await session.ledgerProjection(.flat).grandTotals
        let extent = LedgerColumnID(column.key)
        #expect(totals.incompatibleColumns.contains(extent), "2 m + 3 m² cannot be added")
        // Old output: "" — a blank cell for a refused total (QUALITY_BAR A11).
        #expect(!totals.displayValue(extent).isEmpty)
        // A ledger of counts has no plan area at all. Old output: planArea in incompatibleColumns.
        #expect(!totals.incompatibleColumns.contains(LedgerColumnID("planArea")))
        #expect(LedgerBridge.refusalText(.mixedDimensions([.length, .area])) == "Mixed units")
    }

    // MARK: BH-104, BH-105, BH-437

    @Test("Repeat × refuses fractions, zero and out-of-range values; the cell shows the multiplier in force")
    func repeatColumn() {
        let definition = RepetitionColumn.definition()
        func stored(_ text: String) -> ZPDFContracts.LedgerCellValue {
            .number(ZPDFContracts.DecimalQuantity(value: Decimal(string: text)!, dimension: .ratio))
        }
        // The write path. Old output: every one of these stored verbatim.
        #expect(LedgerBridge.domainCellValue(.number(Decimal(string: "2.9")!), definition: definition) == nil)
        #expect(LedgerBridge.domainCellValue(.number(0), definition: definition) == nil)
        #expect(LedgerBridge.domainCellValue(.number(-3), definition: definition) == nil)
        #expect(LedgerBridge.domainCellValue(.number(Decimal(string: "1e19")!), definition: definition) == nil)
        #expect(LedgerBridge.domainCellValue(.number(6), definition: definition) == stored("6"))
        #expect(LedgerBridge.domainCellValue(.empty, definition: definition) == .empty)

        // The read path, on values already on disk: one number for cell, badge and total.
        func quantity(_ text: String) -> ZPDFContracts.DecimalQuantity {
            ZPDFContracts.DecimalQuantity(value: Decimal(string: text)!, dimension: .ratio)
        }
        #expect(RepetitionColumn.effectiveCount(of: quantity("2.9")) == 2)
        #expect(RepetitionColumn.effectiveCount(of: quantity("0")) == nil)
        // Old output: platform-dependent (Int.max or Int.min) for 1e19.
        #expect(RepetitionColumn.effectiveCount(of: quantity("1e19")) == nil)
        let formatter = QuantityFormatter()
        // Old output "2.9" beside a ×2 total; and "0" beside a ×1 total.
        #expect(LedgerBridge.quantityCell(quantity("2.9"), definition: definition, formatter: formatter).1 == "2")
        #expect(LedgerBridge.quantityCell(quantity("0"), definition: definition, formatter: formatter).1 == "1")
    }

    // MARK: BH-014, BH-118, BH-455

    @Test("A dual notation's paper hint decides, even when both ratios score 1.0")
    func paperHintBreaksATieAtTheClamp() throws {
        let parser = ScaleNotationParser()
        let engine = ScaleProposalEngine()
        // A3 landscape: 1190.55 × 841.89 pt.
        let a3 = PDFSizeValue(width: 1190.55, height: 841.89)
        let spaced = parser.candidates(inLine: "SKALA 1:100, 1:200 (A3)")
        // Old output: 1:100 — both clamped to 1.0 and the tie fell to reading order.
        #expect(engine.proposal(from: spaced, pageBoxSizeInPoints: a3)?.ratio.denominator == 200)

        // BH-118: no space after the comma. Old output: one candidate, 1:100, carrying the hint.
        let tight = parser.candidates(inLine: "SKALA 1:100,1:200 (A3)")
        #expect(tight.map(\.ratio.denominator) == [100, 200])
        #expect(tight.first?.paperSizeHint == nil)
        #expect(engine.proposal(from: tight, pageBoxSizeInPoints: a3)?.ratio.denominator == 200)

        // BH-455: a comma decimal is a decimal. Old output: 1:2 at full confidence.
        #expect(parser.candidates(inLine: "SKALA 1:2,5").isEmpty)
        #expect(parser.candidates(inLine: "SKALA 1:2.5").isEmpty)
        #expect(parser.candidates(inLine: "SKALA 1:50").map(\.ratio.denominator) == [50])
    }

    // MARK: BH-454

    @Test("An invalid /UserUnit is refused rather than silently ignored")
    func invalidUserUnitThrows() throws {
        let ratio = try #require(ScaleRatio(numerator: 1, denominator: 100))
        // Old output: the /UserUnit 1 factor, 0.0254 × 100 / 72.
        #expect(throws: (any Error).self) { try ratio.metresPerPoint(userUnit: 0) }
        #expect(throws: (any Error).self) { try ratio.metresPerPoint(userUnit: .nan) }
        // Hand-derived: 0.0254 × 100 × 2 / 72 = 0.0705555… m per page unit.
        let doubled = try ratio.metresPerPoint(userUnit: 2)
        #expect(abs(doubled - 0.0254 * 200 / 72) < 1e-15)
    }

    // MARK: BH-015, BH-463

    @Test("The legend counts marks, not records, and keeps glyph variants distinct")
    func legendCountsMarks() {
        let page = PageID(UUID())
        func count(_ marks: Int, symbol: MarkupSymbol?) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .count, tool: .count,
                subject: "Drains", author: "t",
                geometry: MeasurementGeometry(pageID: page, countPoints: (0..<marks).map {
                    CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: Double($0), y: 0))
                }),
                symbol: symbol,
                createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        // One Count commit of forty clicks. Old output: ×1.
        let forty = CountSymbolLegend.entries(markups: [count(40, symbol: nil)])
        #expect(forty.map(\.markCount) == [40])
        let two = CountSymbolLegend.entries(markups: [count(40, symbol: nil), count(2, symbol: nil)])
        #expect(two.map(\.markCount) == [42])

        // Same artwork under two glyph names: two rows. Old output: both ids "Drains|<digest>".
        let digest = String(repeating: "a", count: 64)
        let variants = CountSymbolLegend.entries(markups: [
            count(1, symbol: MarkupSymbol(artworkDigest: digest, kind: .vector, builtInGlyph: "filledCircle")),
            count(1, symbol: MarkupSymbol(artworkDigest: digest, kind: .vector, builtInGlyph: "cross"))
        ])
        #expect(variants.count == 2)
        #expect(Set(variants.map(\.id)).count == 2)
    }
}
