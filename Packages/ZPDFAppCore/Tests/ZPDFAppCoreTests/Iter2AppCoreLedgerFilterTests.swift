import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore: C-01 (reversed number range) and C-02 (disabled rules are skipped).
@Suite("Iter2 appcore: ledger filter seam")
struct Iter2AppCoreLedgerFilterTests {

    /// 100 pt = 10 m on a Letter sheet, with a 10 m × 8 m (80 m²) and a 10 m × 2 m (20 m²) area.
    private static func session() async throws -> TakeoffSession {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        for height in [80.0, 20.0] {
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            _ = try await session.apply(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement,
                tool: .area, subject: "Slab", author: "test",
                geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: height), PDFPoint(x: 0, y: height)
                ], isClosed: true))]),
                createdAt: stamp, modifiedAt: stamp
            )))
        }
        return session
    }

    private static func request(_ rules: [ZPDFUIPresentation.LedgerFilterRule]) -> LedgerRequest {
        LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: rules))
    }

    // MARK: C-01

    @Test("A number range typed high-to-low is the same band as low-to-high")
    func reversedNumberRange() async throws {
        // Old output: `.numberRange(lower: 12, upper: 5)`, which no value satisfies.
        #expect(LedgerSpecBuilder.filterValue(.numberRange(lower: 12, upper: 5)) == .numberRange(lower: 5, upper: 12))
        #expect(LedgerSpecBuilder.filterValue(.numberRange(lower: 5, upper: 12)) == .numberRange(lower: 5, upper: 12))
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_700_086_400)
        #expect(LedgerSpecBuilder.filterValue(.dateRange(start: late, end: early)) == .dateRange(lower: early, upper: late))

        // End to end: Plan Area between 100 and 50 keeps the 80 m² slab and drops the 20 m² one.
        let session = try await Self.session()
        let planArea = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .planArea)).key)
        let reversed = try await session.ledgerProjection(Self.request([
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: planArea, comparison: .between, operand: .numberRange(lower: 100, upper: 50))
        ]))
        // Old output: 0 rows.
        #expect(reversed.rowCount == 1)
        let ordered = try await session.ledgerProjection(Self.request([
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: planArea, comparison: .between, operand: .numberRange(lower: 50, upper: 100))
        ]))
        #expect(ordered.rowCount == 1)
        #expect(reversed.positionByMarkupID == ordered.positionByMarkupID)
    }

    // MARK: C-02

    @Test("A disabled rule takes no part in the spec and is not reported as dropped")
    func disabledRulesAreSkipped() async throws {
        let columns = try LedgerColumnSet.standard()
        let subject = LedgerColumnID(try #require(columns.column(standard: .subject)).key)
        let rules = [
            // Would match nothing if it were applied.
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: subject, comparison: .equals, operand: .text("Roof"), isEnabled: false),
            // Would be reported as an unknown column if it were read.
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: LedgerColumnID("no-such-column"), comparison: .equals,
                             operand: .text("x"), isEnabled: false),
            // Would be reported as unsupported if it were read.
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: subject, comparison: .matchesRegex, operand: .regex("^S"), isEnabled: false)
        ]
        let translation = LedgerSpecBuilder.translate(Self.request(rules), columns: columns)
        #expect(translation.spec.filter.matchesEverything)
        #expect(translation.unappliedFilterRules.isEmpty)

        // Nested groups skip disabled rules too, and an enabled sibling still applies.
        let nested = LedgerRequest(filter: LedgerFilterGroup(id: UUID(), groups: [
            LedgerFilterGroup(id: UUID(), rules: rules + [
                ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: subject, comparison: .equals, operand: .text("Slab"))
            ])
        ]))
        let nestedSpec = LedgerSpecBuilder.translate(nested, columns: columns)
        #expect(!nestedSpec.spec.filter.matchesEverything)
        #expect(nestedSpec.unappliedFilterRules.isEmpty)

        let session = try await Self.session()
        #expect(try await session.ledgerProjection(Self.request(rules)).rowCount == 2)
        #expect(try await session.ledgerProjection(nested).rowCount == 2)
        // Enabling the "Roof" rule does empty the ledger, so the rule itself is live.
        var enabled = rules[0]
        enabled.isEnabled = true
        #expect(try await session.ledgerProjection(Self.request([enabled])).rowCount == 0)
    }
}
