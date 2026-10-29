import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFTestingSupport
import ZPDFUIPresentation

/// ADR-0014 §3, the AppCore half (CR-102): a dimensionless cell stored before the `ratio` tag
/// decodes as a count, and the column it sits in is what says whether it is one.
@Suite("Ratio tag migration")
struct RatioTagMigrationTests {

    private static func markup(id: MarkupID, documentID: DocumentID, pageID: PageID) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 100, y: 100),
                    PDFPoint(x: 200, y: 100),
                    PDFPoint(x: 200, y: 180),
                    PDFPoint(x: 100, y: 180)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    @Test("A repeat count stored before the tag loads as a ratio and no longer sums with a count")
    func storedRepeatCountLoadsAsRatio() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.rectangle, in: directory.url)
        let pageID = fixture.firstPage.id
        let id = MarkupID(UUID())
        var record = Self.markup(id: id, documentID: fixture.documentID, pageID: pageID)
        // The bytes a pre-tag build wrote into the `Repeat ×` column: a plain count.
        let preTag = ZPDFContracts.DecimalQuantity(value: 3, dimension: ZPDFContracts.QuantityDimension.count)
        record.customValues[RepetitionColumn.columnID] = .number(preTag)

        let packageURL = directory.url.appendingPathComponent("PreTag.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "PreTag", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(
            TakeoffSession.TakeoffState(pages: fixture.pages, markups: [record], scales: [], pageScaleIDs: [:]),
            into: package
        )
        let stored = try #require(try await TakeoffArchive.read(from: package))
        try await package.close()
        #expect(
            stored.markups.first?.customValues[RepetitionColumn.columnID] == .number(preTag),
            "the archive carries the pre-tag bytes, which decode as a count"
        )

        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        try await session.hydrate(markups: stored.markups, scales: [], pageScaleIDs: [:])
        let cell = try #require(await session.markup(id)?.customValues[RepetitionColumn.columnID])
        guard case .number(let repeats) = cell else {
            Issue.record("expected a number cell, got \(cell)")
            return
        }
        // Old output: `.count` — and `count(4) + repeats` summed to 7 without a word.
        #expect(repeats.dimension == ZPDFContracts.QuantityDimension.ratio)
        #expect(repeats.value == 3)
        #expect(throws: DimensionError.self) {
            _ = try ZPDFContracts.DecimalQuantity.count(4) + repeats
        }
        // The row still repeats: the ledger's multiplier accepts the tag it now carries.
        #expect(try await session.ledgerProjection(.flat).rowCount == 1)
    }

    @Test("The bridge tags a typed dimensionless cell by the column it lands in")
    func bridgeTagsByColumn() throws {
        let repeats = RepetitionColumn.definition()
        let typed = ZPDFUIPresentation.DecimalQuantity(
            value: 2,
            dimension: ZPDFUIPresentation.QuantityDimension(lengthPower: 0, angle: false, currencyCode: nil)
        )
        guard case .number(let ratioCell)? = LedgerBridge.domainCellValue(.quantity(typed), definition: repeats) else {
            Issue.record("expected a number cell")
            return
        }
        // Old output: `.count` — the presentation dimension carries no tag, so a typed repeat
        // count was refused against the column's stored ratios.
        #expect(ratioCell.dimension == ZPDFContracts.QuantityDimension.ratio)

        var counts = repeats
        counts.dimension = ZPDFContracts.QuantityDimension.count
        guard case .number(let countCell)? = LedgerBridge.domainCellValue(.quantity(typed), definition: counts) else {
            Issue.record("expected a number cell")
            return
        }
        #expect(countCell.dimension == ZPDFContracts.QuantityDimension.count)

        // A dimensioned column leaves a mismatched quantity visible to validation.
        var area = repeats
        area.dimension = ZPDFContracts.QuantityDimension(lengthPower: 2)
        guard case .number(let untouched)? = LedgerBridge.domainCellValue(.quantity(typed), definition: area) else {
            Issue.record("expected a number cell")
            return
        }
        #expect(untouched.dimension == ZPDFContracts.QuantityDimension.count)
    }
}
