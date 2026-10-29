import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// T-046: grouping by Type — the default view —
/// makes one group per measurement tool, headed by the tool's name, with a Value subtotal in
/// one dimension. Every measuring path writes markups of kind `.measurement`, so the old Type
/// cell ("measurement") put every row in one group whose Value read "Mixed units".
@MainActor
@Suite("Iteration 3 — ledger Type grouping")
struct Iter3LedgerTypeGroupingTests {

    static let documentID = DocumentID(UUID())
    static let pageID = PageID(UUID())
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func record(_ tool: MeasurementTool, _ geometry: MeasurementGeometry) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
            kind: .measurement, tool: tool, subject: "S", author: "t",
            geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func rectangle(width: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: width, y: 0),
            PDFPoint(x: width, y: 50), PDFPoint(x: 0, y: 50)
        ], isClosed: true))])
    }

    static func segment(length: Double, y: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 0, y: y), PDFPoint(x: length, y: y)])
    }

    static func countPoints(_ count: Int) -> MeasurementGeometry {
        MeasurementGeometry(pageID: pageID, countPoints: (0..<count).map { index in
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: Double(index) * 10, y: 500))
        })
    }

    @Test("T-046: Group by Type gives one group per tool, titled by the tool, each with its own Value total")
    func groupByTypeSplitsTheTools() async throws {
        let page = ZPDFContracts.PageDescriptor(
            id: Self.pageID, documentID: Self.documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: Self.documentID, pages: [page])
        // 100 pt = 10 m, so 0.1 m per point.
        _ = try await session.calibrate(
            page: Self.pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        // Hand-derived: Length 30 pt + 50 pt = 3 m + 5 m = 8 m. Area 10 × 50 pt + 20 × 50 pt =
        // (1 × 5) + (2 × 5) = 15 m². Count 3 + 2 = 5.
        for markup in [
            Self.record(.length, Self.segment(length: 30, y: 300)),
            Self.record(.area, Self.rectangle(width: 10)),
            Self.record(.count, Self.countPoints(3)),
            Self.record(.length, Self.segment(length: 50, y: 400)),
            Self.record(.area, Self.rectangle(width: 20)),
            Self.record(.count, Self.countPoints(2))
        ] {
            _ = try await session.apply(.addMarkup(markup))
        }
        let icon = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .icon)).key)
        let presenter = AppLedgerPresenter(session: session, projection: try await session.ledgerProjection(.flat))
        presenter.setGrouping([icon])
        await presenter.refresh()

        let value = LedgerDefaultColumns.valueColumnID
        // Old output: one group titled "measurement" holding six rows, its Value refused as
        // "Mixed units" (value in incompatibleColumns, no total).
        #expect(presenter.rootGroups.map(\.title) == ["Area", "Count", "Length"])
        #expect(presenter.rootGroups.map(\.groupingValue) == ["t:area", "t:count", "t:length"])
        #expect(presenter.rootGroups.map(\.totals.rowCount) == [2, 2, 2])
        #expect(presenter.rootGroups.map { $0.totals.total(value) } == [
            ZPDFUIPresentation.DecimalQuantity(value: 15, dimension: .area),
            ZPDFUIPresentation.DecimalQuantity(value: 5, dimension: .count),
            ZPDFUIPresentation.DecimalQuantity(value: 8, dimension: .length)
        ])
        #expect(presenter.rootGroups.allSatisfy { !$0.totals.incompatibleColumns.contains(value) })
        // The heading is the text the Type cells under it show.
        for position in 0..<presenter.rowCount {
            let row = try #require(presenter.row(at: position))
            let group = try #require(presenter.rootGroups.first { $0.groupingValue == "t:\(row.measurementKind?.rawValue ?? "")" })
            #expect(row.displayValue(icon) == group.title)
        }
    }
}
