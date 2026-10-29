import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// U-063 (re-fix): a pattern operand kept under a comparison that takes a value
/// — "Label is /^C-/", a pattern rule whose comparison was changed (the BH-712 shape) — is
/// dropped at the seam and reported, exactly like a pattern rule.
///
/// The pane and the export banner (ZPDFUILedger's `LedgerFilterDiagnostic.isApplied`) already
/// treated such a rule as not applied and wrote "No filter applied". The seam did not drop it:
/// `filterValue` turned the `.regex` operand into `.none` and the rule still crossed, so the core
/// matched no row for "is" / "contains" and every row for "is not" / "does not contain" — the
/// export carried 0 rows under a banner saying no filter was applied.
@Suite("Iteration 4 — ledger filter seam, pattern operands")
struct Iter4LedgerPatternOperandSeamTests {

    private static func labelKey() throws -> LedgerColumnID {
        LedgerColumnID(try #require(LedgerColumnSet.standard().column(standard: .label)).key)
    }

    private static func subjectKey() throws -> LedgerColumnID {
        LedgerColumnID(try #require(LedgerColumnSet.standard().column(standard: .subject)).key)
    }

    private static func request(_ rules: [ZPDFUIPresentation.LedgerFilterRule]) -> LedgerRequest {
        LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: rules))
    }

    @Test("U-063: \"Label is /^C-/\" and \"Label is not /^C-/\" are dropped and reported")
    func patternOperandIsDroppedAndReported() throws {
        let columns = try LedgerColumnSet.standard()
        let label = try Self.labelKey()
        let valueComparisons: [LedgerFilterComparison] = [
            .equals, .notEquals, .contains, .notContains, .beginsWith, .endsWith,
            .lessThan, .greaterThanOrEqual, .between, .isAnyOf
        ]
        for comparison in valueComparisons {
            let translation = LedgerSpecBuilder.translate(
                Self.request([ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: label, comparison: comparison, operand: .regex("^C-"))]),
                columns: columns
            )
            // Old output: a spec filter `label <op> .none` (not match-all) and no diagnostic.
            #expect(translation.spec.filter.matchesEverything, "\(comparison) still crossed the seam")
            #expect(
                translation.unappliedFilterRules
                    == [LedgerFilterDiagnostic(column: label, comparison: comparison, reason: .unsupportedComparison)],
                "\(comparison)"
            )
        }

        // A comparison that takes no value ignores the operand, so the rule is still applied —
        // as the pane's predicate says.
        let unary = LedgerSpecBuilder.translate(
            Self.request([ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: label, comparison: .isEmpty, operand: .regex("^C-"))]),
            columns: columns
        )
        #expect(!unary.spec.filter.matchesEverything)
        #expect(unary.unappliedFilterRules.isEmpty)

        // Beside an applied rule, only the pattern operand goes.
        let mixed = LedgerSpecBuilder.translate(
            Self.request([
                ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: label, comparison: .equals, operand: .regex("^C-")),
                ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: try Self.subjectKey(), comparison: .contains, operand: .text("Wall"))
            ]),
            columns: columns
        )
        #expect(!mixed.spec.filter.matchesEverything)
        #expect(mixed.unappliedFilterRules.map(\.reason) == [.unsupportedComparison])
        #expect(!(mixed.unappliedFilterRules.first?.message.isEmpty ?? true))
    }

    @Test("U-063: the ledger rows are the rows the banner describes — all of them, or the Wall rows")
    func rowsMatchWhatTheBannerDescribes() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let wall = MarkupID(UUID())
        for (id, subject, label) in [(wall, "Wall", "C-01"), (MarkupID(UUID()), "Slab", "C-02"), (MarkupID(UUID()), "Slab", "W-01")] {
            _ = try await session.apply(.addMarkup(Self.markup(id: id, documentID: documentID, pageID: page.id, subject: subject, label: label)))
        }
        let label = try Self.labelKey()

        for comparison in [LedgerFilterComparison.equals, .notEquals, .contains, .notContains] {
            let projection = try await session.ledgerProjection(Self.request([
                ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: label, comparison: comparison, operand: .regex("^C-"))
            ]))
            // Old output: 0 rows for "is" / "contains" and 3 for "is not" / "does not contain",
            // isFiltered true, no diagnostic — under the banner "No filter applied".
            #expect(projection.rowCount == 3, "\(comparison)")
            #expect(projection.isFiltered == false, "\(comparison)")
            #expect(projection.unappliedFilterRules.map(\.reason) == [.unsupportedComparison], "\(comparison)")
        }

        // The banner for this one names only `Subject contains “Wall”`; the rows are the Wall row.
        let mixed = try await session.ledgerProjection(Self.request([
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: label, comparison: .equals, operand: .regex("^C-")),
            ZPDFUIPresentation.LedgerFilterRule(id: UUID(), column: try Self.subjectKey(), comparison: .contains, operand: .text("Wall"))
        ]))
        // Old output: 0 rows (the pattern operand matched nothing and the group is "all").
        #expect(mixed.rowCount == 1)
        #expect(mixed.positionByMarkupID[wall.rawValue] == 0)
        #expect(mixed.isFiltered)
        #expect(mixed.unappliedFilterRules.map(\.reason) == [.unsupportedComparison])
    }

    private static func markup(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        subject: String,
        label: String
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: subject,
            label: label,
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }
}
