import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// IM-011: the application's ledger presenter supplies its outline, so the table can take every
/// heading and subtotal from the aggregation core instead of folding rows a second time.
///
/// `suppliesDisplayOrderedOutline` promises three things; each is checked here against a real
/// session, with hand-derived numbers and against the core's own group tree:
/// display order is group order, every node counts its descendants, and every node's totals
/// carry every summed column plus the display `Value` total.
@MainActor
@Suite("App ledger presenter outline")
struct AppLedgerPresenterOutlineTests {

    static let documentID = DocumentID(UUID())
    static let pageID = PageID(UUID())

    /// One markup: an area of `width` × 50 pt at 0.1 m per point, so `0.5 × width` m².
    struct Spec {
        let subject: String
        let label: String
        let width: Double
    }

    /// Hand-picked: A/L1 = 10 + 30 pt → 5 + 15 = 20 m²; A/L2 = 20 pt → 10 m²;
    /// B/L1 = 40 pt → 20 m²; B/L2 = 60 + 80 pt → 30 + 40 = 70 m². A = 30 m², B = 90 m², all 120 m².
    static let specs: [Spec] = [
        Spec(subject: "B", label: "L2", width: 60),
        Spec(subject: "A", label: "L1", width: 10),
        Spec(subject: "B", label: "L1", width: 40),
        Spec(subject: "A", label: "L2", width: 20),
        Spec(subject: "B", label: "L2", width: 80),
        Spec(subject: "A", label: "L1", width: 30)
    ]

