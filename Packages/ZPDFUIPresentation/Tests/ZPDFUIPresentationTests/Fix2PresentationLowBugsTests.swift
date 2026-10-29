import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Bug hunt 2, the low-severity presentation findings, grouped.
@Suite("Fix2 presentation low findings")
@MainActor
struct Fix2PresentationLowBugsTests {

    /// BH-798. Old output: `five < three` false and `three < five` false for a count of 5 and a
    /// ratio of 3 — neither ordered, yet unequal, so sorting a mixed column was undefined.
    @Test("A count and a ratio are strictly ordered")
    func countAndRatioOrder() {
        let five = DecimalQuantity.count(5)
        let three = DecimalQuantity(value: 3, dimension: .ratio)
        #expect((five < three) != (three < five))
        #expect(!(five < five))
    }

    private func column(_ id: LedgerColumnID, _ dimension: QuantityDimension) -> LedgerColumn {
        LedgerColumn(id: id, title: id.rawValue, kind: .number, dimension: dimension, width: 100, alignment: .trailing, aggregate: .sum)
    }

    private func row(_ values: [LedgerColumnID: LedgerCellValue]) -> LedgerRow {
        LedgerRow(markupID: UUID(), values: values, displayValues: [:],
                  colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), kind: .count)
    }

    /// BH-764. Old output: `.number(12).dimension` was `.ratio` while `asQuantity(inColumn: nil)`
    /// minted a `.count`.
    @Test("A free-typed number's dimension agrees with the quantity it becomes")
    func numberDimensionAgrees() {
        let cell = LedgerCellValue.number(12)
        #expect(cell.dimension == cell.asQuantity(inColumn: nil)?.dimension)
    }

    /// BH-766. Old output: a formula column with one "Formula error" cell totalled the other
    /// rows (total 5) instead of refusing. Since R-138 this rule lives only in the mock totals
    /// the sample data and previews are built from; the shipped totals are the core
    /// aggregator's (ZPDFAppCore `LedgerBridge.totals`).
    @Test("An error cell in a numeric column fails the total")
    func errorCellFailsTheTotal() {
        let id = LedgerColumnID.custom("formula")
        let rows = [row([id: .quantity(.count(5))]), row([id: .text("Formula error")])]
        let totals = LedgerTotals.mockSumming(rows: rows, columns: [column(id, .count)]) { _, q in "\(q.value)" }
        #expect(totals.total(id) == nil)
    }

    /// BH-788 / BH-790. Old output: "Kitchen, Room, 1 markups", "A-101, 1 pages".
    @Test("Singular counts read in the singular")
    func singularCounts() {
        let zone = ProjectZoneSummary(id: UUID(), name: "Kitchen", kind: .room, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0), markupCount: 1)
        #expect(zone.accessibilityLabel.hasSuffix("1 markup"), "\(zone.accessibilityLabel)")
        let tab = DocumentTabSummary(id: UUID(), title: "A-101", fileName: "A-101.pdf", pageCount: 1)
        #expect(tab.accessibilityLabel == "A-101, 1 page")
        let many = DocumentTabSummary(id: UUID(), title: "A", fileName: "A.pdf", pageCount: 3)
        #expect(many.accessibilityLabel == "A, 3 pages")
    }

    /// BH-787. Old output: "Walls, doors, Öppningar" and "Doors"/"doors" split apart.
    @Test("Preset categories sort as a person reads them")
    func categoriesSortLocaleAware() {
        let names = ["Walls", "doors", "Doors", "Öppningar", "areas"]
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(sorted.first == "areas")
        #expect(abs((sorted.firstIndex(of: "doors") ?? 0) - (sorted.firstIndex(of: "Doors") ?? 9)) == 1)
    }

    /// BH-791. Old output: "Fatal error: Double value cannot be converted to Int because it is
    /// either infinite or NaN".
    @Test("A non-finite index progress does not trap")
    func nonFiniteProgress() {
        #expect(GeometryIndexStatus.building(progress: .nan).displayName.contains("0"))
        #expect(GeometryIndexStatus.building(progress: .infinity).displayName.contains("0"))
        #expect(GeometryIndexStatus.building(progress: 7).displayName.contains("100"))
    }

    /// BH-792. Old output: `toolIndicatorText(namedBy: "Place · Door Count")` appended the
    /// previous tool's "Area needs 3 more points…" note.
    @Test("A nil note means no qualifier")
    func nilNoteMeansNoQualifier() {
        var snapshot = ZenitSampleProject.shared.statusBar
        snapshot.activeToolNote = "Area needs 3 more points before it can be finished."
        #expect(snapshot.toolIndicatorText(namedBy: "Place · Door Count") == "Place · Door Count")
        #expect(snapshot.toolIndicatorText(namedBy: "Place", note: "x").hasSuffix("x"))
    }

    /// BH-793. Old output: decoding `"red": 2` kept 2, and `1e300` trapped `hexString`.
    @Test("A decoded colour is clamped")
    func decodedColourIsClamped() throws {
        let json = #"{"red":1e300,"green":-4,"blue":0.5,"alpha":2}"#
        let colour = try JSONDecoder().decode(ColorRGBA.self, from: Data(json.utf8))
        #expect(colour.red == 1 && colour.green == 0 && colour.alpha == 1)
        #expect(colour.hexString == "#FF0080")
        let roundTrip = try JSONDecoder().decode(ColorRGBA.self, from: JSONEncoder().encode(colour))
        #expect(roundTrip == colour)
    }
}
