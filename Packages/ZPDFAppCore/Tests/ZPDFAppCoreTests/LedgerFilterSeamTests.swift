import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// CR-52 and CR-56: what crosses the ledger filter seam, and what the seam admits it dropped.
@Suite("Ledger filter seam")
struct LedgerFilterSeamTests {

    private static func statusColumn() throws -> LedgerColumnDefinition {
        try #require(LedgerColumnSet.standard().column(standard: .status))
    }

    // MARK: CR-52

    @Test("A text operand on a Choice column crosses as the option's identity")
    func choiceOperandsResolve() throws {
        let status = try Self.statusColumn()
        let open = LedgerIdentifiers.choiceOptionID(for: .open)
        let resolved = LedgerIdentifiers.choiceOptionID(for: .resolved)

        // Old output: `.text("open")`, which the evaluator never matches against a choice cell.
        #expect(LedgerSpecBuilder.filterValue(.text("open"), column: status) == .choice(open))
        // Case and spacing are a person's, not the store's.
        #expect(LedgerSpecBuilder.filterValue(.text("Open"), column: status) == .choice(open))
        #expect(LedgerSpecBuilder.filterValue(.text(open.rawValue.uuidString), column: status) == .choice(open))
        // Old output: `.textSet(["open", "resolved"])`.
        #expect(
            LedgerSpecBuilder.filterValue(.choices(["open", "resolved"]), column: status)
                == .choiceSet([open, resolved])
        )
        // A value no option carries is not invented: it matches nothing, and says so as text.
        #expect(LedgerSpecBuilder.filterValue(.text("nonsense"), column: status) == .text("nonsense"))
        #expect(LedgerSpecBuilder.filterValue(.choices(["nonsense"]), column: status) == .choiceSet([]))
        // A text column keeps text semantics.
        let subject = try #require(LedgerColumnSet.standard().column(standard: .subject))
        #expect(LedgerSpecBuilder.filterValue(.text("open"), column: subject) == .text("open"))
        #expect(LedgerSpecBuilder.filterValue(.choices(["a", "b"]), column: subject) == .textSet(["a", "b"]))
    }

    @Test("A Status rule narrows the ledger to the rows in that status")
    func statusRuleMatchesRows() async throws {
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
        let open = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(Self.markup(id: open, documentID: documentID, pageID: page.id, status: .open)))
        _ = try await session.apply(.addMarkup(Self.markup(documentID: documentID, pageID: page.id, status: .resolved)))
        _ = try await session.apply(.addMarkup(Self.markup(documentID: documentID, pageID: page.id, status: .none)))

        let statusKey = LedgerColumnID(try Self.statusColumn().key)
        func request(_ comparison: LedgerFilterComparison, _ operand: LedgerFilterOperand) -> LedgerRequest {
            LedgerRequest(filter: LedgerFilterGroup(
                id: UUID(),
                rules: [LedgerFilterRule(id: UUID(), column: statusKey, comparison: comparison, operand: operand)]
            ))
        }

        // Old output: 0 rows for "is Open", 3 rows for "is not Open", 0 rows for "is any of".
        let isOpen = try await session.ledgerProjection(request(.equals, .text("open")))
        #expect(isOpen.rowCount == 1)
        #expect(isOpen.positionByMarkupID[open.rawValue] == 0)
        #expect(try await session.ledgerProjection(request(.notEquals, .text("open"))).rowCount == 2)
        #expect(try await session.ledgerProjection(request(.isAnyOf, .choices(["open", "resolved"]))).rowCount == 2)
        #expect(isOpen.unappliedFilterRules.isEmpty)
    }

    // MARK: CR-56

    @Test("A pattern rule and a display-column rule are reported, not silently dropped")
    func droppedRulesAreNamed() throws {
        let columns = try LedgerColumnSet.standard()
        let subjectKey = LedgerColumnID(try #require(columns.column(standard: .subject)).key)
        let request = LedgerRequest(filter: LedgerFilterGroup(
            id: UUID(),
            rules: [
                LedgerFilterRule(id: UUID(), column: subjectKey, comparison: .matchesRegex, operand: .regex("^Slab")),
                LedgerFilterRule(id: UUID(), column: LedgerDefaultColumns.valueColumnID, comparison: .greaterThan, operand: .number(10)),
                LedgerFilterRule(id: UUID(), column: LedgerColumnID("no-such-column"), comparison: .equals, operand: .text("x")),
                LedgerFilterRule(id: UUID(), column: subjectKey, comparison: .contains, operand: .text("Slab"))
            ]
        ))

        let translation = LedgerSpecBuilder.translate(request, columns: columns)
        // Old behaviour: `spec(for:columns:)` returned a spec with the one `contains` rule and no
        // account of the three it left out; the builder reported "applied".
        #expect(translation.unappliedFilterRules.count == 3)
        #expect(translation.unappliedFilterRules.map(\.reason) == [
            .unsupportedComparison, .displayOnlyColumn, .unknownColumn
        ])
        #expect(translation.unappliedFilterRules.first?.column == subjectKey)
        #expect(translation.unappliedFilterRules.first?.comparison == .matchesRegex)
        #expect(!translation.spec.filter.matchesEverything, "the rule that could be applied still is")
        for diagnostic in translation.unappliedFilterRules {
            #expect(!diagnostic.message.isEmpty)
        }
    }

    @Test("The diagnostics reach the projection and the ledger presenter")
    @MainActor
    func diagnosticsReachThePresenter() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let subjectKey = LedgerColumnID(try #require(LedgerColumnSet.standard().column(standard: .subject)).key)

        environment.ledger.setFilter(LedgerFilterGroup(
            id: UUID(),
            rules: [LedgerFilterRule(id: UUID(), column: subjectKey, comparison: .matchesRegex, operand: .regex(".*"))]
        ))
        await environment.ledger.refresh()

        // Old state: `unappliedFilterRules` did not exist; `isFiltered` read false and nothing
        // said the pattern rule had gone.
        #expect(environment.ledger.unappliedFilterRules.map(\.reason) == [.unsupportedComparison])
        #expect(environment.ledger.isFiltered == false)
    }

    private static func markup(
        id: MarkupID = MarkupID(UUID()),
        documentID: DocumentID,
        pageID: PageID,
        status: ZPDFContracts.MarkupStatus
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            author: "test",
            status: status,
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
