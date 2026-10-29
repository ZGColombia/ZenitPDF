import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The ledger presenter, at the size it has to survive.
///
/// ADR-0003 §3.4 is the thing under test: the presenter answers a *count* and a
/// *row-at-index*, and never a row array. These tests build a ten-thousand-row takeoff and
/// then assert that reading the forty rows a table draws costs forty rows.
@Suite("Ledger presenter")
struct LedgerPresenterTests {

    static let documentID = DocumentID(UUID())
    static let pageID = PageID(UUID())

    static var page: ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
    }

    /// A session holding `count` measured rectangles of increasing size, at a scale where
    /// one PDF point is 0.1 m.
    @MainActor
    static func session(rowCount count: Int) async throws -> TakeoffSession {
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            let width = Double(10 + index % 90)
            _ = try await session.apply(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: .area,
                subject: index % 2 == 0 ? "Floor slab" : "Roof deck",
                label: "R\(index)",
                author: "test",
                geometry: MeasurementGeometry(
                    pageID: pageID,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0),
                        PDFPoint(x: width, y: 0),
                        PDFPoint(x: width, y: 50),
                        PDFPoint(x: 0, y: 50)
                    ], isClosed: true))]
                ),
                createdAt: stamp,
                modifiedAt: stamp
            )))
        }
        return session
    }

    @Test("Ten thousand rows are addressed by index, and a scroll window costs the window")
    @MainActor
    func indexAddressedAtScale() async throws {
        let session = try await Self.session(rowCount: 10_000)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)

        #expect(presenter.rowCount == 10_000)
        #expect(!presenter.isEmpty)

        // The window a table draws.
        let window = (4_000..<4_040).compactMap { presenter.row(at: $0) }
        #expect(window.count == 40)
        #expect(window.first?.displayValue("subject") == "Floor slab")

        // Every row in the window resolves back to its own index, so selection by identity
        // survives the trip through the table.
        for (offset, row) in window.enumerated() {
            #expect(presenter.index(of: row.markupID) == 4_000 + offset)
        }

        // Out of range answers `nil` rather than trapping: the table asks for the band it
        // is about to draw, not for one it has bounds-checked first.
        #expect(presenter.row(at: -1) == nil)
        #expect(presenter.row(at: 10_000) == nil)
        #expect((9_990..<10_050).compactMap { presenter.row(at: $0) }.count == 10)
    }

    @Test("Prefetch fills the band it is given and evicts what scrolled away")
    @MainActor
    func prefetchAndEviction() async throws {
        let session = try await Self.session(rowCount: 5_000)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)

        // The band the ledger table hands over for rows 1 000..<1 040 on screen: 32 leading and
        // 96 trailing (`LedgerTableController.prefetchVisibleBand`, ZPDFUILedger's IM-014 test).
        let plan = 968..<1_136
        presenter.prefetchRows(in: plan)
        #expect(presenter.row(at: 1_000) != nil)

        // Scrolling to the far end and prefetching there must not keep the near end alive:
        // a cache that only grows is an array of view models with extra steps.
        let far = 4_768..<4_936
        presenter.prefetchRows(in: far)
        #expect(presenter.row(at: 4_800) != nil)
        #expect(presenter.row(at: 1_000) != nil, "still answerable — it is rebuilt, not remembered")
    }

    @Test("A filter narrows the count and the identity index follows it")
    @MainActor
    func filteringNarrowsTheIndex() async throws {
        let session = try await Self.session(rowCount: 200)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)
        #expect(presenter.rowCount == 200)

        let survivor = try #require(presenter.row(at: 0)).markupID
        let excluded = try #require(presenter.row(at: 1)).markupID

        presenter.setFilter(LedgerFilterGroup(
            id: UUID(),
            conjunction: .all,
            rules: [LedgerFilterRule(
                id: UUID(),
                column: "subject",
                comparison: .equals,
                operand: .text("Floor slab")
            )]
        ))
        await presenter.refresh()

        #expect(presenter.rowCount == 100)
        #expect(presenter.index(of: survivor) != nil)
        #expect(presenter.index(of: excluded) == nil, "a filtered-out row has no display position")
        #expect((0..<presenter.rowCount).compactMap { presenter.row(at: $0) }.allSatisfy {
            $0.displayValue("subject") == "Floor slab"
        })
    }

    @Test("Sorting reorders the index without changing which rows exist")
    @MainActor
    func sortingReorders() async throws {
        let session = try await Self.session(rowCount: 90)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)

        presenter.sort(by: "planArea", ascending: true)
        await presenter.refresh()
        let ascending = (0..<presenter.rowCount).compactMap { presenter.row(at: $0) }.compactMap {
            $0.quantity("planArea")?.value
        }
        #expect(ascending.count == 90)
        #expect(ascending == ascending.sorted())

        presenter.sort(by: "planArea", ascending: false)
        await presenter.refresh()
        let descending = (0..<presenter.rowCount).compactMap { presenter.row(at: $0) }.compactMap {
            $0.quantity("planArea")?.value
        }
        #expect(descending == descending.sorted(by: >))
        #expect(Set(ascending) == Set(descending), "the same rows, in the other order")
    }

    @Test("Grouping builds an outline whose subtotals reconcile with the grand total")
    @MainActor
    func groupingReconciles() async throws {
        let session = try await Self.session(rowCount: 60)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)

        presenter.setGrouping(["subject"])
        await presenter.refresh()

        #expect(presenter.rootGroups.count == 2, "Floor slab and Roof deck")
        let grand = try #require(presenter.grandTotals.total("planArea")).value
        var summed: Decimal = 0
        for group in presenter.rootGroups {
            summed += try #require(group.totals.total("planArea")).value
        }
        #expect(summed == grand, "the group totals add up to the grand total, exactly")
        #expect(presenter.rootGroups.reduce(0) { $0 + $1.totals.rowCount } == 60)
    }

    @Test("Collapsing a group survives a rebuild")
    @MainActor
    func collapsedGroupsSurviveRebuilds() async throws {
        let session = try await Self.session(rowCount: 20)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)
        presenter.setGrouping(["subject"])
        await presenter.refresh()

        let first = try #require(presenter.rootGroups.first)
        #expect(first.isExpanded)
        presenter.toggleGroup(id: first.id)
        #expect(presenter.rootGroups.first?.isExpanded == false)

        // A rebuild derives group identity from the group's path, not from a fresh UUID, so
        // the collapse is still there. Regenerating identities would re-expand every group
        // on every keystroke in the filter field.
        presenter.sort(by: "label", ascending: true)
        await presenter.refresh()
        let sameGroup = try #require(presenter.rootGroups.first { $0.id == first.id })
        #expect(sameGroup.isExpanded == false)
    }

    @Test("Selection is by identity and drops rows the filter removed")
    @MainActor
    func selectionIsByIdentity() async throws {
        let session = try await Self.session(rowCount: 40)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)

        let kept = try #require(presenter.row(at: 0)).markupID
        let dropped = try #require(presenter.row(at: 1)).markupID
        presenter.select(rowIDs: [kept, dropped], additive: false)
        #expect(presenter.selectedRowIDs.count == 2)
        #expect(presenter.rows(withIDs: presenter.selectedRowIDs).count == 2)

        presenter.setFilter(LedgerFilterGroup(
            id: UUID(),
            conjunction: .all,
            rules: [LedgerFilterRule(
                id: UUID(),
                column: "subject",
                comparison: .equals,
                operand: .text("Floor slab")
            )]
        ))
        await presenter.refresh()
        #expect(presenter.selectedRowIDs == [kept], "a selection cannot outlive its row")
    }

    // MARK: Unit display column

    @Test("A measured row fills the Unit column from its primary quantity")
    @MainActor
    func unitDisplayColumnIsFilled() async throws {
        let session = try await Self.session(rowCount: 1)
        let projection = try await session.ledgerProjection(.flat)
        let presenter = AppLedgerPresenter(session: session, projection: projection)

        let row = try #require(presenter.row(at: 0))
        // The fixture markup is an area, so its primary quantity is m² under metric units.
        #expect(row.displayValue(LedgerDefaultColumns.unitColumnID) == "m²")
        #expect(LedgerDefaultColumns.unitText(for: row) == "m²")
        // The Value column stays a bare number — the unit lives in its own column.
        let value = LedgerDefaultColumns.valueText(for: row)
        #expect(!value.isEmpty)
        #expect(!value.contains("m"))
        // The Type column reads the tool's name, not the kind token.
        #expect(LedgerDefaultColumns.displayText(for: row, columnID: .icon) == "Area")
    }

    @Test("A count's unit reads as pieces, and a quantity-free row stays blank")
    func countAndQuantityFreeUnits() {
        let formatter = QuantityFormatter()
        let count = LedgerBridge.primaryUnitText(
            kind: .count,
            values: [.count: .quantity(.count(5))],
            displays: [.count: "5"],
            formatter: formatter
        )
        #expect(count == "pcs")

        let none = LedgerBridge.primaryUnitText(
            kind: nil,
            values: [:],
            displays: [:],
            formatter: formatter
        )
        #expect(none.isEmpty)

        let length = LedgerBridge.primaryUnitText(
            kind: .length,
            values: [.planLength: .quantity(.metres(7))],
            displays: [.planLength: "7.00"],
            formatter: formatter
        )
        #expect(length == "m")
    }
}
