import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// A filtered export must say that it is filtered.
///
/// The application's CSV exporter writes whatever the presenter is showing, and the save
/// panel it sits behind promises "the Quantity Ledger as it is on screen". With a filter
/// on, that file is a subset of the takeoff shaped exactly like the whole takeoff — and
/// the person who receives it has no way to tell. QUALITY_BAR A35 rules that out, and the
/// projection has carried `filterDescription` and `totalRowCountBeforeFilter` all along;
/// what was missing was a caller.
///
/// Driven through the shipping `AppLedgerPresenter`, so the counts are the real ones.
@Suite("Filtered ledger export", .appTierSerialised)
struct LedgerFilteredExportTests {

    @MainActor
    private func makeLedger(subjects: [String]) async throws -> (AppCoreEnvironment, TakeoffSession) {
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
        for subject in subjects {
            try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: subject,
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
        return (environment, session)
    }

    private static func filter(subject: String) -> LedgerFilterGroup {
        LedgerFilterGroup(
            id: UUID(),
            rules: [LedgerFilterRule(
                id: UUID(),
                column: .subject,
                comparison: .equals,
                operand: .text(subject)
            )]
        )
    }

    @Test("An unfiltered export is exactly what it has always been: header row, then rows")
    @MainActor
    func unfilteredExportIsUnchanged() async throws {
        let (environment, _) = try await makeLedger(subjects: ["Slab", "Slab", "Wall"])
        let csv = LedgerCSVExport.render(presenter: environment.ledger)
        let lines = csv.components(separatedBy: "\r\n").dropLast()

        #expect(!environment.ledger.isFiltered)
        #expect(lines.count == 1 + environment.ledger.rowCount)
        #expect(lines.first == environment.ledger.visibleColumns
            .map { LedgerCSVExport.field($0.title) }
            .joined(separator: ","))
        #expect(!csv.contains(LedgerCSVExport.filteredBannerKey))
    }

    @Test("A filtered export leads with a banner naming the filter and the rows it dropped")
    @MainActor
    func filteredExportCarriesItsBanner() async throws {
        let (environment, _) = try await makeLedger(subjects: ["Slab", "Slab", "Wall"])
        environment.ledger.setFilter(Self.filter(subject: "Slab"))
        await environment.ledger.refresh()

        #expect(environment.ledger.rowCount == 2)
        #expect(environment.ledger.unfilteredRowCount == 3)
        #expect(environment.ledger.isFiltered)

        let csv = LedgerCSVExport.render(presenter: environment.ledger)
        let lines = csv.components(separatedBy: "\r\n").dropLast()

        // Banner, blank separator, header, two records.
        #expect(lines.count == 2 + 1 + 2, "lines: \(Array(lines))")
        let banner = try #require(lines.first)
        #expect(banner.hasPrefix(LedgerCSVExport.filteredBannerKey))
        #expect(banner.contains("2 of 3 rows"), "\(banner)")
        // The filter itself, in the same words the PDF report's metadata page uses.
        #expect(banner.contains("Subject"), "\(banner)")
        #expect(banner.contains("Slab"), "\(banner)")
        #expect(lines.dropFirst().first == "", "a blank line separates the banner from the table")

        // And the table underneath is still the table: header, then only matching rows.
        let header = try #require(lines.dropFirst(2).first)
        #expect(header == environment.ledger.visibleColumns
            .map { LedgerCSVExport.field($0.title) }
            .joined(separator: ","))
        #expect(lines.dropFirst(3).allSatisfy { $0.contains("Slab") })
        #expect(!lines.dropFirst(3).contains { $0.contains("Wall") })
    }

    @Test("Clearing the filter removes the banner again")
    @MainActor
    func clearingTheFilterClearsTheBanner() async throws {
        let (environment, _) = try await makeLedger(subjects: ["Slab", "Wall"])
        environment.ledger.setFilter(Self.filter(subject: "Slab"))
        await environment.ledger.refresh()
        #expect(LedgerCSVExport.render(presenter: environment.ledger)
            .contains(LedgerCSVExport.filteredBannerKey))

        environment.ledger.setFilter(LedgerFilterGroup(id: UUID()))
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 2)
        #expect(!environment.ledger.isFiltered)
        #expect(!LedgerCSVExport.render(presenter: environment.ledger)
            .contains(LedgerCSVExport.filteredBannerKey))
    }

    /// L-25: the CSV's `Unit` column was empty, so "Plan Length 12,30" carried no
    /// unit. Hand-derived at 100 pt = 10 m (10 pt = 1 m): a 125 pt length is 12.50 m, a
    /// 100 × 80 pt area is 10 m × 8 m = 80 m², three marks are 3 pcs.
    ///
    /// Old output: the Unit cell of every row was "" — the store holds no value for the
    /// contract's `displayUnit` column and the exporter wrote the stored text as it was.
    @Test("L-25: the CSV Unit column carries each measured row's unit, as the ledger shows it")
    @MainActor
    func unitColumnCarriesTheRowsUnit() async throws {
        let (environment, session) = try await makeLedger(subjects: ["Slab"])
        let page = try #require(await session.firstPageID)
        let documentID = await session.documentID
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        func record(_ tool: MeasurementTool, _ subject: String, _ geometry: MeasurementGeometry) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: tool,
                subject: subject, author: "test", geometry: geometry, createdAt: stamp, modifiedAt: stamp
            )
        }
        try await environment.commands.perform(.addMarkup(record(.polylength, "Wall", MeasurementGeometry(
            pageID: page, points: [PDFPoint(x: 0, y: 200), PDFPoint(x: 125, y: 200)]
        ))))
        try await environment.commands.perform(.addMarkup(record(.count, "Doors", MeasurementGeometry(
            pageID: page,
            countPoints: [(300.0, 300.0), (320, 300), (340, 300)].map {
                CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: $0.0, y: $0.1))
            }
        ))))
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 3)

        let columns = environment.ledger.visibleColumns
        let unitIndex = try #require(columns.firstIndex { $0.id == .displayUnit }, "the presenter lists the Unit column")
        #expect(columns[unitIndex].title == "Unit")
        // `;`: the decimal separator of a Swedish ledger needs no quoting then, as in the app.
        let lines = LedgerCSVExport.render(presenter: environment.ledger, delimiter: ";")
            .components(separatedBy: "\r\n").dropLast()
        #expect(lines.count == 1 + 3)
        var units: [String: String] = [:]
        for (index, line) in lines.dropFirst().enumerated() {
            let row = try #require(environment.ledger.row(at: index))
            let cells = line.components(separatedBy: ";")
            #expect(cells.count == columns.count, "\(line)")
            let unit = cells[unitIndex]
            units[row.displayValue(.subject)] = unit
            // Whatever the ledger's own Unit column shows for that row.
            #expect(unit == LedgerDefaultColumns.displayText(for: row, columnID: LedgerDefaultColumns.unitColumnID))
        }
        #expect(units == ["Wall": "m", "Slab": "m²", "Doors": "pcs"], "\(units)")

        // The numbers beside those units, hand-derived above.
        let totals = environment.ledger.grandTotals
        #expect(totals.total("planLength")?.value == Decimal(string: "12.5"))
        #expect(totals.total("planArea")?.value == Decimal(80))
        #expect(totals.total("count")?.value == Decimal(3))
    }
}