    static func session(_ specs: [Spec]) async throws -> TakeoffSession {
        let page = ZPDFContracts.PageDescriptor(
            id: pageID, documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for spec in specs {
            _ = try await session.apply(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
                kind: .measurement, tool: .area, subject: spec.subject, label: spec.label, author: "t",
                geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: spec.width, y: 0),
                    PDFPoint(x: spec.width, y: 50), PDFPoint(x: 0, y: 50)
                ], isClosed: true))]),
                createdAt: stamp, modifiedAt: stamp
            )))
        }
        return session
    }

    struct Columns {
        let subject: LedgerColumnID
        let label: LedgerColumnID
        let planArea: LedgerColumnID
    }

    static func columns(_ session: TakeoffSession) async throws -> Columns {
        let set = await session.ledgerColumns
        return Columns(
            subject: LedgerColumnID(try #require(set.column(standard: .subject)).key),
            label: LedgerColumnID(try #require(set.column(standard: .label)).key),
            planArea: LedgerColumnID(try #require(set.column(standard: .planArea)).key)
        )
    }

    static func presenter(_ session: TakeoffSession, grouping: [LedgerColumnID]) async throws -> AppLedgerPresenter {
        let presenter = AppLedgerPresenter(session: session, projection: try await session.ledgerProjection(.flat))
        presenter.setGrouping(grouping)
        await presenter.refresh()
        return presenter
    }

    static func m2(_ value: Decimal) -> ZPDFUIPresentation.DecimalQuantity {
        ZPDFUIPresentation.DecimalQuantity(value: value, dimension: .area)
    }

    /// Walks the outline, checking that each leaf's rows sit at the next `rowCount` display
    /// positions and carry the leaf's (and its ancestors') keys. Returns the end position.
    @discardableResult
    static func expectPositional(
        _ nodes: [ZPDFUIPresentation.LedgerGroupNode],
        presenter: AppLedgerPresenter,
        from start: Int,
        ancestors: [(LedgerColumnID, String)] = []
    ) -> Int {
        var cursor = start
        for node in nodes {
            #expect(node.groupingColumn != nil)
            let path = ancestors + [(node.groupingColumn ?? LedgerColumnID("?"), node.title)]
            if node.children.isEmpty {
                for position in cursor..<(cursor + node.totals.rowCount) {
                    let row = presenter.row(at: position)
                    for (id, title) in path {
                        #expect(row?.displayValue(id) == title, "row \(position) belongs to \(title)")
                    }
                }
                cursor += node.totals.rowCount
            } else {
                let end = expectPositional(node.children, presenter: presenter, from: cursor, ancestors: path)
                #expect(end - cursor == node.totals.rowCount, "\(node.title) counts its descendants")
                cursor = end
            }
        }
        return cursor
    }

    @Test("IM-011: the presenter declares its outline")
    func declaresOutline() async throws {
        let session = try await Self.session([])
        let presenter = AppLedgerPresenter(session: session, projection: try await session.ledgerProjection(.flat))
        #expect(presenter.suppliesDisplayOrderedOutline)
        let existential: any LedgerPresenting = presenter
        #expect(existential.suppliesDisplayOrderedOutline, "dispatched through the protocol")
    }

    @Test("IM-011 grouped: display order is group order, counts and totals are the core's")
    func groupedOutline() async throws {
        let session = try await Self.session(Self.specs)
        let ids = try await Self.columns(session)
        let presenter = try await Self.presenter(session, grouping: [ids.subject])
        let value = LedgerDefaultColumns.valueColumnID

        #expect(presenter.rootGroups.map(\.title) == ["A", "B"])
        #expect(Self.expectPositional(presenter.rootGroups, presenter: presenter, from: 0) == presenter.rowCount)
        let a = try #require(presenter.rootGroups.first)
        let b = try #require(presenter.rootGroups.last)
        #expect(a.totals.rowCount == 3)
        #expect(b.totals.rowCount == 3)
        #expect(a.totals.total(ids.planArea) == Self.m2(30))
        #expect(b.totals.total(ids.planArea) == Self.m2(90))
        #expect(a.totals.total(value) == Self.m2(30), "the display Value total rides on every node")
        #expect(b.totals.total(value) == Self.m2(90))
        #expect(presenter.grandTotals.total(ids.planArea) == Self.m2(120))
        #expect(presenter.grandTotals.total(value) == Self.m2(120))
        #expect(presenter.grandTotals.rowCount == 6)
    }

    @Test("IM-011 nested: two levels, every node counts its descendants and carries the core's totals")
    func nestedOutline() async throws {
        let session = try await Self.session(Self.specs)
        let ids = try await Self.columns(session)
        let presenter = try await Self.presenter(session, grouping: [ids.subject, ids.label])

        #expect(Self.expectPositional(presenter.rootGroups, presenter: presenter, from: 0) == 6)
        let a = try #require(presenter.rootGroups.first)
        let b = try #require(presenter.rootGroups.last)
        #expect(a.children.map(\.title) == ["L1", "L2"])
        #expect(a.children.map(\.totals.rowCount) == [2, 1])
        #expect(a.children.map { $0.totals.total(ids.planArea) } == [Self.m2(20), Self.m2(10)])
        #expect(b.children.map { $0.totals.total(ids.planArea) } == [Self.m2(20), Self.m2(70)])
        #expect(b.children.map { $0.totals.total(LedgerDefaultColumns.valueColumnID) } == [Self.m2(20), Self.m2(70)])
        #expect(a.totals.total(ids.planArea) == Self.m2(30))

        // Against the core's own group tree: every node's Plan Area is the core aggregate.
        let store = try LedgerStore(
            markups: await session.ledgerMarkups,
            columns: await session.ledgerColumns,
            names: await session.nameTable.ledgerCatalog,
            quantityMultiplierColumn: RepetitionColumn.columnID
        )
        let view = store.makeView(LedgerSpecBuilder.translate(presenter.request, columns: store.columns).spec)
        let areaColumn = try #require(store.columns.column(standard: .planArea))
        func compare(_ core: [ZPDFQuantityLedger.LedgerGroupNode], _ shown: [ZPDFUIPresentation.LedgerGroupNode]) {
            #expect(core.count == shown.count)
            for (coreNode, shownNode) in zip(core, shown) {
                #expect(shownNode.totals.rowCount == coreNode.descendantRowCount)
                #expect(shownNode.totals.total(ids.planArea)?.value == coreNode.aggregates[areaColumn.id]?.decimal)
                compare(coreNode.children, shownNode.children)
            }
        }
        compare(view.tree.roots, presenter.rootGroups)
    }

    @Test("IM-011 filtered: the outline covers only the rows that pass, and so do its totals")
    func filteredOutline() async throws {
        let session = try await Self.session(Self.specs)
        let ids = try await Self.columns(session)
        let presenter = try await Self.presenter(session, grouping: [ids.label])
        presenter.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: ids.subject, comparison: .equals, operand: .text("B"))
        ]))
        await presenter.refresh()

        #expect(presenter.isFiltered)
        #expect(presenter.rowCount == 3)
        #expect(Self.expectPositional(presenter.rootGroups, presenter: presenter, from: 0) == 3)
        #expect(presenter.rootGroups.map(\.title) == ["L1", "L2"])
        #expect(presenter.rootGroups.map { $0.totals.total(ids.planArea) } == [Self.m2(20), Self.m2(70)])
        #expect(presenter.grandTotals.total(ids.planArea) == Self.m2(90))
        #expect(presenter.grandTotals.total(LedgerDefaultColumns.valueColumnID) == Self.m2(90))
    }

    @Test("IM-011 empty: no rows, no groups, an empty grand total")
    func emptyOutline() async throws {
        let session = try await Self.session([])
        let ids = try await Self.columns(session)
        let presenter = try await Self.presenter(session, grouping: [ids.subject])
        #expect(presenter.rowCount == 0)
        #expect(presenter.rootGroups.isEmpty)
        #expect(presenter.grandTotals.rowCount == 0)
        #expect(presenter.grandTotals.quantities.isEmpty)
    }

    @Test("IM-011 / BH-240 in the core: a Slope group has no Value total — ratios are never summed")
    func slopeGroupHasNoValueTotal() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-100",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        environment.measurement.setPage(page.id)
        for (percent, y) in [("25", 0.0), ("50", 200.0)] {
            environment.measurement.activate(kind: .slope)
            environment.measurement.setParameterText(percent)
            environment.measurement.appendRawPoints([PDFPointValue(x: 0, y: y), PDFPointValue(x: 100, y: y)])
            environment.measurement.commitActiveMeasurement()
            try await Task.sleep(for: .milliseconds(50))
            await environment.commands.settle()
        }
        let slopes = await session.orderedMarkups.filter { $0.tool == .slope }
        #expect(slopes.count == 2)
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCountsByMeasurementKind == [.slope: 2])

        let icon = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .icon)).key)
        let ledger = environment.ledger
        ledger.setGrouping([icon])
        await ledger.refresh()
        let value = LedgerDefaultColumns.valueColumnID
        let slopeGroup = try #require(ledger.rootGroups.first)
        #expect(ledger.rootGroups.count == 1)
        #expect(slopeGroup.totals.rowCount == 2)
        // Old output: 0.25 + 0.5 = 0.75, a summed ratio under the Slope heading.
        // The core stores a slope ratio as a plain dimensionless number, so the refusal has
        // to come from the column (the core never sums Slope Ratio), not from the dimension.
        #expect(slopeGroup.totals.total(value) == nil, "\(String(describing: slopeGroup.totals.total(value)))")
        #expect(!slopeGroup.totals.incompatibleColumns.contains(value), "no number, and no false unit conflict")
        #expect(ledger.grandTotals.total(value) == nil)
    }

    /// The kind counts, recounted independently from the rows the presenter serves.
    static func countedFromRows(_ presenter: AppLedgerPresenter) -> [ZPDFUIPresentation.MeasurementKind: Int] {
        var counts: [ZPDFUIPresentation.MeasurementKind: Int] = [:]
        for position in 0..<presenter.rowCount {
            guard let kind = presenter.row(at: position)?.measurementKind else { continue }
            counts[kind, default: 0] += 1
        }
        return counts
    }

    @Test("Rows per measurement kind follow the projection — filtered, empty and mixed")
    func rowCountsByMeasurementKind() async throws {
        let session = try await Self.session(Self.specs)
        let ids = try await Self.columns(session)
        let presenter = try await Self.presenter(session, grouping: [])
        #expect(presenter.rowCountsByMeasurementKind == [.area: 6])
        #expect(presenter.rowCountsByMeasurementKind == Self.countedFromRows(presenter))

        presenter.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: ids.subject, comparison: .equals, operand: .text("B"))
        ]))
        await presenter.refresh()
        #expect(presenter.rowCountsByMeasurementKind == [.area: 3], "only the rows that pass the filter")

        // A length joins the areas: two kinds, each counted once per swap.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await session.apply(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()), documentID: Self.documentID, pageID: Self.pageID,
            kind: .measurement, tool: .length, subject: "B", label: "K", author: "t",
            geometry: MeasurementGeometry(pageID: Self.pageID, points: [PDFPoint(x: 0, y: 300), PDFPoint(x: 30, y: 300)]),
            createdAt: stamp, modifiedAt: stamp
        )))
        await presenter.refresh()
        #expect(presenter.rowCountsByMeasurementKind == [.area: 3, .length: 1])
        #expect(presenter.rowCountsByMeasurementKind == Self.countedFromRows(presenter))

        let empty = try await Self.presenter(try await Self.session([]), grouping: [])
        #expect(empty.rowCountsByMeasurementKind.isEmpty)
    }

    @Test("IM-011: the core's Value fold refuses in words the table can tell apart")
    func valueFoldRefusals() {
        let formatter = QuantityFormatter()
        var mixed = LedgerBridge.PrimaryTotal()
        mixed.add(ZPDFUIPresentation.DecimalQuantity(value: 2, dimension: .area))
        mixed.add(ZPDFUIPresentation.DecimalQuantity(value: 3, dimension: .length))
        let mixedTotals = mixed.applied(to: .empty, formatter: formatter)
        #expect(mixedTotals.incompatibleColumns.contains(LedgerDefaultColumns.valueColumnID))
        #expect(mixedTotals.displayValue(LedgerDefaultColumns.valueColumnID) == LedgerTotals.incompatiblePlaceholder,
                "the table reads these words as a unit conflict")

        var overflow = LedgerBridge.PrimaryTotal()
        let huge = Decimal.greatestFiniteMagnitude
        overflow.add(ZPDFUIPresentation.DecimalQuantity(value: huge, dimension: .area))
        overflow.add(ZPDFUIPresentation.DecimalQuantity(value: huge, dimension: .area))
        #expect(overflow.isFailed)
        let failedTotals = overflow.applied(to: .empty, formatter: formatter)
        #expect(failedTotals.incompatibleColumns.contains(LedgerDefaultColumns.valueColumnID))
        #expect(failedTotals.displayValue(LedgerDefaultColumns.valueColumnID) != LedgerTotals.incompatiblePlaceholder,
                "a failed total is not called a unit conflict")

        var ratios = LedgerBridge.PrimaryTotal()
        ratios.add(ZPDFUIPresentation.DecimalQuantity(value: 2, dimension: .area))
        ratios.add(ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "0.25")!, dimension: .ratio))
        let ratioTotals = ratios.applied(to: .empty, formatter: formatter)
        #expect(ratioTotals.total(LedgerDefaultColumns.valueColumnID) == nil)
        #expect(!ratioTotals.incompatibleColumns.contains(LedgerDefaultColumns.valueColumnID))

        var merged = LedgerBridge.PrimaryTotal()
        merged.add(ZPDFUIPresentation.DecimalQuantity(value: 2, dimension: .area))
        merged.merge(ratios)
        #expect(merged.isNonAdditive, "a non-additive child makes its parent non-additive")
    }
}
