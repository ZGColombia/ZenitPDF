import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Integration follow-ups: changes other packages need from ZPDFAppCore (BH-041,
/// BH-164/BH-052, BH-279, BH-796, IM-005, IM-014, IM-023, IM-027, IM-081, IM-085, IM-098,
/// IM-099, IM-133, IM-184, IM-012).
@MainActor
@Suite("Integration follow-ups")
struct IntegrationFollowUpTests {

    private func makeEnvironment(pageCount: Int = 1) async throws -> (AppCoreEnvironment, TakeoffSession, [ZPDFContracts.PageDescriptor], DocumentID) {
        let documentID = DocumentID(UUID())
        let pages = (0..<pageCount).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: index, label: "A-10\(index)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, pages, documentID)
    }

    private func calibrate(_ environment: AppCoreEnvironment, _ page: PageID) async throws {
        // 100 pt = 10 m: 0.1 m per point.
        try await environment.commands.calibrate(
            page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
    }

    private func record(
        _ tool: MeasurementTool,
        page: PageID,
        documentID: DocumentID,
        subject: String = "S",
        geometry: MeasurementGeometry,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page,
            kind: tool == .count ? .count : .measurement, tool: tool,
            subject: subject, author: "t", geometry: geometry,
            createdAt: createdAt, modifiedAt: createdAt
        )
    }

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: y), PDFPoint(x: x + w, y: y), PDFPoint(x: x + w, y: y + h), PDFPoint(x: x, y: y + h)
        ], isClosed: true))])
    }

    // MARK: BH-164, BH-052

    @Test("The Slope tool derives its fall line from the run, so it commits")
    func slopeToolCommits() async throws {
        let (environment, session, pages, _) = try await makeEnvironment()
        try await calibrate(environment, pages[0].id)
        environment.measurement.setPage(pages[0].id)
        environment.measurement.activate(kind: .slope)
        environment.measurement.setParameterText("50")
        environment.measurement.appendRawPoints([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)])
        environment.measurement.commitActiveMeasurement()
        try await Task.sleep(for: .milliseconds(50))
        await environment.commands.settle()
        let stored = try #require(await session.orderedMarkups.first { $0.tool == .slope })
        // Old output: no markup — SlopeCalculator threw requireAzimuth on the drawn run.
        // Since ADR-0019 (formula version 4) the Slope tool is informational: the drawn run says
        // where the pitch is read and writes no summed length. It commits with the pitch itself:
        // 50 % is ratio 0.5. (Before ADR-0019 it also wrote trueLength 11.18033988749895 m.)
        #expect(stored.measurement?.values[.slopePercent]?.value == 50)
        #expect(stored.measurement?.values[.slopeRatio]?.value == Decimal(string: "0.5"))
        #expect(stored.measurement?.values[.trueLength] == nil)
        #expect(stored.measurement?.values[.planLength] == nil)
    }

    // MARK: BH-279

    @Test("The resolved selection includes markups on other sheets")
    func resolvedSelectionCoversTheDocument() async throws {
        let (environment, _, pages, documentID) = try await makeEnvironment(pageCount: 2)
        let other = record(.area, page: pages[1].id, documentID: documentID, geometry: box(0, 0, 10, 10, page: pages[1].id))
        try await environment.commands.perform(.addMarkup(other))
        environment.canvas.select(markupIDs: [other.id.rawValue], additive: false)
        // Old output: [] — the protocol default resolved from the visible (current-page) set.
        #expect(environment.canvas.resolvedSelectedMarkups.map(\.id) == [other.id.rawValue])
    }

    // MARK: BH-796

    @Test("Two free-text fields get two answers")
    func placementPromptsBySlot() async throws {
        let (environment, session, pages, _) = try await makeEnvironment()
        let template = StampTemplate(
            id: UUID(), revision: 1, widthPoints: 160, heightPoints: 60, artwork: nil,
            fields: [
                StampFieldDefinition(kind: .freeText, slot: 0, prompt: "Checked by"),
                StampFieldDefinition(kind: .freeText, slot: 1, prompt: "Note")
            ]
        )
        let preset = ToolPresetSummary(
            id: UUID(), name: "QA", category: "", panel: .myTools, markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0), defaultSubject: "", stamp: template
        )
        let slots = template.placementPrompts.map(\.slot)
        #expect(slots.count == 2)
        _ = await environment.placeStamp(
            preset, at: PDFPointValue(x: 100, y: 100), pageID: pages[0].id.rawValue,
            promptedText: "FN", promptedTexts: [slots[1]: "Site copy"]
        )
        let stamp = try #require(await session.orderedMarkups.first?.stamp)
        // Old output: the second field resolved empty.
        #expect(stamp.fields.map(\.resolvedText).sorted() == ["FN", "Site copy"])
    }

    // MARK: BH-041

    @Test("A date equality filter matches the whole day")
    func dateEqualityIsTheWholeDay() async throws {
        let (environment, session, pages, documentID) = try await makeEnvironment()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let afternoon = day.addingTimeInterval(15 * 3_600)
        let nextDay = day.addingTimeInterval(30 * 3_600)
        let a = record(.area, page: pages[0].id, documentID: documentID, geometry: box(0, 0, 10, 10, page: pages[0].id), createdAt: afternoon)
        let b = record(.area, page: pages[0].id, documentID: documentID, geometry: box(20, 0, 10, 10, page: pages[0].id), createdAt: nextDay)
        try await environment.commands.perform(.addMarkup(a))
        try await environment.commands.perform(.addMarkup(b))
        let created = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .created)).key)
        let equals = try await session.ledgerProjection(LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: created, comparison: .equals, operand: .date(day))
        ])))
        // Old output: 0 rows — only a markup created at midnight matched.
        #expect(Set(equals.positionByMarkupID.keys) == [a.id.rawValue])
        let notEquals = try await session.ledgerProjection(LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: created, comparison: .notEquals, operand: .date(day))
        ])))
        #expect(Set(notEquals.positionByMarkupID.keys) == [b.id.rawValue])
    }

    // MARK: IM-014, IM-098

    @Test("Group and grand totals carry the Value sum; rows carry their Value cell")
    func valueColumnTotals() async throws {
        let (environment, session, pages, documentID) = try await makeEnvironment()
        try await calibrate(environment, pages[0].id)
        // 100 × 50 pt = 50 m²; 20 × 10 pt = 2 m²; a 30 pt length = 3 m.
        let big = record(.area, page: pages[0].id, documentID: documentID, subject: "Slab", geometry: box(0, 0, 100, 50, page: pages[0].id))
        let small = record(.area, page: pages[0].id, documentID: documentID, subject: "Slab", geometry: box(200, 0, 20, 10, page: pages[0].id))
        let run = record(.length, page: pages[0].id, documentID: documentID, subject: "Kerb",
                         geometry: MeasurementGeometry(pageID: pages[0].id, points: [PDFPoint(x: 0, y: 300), PDFPoint(x: 30, y: 300)]))
        for markup in [big, small, run] { try await environment.commands.perform(.addMarkup(markup)) }
        let subject = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .subject)).key)
        let projection = try await session.ledgerProjection(LedgerRequest(grouping: [subject]))
        let value = LedgerDefaultColumns.valueColumnID
        let slab = try #require(projection.rootGroups.first { $0.title == "Slab" })
        #expect(slab.totals.total(value)?.value == 52, "50 + 2 m²")
        #expect(slab.totals.rowCount == 2)
        let kerb = try #require(projection.rootGroups.first { $0.title == "Kerb" })
        #expect(kerb.totals.total(value)?.value == 3)
        // Areas and a length cannot be one number: the grand Value total refuses.
        #expect(projection.grandTotals.incompatibleColumns.contains(value))
        #expect(projection.grandTotals.displayValue(value) == "Mixed units")
        let position = try #require(projection.positionByMarkupID[big.id.rawValue])
        #expect(projection.row(at: position)?.displayValue(value) == "50.00")
    }

    // MARK: IM-099, IM-027

    @Test("Multi-level sort applies every level; the export request carries the on-screen columns")
    func multiLevelSortAndExportColumns() async throws {
        let (environment, _, pages, documentID) = try await makeEnvironment()
        try await calibrate(environment, pages[0].id)
        let subjects = ["B", "A", "B", "A"]
        var ids: [MarkupID] = []
        for (index, subject) in subjects.enumerated() {
            let markup = record(.area, page: pages[0].id, documentID: documentID, subject: subject,
                                geometry: box(Double(index) * 50, 0, Double(10 + index * 10), 10, page: pages[0].id))
            ids.append(markup.id)
            try await environment.commands.perform(.addMarkup(markup))
        }
        let ledger = environment.ledger
        ledger.sort(by: [
            ZPDFUIPresentation.LedgerSortDescriptor(column: .subject, ascending: true),
            ZPDFUIPresentation.LedgerSortDescriptor(column: .planArea, ascending: false)
        ])
        await ledger.refresh()
        #expect(ledger.sortDescriptors.count == 2)
        let order = (0..<ledger.rowCount).compactMap { ledger.row(at: $0)?.markupID }
        // A: indices 1 (20 pt wide) and 3 (40 pt wide) → 3 first; then B: 2 (30) before 0 (10).
        #expect(order == [ids[3], ids[1], ids[2], ids[0]].map(\.rawValue))

        ledger.onScreenColumnOrder = [.subject, LedgerDefaultColumns.valueColumnID, .planArea]
    }

    // MARK: IM-133

    @Test("The pointer readout is its own observable property")
    func cursorReadout() {
        let status = AppStatusPresenter(units: .metric)
        status.updateCursor(PDFPointValue(x: 12, y: 34))
        #expect(!status.cursorDisplayText.isEmpty)
        #expect(status.cursorDisplayText == status.snapshot.cursorDisplayText)
        #expect(status.cursorPagePoint == PDFPointValue(x: 12, y: 34))
    }

    // MARK: IM-184, IM-023

    @Test("Adding ledger columns is one undo step; lock, unlock, hide and show are commands")
    func columnAndFlagCommands() async throws {
        let (environment, session, pages, documentID) = try await makeEnvironment()
        let column = LedgerColumnDefinition(id: ColumnID(UUID()), key: "zenit.import.test", title: "Qty", kind: .text)
        let row = record(.area, page: pages[0].id, documentID: documentID, geometry: box(0, 0, 10, 10, page: pages[0].id))
        try await environment.commands.performBatch([.addCustomColumns([column]), .addMarkup(row)], actionName: "Import")
        #expect(await session.ledgerColumns.column(key: "zenit.import.test") != nil)
        await environment.commands.undo()
        // Old behaviour: the rows went, the imported column stayed.
        #expect(await session.ledgerColumns.column(key: "zenit.import.test") == nil)
        #expect(await session.orderedMarkups.isEmpty)
        await environment.commands.redo()
        #expect(await session.runtimeColumnDefinitions.map(\.key) == ["zenit.import.test"])

        try await environment.commands.perform(.setLocked(ids: [row.id], locked: true))
        #expect(await session.markup(row.id)?.locked == true)
        await #expect(throws: DocumentCommandError.markupLocked(row.id)) {
            try await environment.commands.perform(.setHidden(ids: [row.id], hidden: true))
        }
        try await environment.commands.perform(.setLocked(ids: [row.id], locked: false))
        try await environment.commands.perform(.setHidden(ids: [row.id], hidden: true))
        #expect(await session.markup(row.id)?.hidden == true)
        await environment.commands.undo()
        #expect(await session.markup(row.id)?.hidden == false)
    }

    // MARK: IM-081

    @Test("A column-only change and a prebuilt ledger give the fresh build's projection")
    func columnChangeAndPrebuild() async throws {
        let (environment, session, pages, documentID) = try await makeEnvironment()
        try await calibrate(environment, pages[0].id)
        for index in 0..<20 {
            try await environment.commands.perform(.addMarkup(record(
                .area, page: pages[0].id, documentID: documentID, subject: "S\(index % 3)",
                geometry: box(Double(index) * 20, 0, 10, 10, page: pages[0].id)
            )))
        }
        _ = try await session.ledgerProjection(.flat)
        try await session.addCustomColumns([LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.note", title: "Note", kind: .text)])
        let afterColumns = try await session.ledgerProjection(.flat)
        #expect(afterColumns.columns.contains { $0.id == LedgerColumnID("custom.note") })
        #expect(afterColumns.rowCount == 20)

        // R-064 (iteration 1 re-fix): the prebuild reports no progress; the ledger package's
        // own build still does, and Fix2QStoreAndReportTests covers its fractions.
        try await session.prebuildLedger()
        let prebuilt = try await session.ledgerProjection(.flat)
        #expect(prebuilt.rowCount == 20)
        #expect(prebuilt.grandTotals == afterColumns.grandTotals)
    }

    // MARK: IM-085

    @Test("Hits list without rectangles and get them when revealed")
    func searchBoundsOnReveal() async throws {
        let index = try await DocumentSearchIndexTests.makeIndex()
        defer { Task { await index.shutDown() } }
        _ = try await index.indexDrawingText()
        let documentUUID = UUID()
        let pages = DocumentSearchIndexTests.pages(count: 1, documentID: DocumentID(documentUUID))
        let presenter = AppSearchPresenter(
            service: index.service,
            projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Plan", pages: pages, currentPageIndex: 0),
            scope: ZPDFUIPresentation.SearchScope(location: .entireProject)
        )
        presenter.debounce = .zero
        var revealed: [ZPDFUIPresentation.SearchHit] = []
        presenter.onReveal = { revealed.append($0) }
        presenter.query = "SCREED"
        presenter.runSearch()
        let deadline = ContinuousClock.now + .seconds(10)
        while presenter.hits.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let hit = try #require(presenter.hits.first)
        presenter.selectHit(id: hit.id)
        while revealed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(revealed.first?.id == hit.id, "the hit keeps its identity")
        #expect(revealed.first?.boundsInPageSpace != nil, "the revealed hit carries its rectangle")
    }

    // MARK: IM-012, IM-096

    @Test("Cells render through the ledger package's number locale")
    func numbersRenderThroughTheSharedLocale() {
        let quantity = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "-1234.5")!, dimension: .area)
        #expect(QuantityFormatter(units: .metric).text(quantity) == "-1,234.50")
        let swedish = QuantityFormatter(units: .metric, localeIdentifier: "sv_SE").text(quantity)
        #expect(swedish == LedgerNumberLocale.forLocale(Locale(identifier: "sv_SE")).string(Decimal(string: "-1234.50")!, decimalPlaces: 2))
    }
}
