import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-MEASURE-03: a value kept under an older scale
/// (Keep Existing Values, ADR-0030 §2) carries a visible "Older scale" badge in its ledger row, in
/// words, and the ledger can be narrowed to exactly those rows. Old output: the row read like any
/// other, and nothing narrowed to it.
@MainActor
struct LedgerOlderScaleTests {

    /// One page at 100 pt = 10 m (0.1 m/pt); line A 50 pt = 5 m, line B 30 pt = 3 m. Then the page
    /// is recalibrated to 100 pt = 20 m keeping existing values: A and B stay 5 m and 3 m, flagged,
    /// and a new line C of 50 pt measures 10 m at the new scale.
    private static func setUp() async throws -> (AppCoreEnvironment, TakeoffSession, kept: [MarkupID], fresh: MarkupID) {
        let documentID = NLMeasureScaleEntryTests.documentID
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        let a = NLMeasureScaleEntryTests.length(on: page.id, from: (0, 0), to: (50, 0))
        let b = NLMeasureScaleEntryTests.length(on: page.id, from: (0, 20), to: (30, 20))
        _ = try await session.apply(.addMarkup(a))
        _ = try await session.apply(.addMarkup(b))
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 20, knownLengthUnit: .metre, keepExisting: true)
        let c = NLMeasureScaleEntryTests.length(on: page.id, from: (0, 40), to: (50, 40))
        _ = try await session.apply(.addMarkup(c))
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, [a.id, b.id], c.id)
    }

    @Test("A kept value's row leads its Type cell with the words; a current value's does not")
    func badge() async throws {
        let (_, session, kept, fresh) = try await Self.setUp()
        let projection = try await session.ledgerProjection(.flat)
        let type = LedgerColumnID(StandardLedgerColumn.icon.rawValue)
        var texts: [UUID: String] = [:]
        for index in 0..<projection.rowCount {
            guard let row = projection.row(at: index) else { continue }
            texts[row.markupID] = row.displayValues[type]
        }
        for id in kept {
            #expect(texts[id.rawValue]?.hasPrefix("⚠ Older scale · ") == true, "\(texts[id.rawValue] ?? "")")
        }
        #expect(texts[fresh.rawValue]?.contains("Older scale") == false)
        #expect(LedgerOlderScale.badge == "⚠ Older scale")
    }

    @Test("The older-scale filter keeps exactly the kept rows; their total is the kept values, 5 + 3 = 8 m")
    func filter() async throws {
        let (_, session, kept, _) = try await Self.setUp()
        let planLength = LedgerColumnID("planLength")
        let everything = try await session.ledgerProjection(.flat)
        #expect(everything.rowCount == 3)
        // By hand: 5 m + 3 m (kept) + 10 m (current) = 18 m — the kept values stay in the total.
        #expect(everything.grandTotals.total(planLength)?.value == 18)
        var request = LedgerRequest.flat
        request.onlyOlderScaleValues = true
        let older = try await session.ledgerProjection(request)
        #expect(older.rowCount == 2)
        #expect(Set((0..<older.rowCount).compactMap { older.row(at: $0)?.markupID }) == Set(kept.map(\.rawValue)))
        #expect(older.grandTotals.total(planLength)?.value == 8)
        #expect(older.isFiltered)
        // The export narrows the same way.
        let report = try await session.exportReportWithDiagnostics(title: "T", request: request).report
        #expect(report.rows.count == 2)
    }

    @Test("The ledger presenter counts the kept rows and narrows to them on request")
    func presenter() async throws {
        let (environment, _, _, _) = try await Self.setUp()
        await environment.ledger.refresh()
        #expect(environment.ledger.olderScaleRowCount == 2)
        #expect(environment.ledger.rowCount == 3)
        environment.ledger.setShowsOnlyOlderScaleValues(true)
        #expect(environment.ledger.request.onlyOlderScaleValues)
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 2)
        #expect(environment.ledger.olderScaleRowCount == 2, "counted over every row, filtered or not")
        environment.ledger.setShowsOnlyOlderScaleValues(false)
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 3)
    }
}
