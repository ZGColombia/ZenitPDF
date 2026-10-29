import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// W-060 at the presenter: the core's
/// ``LedgerAggregationPlan/sums(_:)`` now refuses Radius and Diameter (a radius is a property
/// of one circle, like a slope), and the ledger's `Value` column — a Radius row's Value is its
/// radius — follows the same rule, so neither a heading, the grand total nor the subject
/// summary adds radii. The core half is `Iter6LedgerCoreFixTests` in ZPDFQuantityLedger.
@MainActor
@Suite("Iteration 6 — ledger workflows, W-060 Value heading")
struct Iter6LedgerRadiusValueTests {

    /// Three circles drawn with the Radius tool at 0.1 m per point: rims 10, 20 and 30 pt from
    /// the centre, so r = 1, 2 and 3 m. Grouped by Type they are one "Radius" group.
    @Test("W-060: three circles of r = 1, 2 and 3 m show no Value total, not 6 m")
    func radiusGroupHasNoValueTotal() async throws {
        let documentID = AppLedgerPresenterOutlineTests.documentID
        let pageID = AppLedgerPresenterOutlineTests.pageID
        let session = try await AppLedgerPresenterOutlineTests.session([])
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, rim) in [10.0, 20.0, 30.0].enumerated() {
            let y = 100.0 + 100.0 * Double(index)
            _ = try await session.apply(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
                kind: .measurement, tool: .radius, subject: "Column", label: "C\(index + 1)", author: "t",
                geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 100, y: y), PDFPoint(x: 100 + rim, y: y)]),
                createdAt: stamp, modifiedAt: stamp
            )))
        }
        let set = await session.ledgerColumns
        let icon = LedgerColumnID(try #require(set.column(standard: .icon)).key)
        let radius = LedgerColumnID(try #require(set.column(standard: .radius)).key)
        let diameter = LedgerColumnID(try #require(set.column(standard: .diameter)).key)
        let presenter = try await AppLedgerPresenterOutlineTests.presenter(session, grouping: [icon])
        let value = LedgerDefaultColumns.valueColumnID

        // Every row has its radius, and a Value: the heading's silence is not missing data.
        var radii: [Decimal] = []
        for position in 0..<presenter.rowCount {
            let row = try #require(presenter.row(at: position))
            #expect(!(row.displayValues[value] ?? "").isEmpty, "row \(position) shows a Value")
            if case .quantity(let quantity) = row.values[radius] {
                #expect(quantity.dimension == .length)
                radii.append(quantity.value)
            }
        }
        #expect(radii.sorted() == [1, 2, 3])

        let group = try #require(presenter.rootGroups.first)
        #expect(presenter.rootGroups.count == 1)
        #expect(group.totals.rowCount == 3)
        // Old output: 6 m under the Radius heading and in the grand total, 12 m for Diameter.
        #expect(group.totals.total(value) == nil, "\(String(describing: group.totals.total(value)))")
        #expect(!group.totals.incompatibleColumns.contains(value), "no number, and no false unit conflict")
        #expect(group.totals.total(radius) == nil)
        #expect(group.totals.total(diameter) == nil)
        #expect(presenter.grandTotals.total(value) == nil)
        #expect(presenter.grandTotals.total(radius) == nil)
        // Old output: one "Column" line of 6 m in the project summary.
        #expect(try await session.subjectTotals().isEmpty)
    }
}
