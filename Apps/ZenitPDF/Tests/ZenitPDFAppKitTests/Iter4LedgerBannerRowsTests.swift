import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 4 re-fix, U-063: the CSV export's filter banner describes the filter its rows
/// were filtered by.
///
/// The banner (ZPDFUILedger's `LedgerExportWriter.describe`) names only the rules
/// `LedgerFilterDiagnostic.isApplied` accepts, and that predicate treats a pattern operand
/// under "is" / "is not" — "Label is /^C-/", a pattern rule whose comparison was changed
/// (BH-712) — as not applied. ZPDFAppCore's seam did not drop such a rule: it crossed as
/// "Label is <nothing>", so the export held 0 rows under a banner saying "No filter applied"
/// (or all rows under "is not"). This suite drives both halves through the shipping
/// `AppLedgerPresenter` and `LedgerCSVExport`, so the banner and the rows are compared in one
/// place.
@Suite("Ledger export banner and rows, loop iteration 4", .appTierSerialised)
struct Iter4LedgerBannerRowsTests {

    @MainActor
    private func makeLedger() async throws -> AppCoreEnvironment {
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
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (subject, label) in [("Wall", "C-01"), ("Slab", "C-02"), ("Slab", "W-01")] {
            try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: subject,
                label: label,
                author: "test",
                geometry: MeasurementGeometry(
                    pageID: page.id,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0),
                        PDFPoint(x: 100, y: 0),
                        PDFPoint(x: 100, y: 80),
                        PDFPoint(x: 0, y: 80)
                    ], isClosed: true))]
                ),
                createdAt: stamp,
                modifiedAt: stamp
            )))
        }
        await environment.ledger.refresh()
        return environment
    }

    /// The banner's description of the presenter's filter, exactly as `LedgerCSVExport` asks for it.
    @MainActor
    private static func bannerDescription(_ presenter: any LedgerPresenting) -> String {
        LedgerExportWriter.describe(filter: presenter.filter, columns: presenter.columns)
    }

    private static func patternRule(_ comparison: LedgerFilterComparison) -> ZPDFUIPresentation.LedgerFilterRule {
        LedgerFilterRule(id: UUID(), column: .label, comparison: comparison, operand: .regex("^C-"))
    }

    @Test("U-063: \"Label is /^C-/\" exports every row with no banner, as the banner's own rule says")
    @MainActor
    func patternOperandAloneFiltersNothing() async throws {
        let environment = try await makeLedger()
        for comparison in [LedgerFilterComparison.equals, .notEquals] {
            environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [Self.patternRule(comparison)]))
            await environment.ledger.refresh()

            // What the banner would say about this filter: nothing is applied.
            #expect(Self.bannerDescription(environment.ledger) == "No filter applied")
            // So the rows are the whole takeoff. Old output: 0 rows for "is" and 3 for "is not",
            // both with isFiltered true and a "Filtered" banner reading "0 of 3 rows" /
            // "3 of 3 rows" beside "No filter applied".
            #expect(environment.ledger.rowCount == 3, "\(comparison)")
            #expect(environment.ledger.isFiltered == false, "\(comparison)")
            #expect(environment.ledger.unappliedFilterRules.map(\.reason) == [.unsupportedComparison], "\(comparison)")
            let csv = LedgerCSVExport.render(presenter: environment.ledger)
            let lines = csv.components(separatedBy: "\r\n").dropLast()
            #expect(!csv.contains(LedgerCSVExport.filteredBannerKey), "\(comparison)")
            #expect(lines.count == 1 + 3, "header and every row: \(Array(lines))")
        }
    }

    @Test("U-063: beside an applied rule, the banner names that rule and the rows are its rows")
    @MainActor
    func patternOperandBesideAnAppliedRule() async throws {
        let environment = try await makeLedger()
        environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            Self.patternRule(.equals),
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .contains, operand: .text("Wall"))
        ]))
        await environment.ledger.refresh()

        let description = Self.bannerDescription(environment.ledger)
        #expect(description == "Subject \(LedgerFilterComparison.contains.displayName) “Wall”")
        // Old output: 0 rows — the pattern operand crossed as "Label is <nothing>" and the group
        // needs every rule — under a banner naming only `Subject contains “Wall”`.
        #expect(environment.ledger.rowCount == 1)
        let banner = try #require(LedgerCSVExport.filterBanner(presenter: environment.ledger).first)
        #expect(banner.contains("1 of 3 rows"), "\(banner)")
        #expect(banner.contains(description), "\(banner)")
        let csv = LedgerCSVExport.render(presenter: environment.ledger)
        let records = csv.components(separatedBy: "\r\n").dropLast().dropFirst(3)
        #expect(records.count == 1)
        #expect(records.allSatisfy { $0.contains("Wall") })
    }
}
