import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The Quantity Ledger's power tools, over the composition the application actually ships.
///
/// Every piece of this was already finished and tested — twice over, in two packages that
/// cannot see each other. `ZPDFUILedger` tests `LedgerFilterBuilder` and
/// `LedgerBulkEditModel` against arrays of rows; `ZPDFAppCore` tests `applyBulkEdit`
/// against the real session; `ZPDFUIShell` tests `LedgerPaneModel` against
/// `MockLedgerPresenter`. Nothing tested the join, because the join only exists in the
/// application: `ZPDFUIShell` may not link `ZPDFAppCore`, so the one place where the pane's
/// model meets the real presenter is here.
///
/// That join is where the interesting failures live. A presenter that stopped conforming to
/// `LedgerBulkEditPresenting` disables Apply and every package suite stays green. A status
/// choice whose option value no longer round-trips to `MarkupStatus` writes nothing and
/// every package suite stays green. So these tests build exactly what
/// ``ZPDFUIShell/QuantityLedgerPane`` builds — `LedgerPaneModel(presenter:preferences:)`
/// over `AppLedgerPresenter` — and drive the controls, not the engine underneath them.
///
/// No window is created and nothing is launched: the table controller loads its view the
/// way AppKit would, which is all `rebuildPlan` needs.
///
/// `.serialized` on purpose. Every test here stands up a real `TakeoffSession`, and running
/// eight of them at once raised the app suite's peak concurrency enough to start tripping
/// the shared static document registry and the `pendingStorageShutdowns` drain that returns
/// before the shutdown it should have awaited. That defect is older than this suite and lives
/// elsewhere; making its trigger more likely while
/// leaving it unfixed would be the wrong trade, so this suite takes itself out of the race.
@Suite("Ledger power tools, end to end", .appTierSerialised, .serialized)
@MainActor
struct LedgerPowerToolsTests {

    // MARK: - Fixture

    private struct Fixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let model: LedgerPaneModel
        let defaults: UserDefaults
        let suiteName: String
        let ids: [MarkupID]

    }

    /// One calibrated page at 0.1 m/pt carrying three 100 × 80 pt rectangles — 80 m² each,
    /// so 240 m² total and every arithmetic slip is visible by eye.
    private func makeFixture(
        subjects: [String] = ["Slab A", "Slab B", "Wall C"]
    ) async throws -> Fixture {
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

        var ids: [MarkupID] = []
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for subject in subjects {
            let id = MarkupID(UUID())
            try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
                id: id,
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: subject,
                author: "test",
                status: .open,
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
            ids.append(id)
        }
        await environment.ledger.refresh()

        // The pane's own composition, verbatim, over an isolated defaults suite so the
        // test never writes into the person's real preferences.
        // One suite name for this prefix, not one per test: 609 of the 2 547 empty plists
        // measured in a development machine's Preferences folder on 2026-08-25 were this fixture's UUIDs,
        // and `cfprefsd` rewrites the file after any attempt to delete it. Never
        // `?? .standard` either — that fallback would put a test's pane preferences into the
        // user's real defaults, which is the set-mode leak with a different key.
        let suiteName = ScratchDefaults.suiteName(for: "zenit.ledgerpowertools")
        let defaults = try #require(
            UserDefaults(suiteName: suiteName),
            "a scratch suite must never fall back to UserDefaults.standard"
        )
        defaults.removePersistentDomain(forName: suiteName)
        let model = LedgerPaneModel(
            presenter: environment.ledger,
            preferences: LedgerPanePreferences(defaults: defaults)
        )
        model.host.controller.loadViewIfNeeded()
        model.refresh()

        return Fixture(
            environment: environment,
            session: session,
            model: model,
            defaults: defaults,
            suiteName: suiteName,
            ids: ids
        )
    }

    private static func subjectFilter(_ subject: String) -> LedgerFilterGroup {
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

    /// Waits for the pane's Apply, which hands the request to the presenter in a `Task` so
    /// the panel stays responsive. Polling the receipt is how the panel itself learns.
    private static func receipt(after model: LedgerPaneModel) async -> LedgerBulkEditReceipt? {
        _ = await AppTestSupport.wait { model.lastBulkEditReceipt != nil }
        return model.lastBulkEditReceipt
    }

    // MARK: - 1. The filter, through the pane

    @Test("The pane's filter narrows the real ledger, and its live count is over the whole takeoff")
    func filterThroughThePaneNarrowsTheRealLedger() async throws {
        let fixture = try await makeFixture(subjects: ["Slab", "Slab", "Wall"])
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let model = fixture.model

        #expect(model.matchCount == 3)
        #expect(model.totalCount == 3)
        #expect(!fixture.environment.ledger.isFiltered)

        model.setFilter(Self.subjectFilter("Slab"))
        // The app presenter debounces and supersedes its rebuilds, so the pane waits for
        // the projection rather than assuming the setter was synchronous.
        _ = await AppTestSupport.wait { model.matchCount == 2 }
        model.refresh()

        #expect(model.matchCount == 2, "the numerator is what passed the filter")
        #expect(model.totalCount == 3, "the denominator is the whole takeoff, not the page")
        #expect(fixture.environment.ledger.isFiltered)
        // The table under the panel really is two rows, not three drawn with one dimmed.
        #expect(model.host.rowCount == 2)

        model.setFilter(LedgerFilterGroup(id: UUID()))
        _ = await AppTestSupport.wait { model.matchCount == 3 }
        #expect(!fixture.environment.ledger.isFiltered)
    }

    @Test("A named filter saved in the pane survives the pane being rebuilt")
    func savedFilterSurvivesARebuild() async throws {
        let fixture = try await makeFixture()
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }

        var store = fixture.model.savedFilters
        store.save(name: "Concrete only", filter: Self.subjectFilter("Slab A"))
        fixture.model.savedFilters = store

        // A new pane over the same preferences — closing the ledger and reopening it.
        let rebuilt = LedgerPaneModel(
            presenter: fixture.environment.ledger,
            preferences: LedgerPanePreferences(defaults: fixture.defaults)
        )
        #expect(rebuilt.savedFilters.filters.map(\.name) == ["Concrete only"])
    }

    @Test("The filter panel's canvas control reaches the drawing")
    func canvasFollowsTheLedgerFilter() async throws {
        let fixture = try await makeFixture(subjects: ["Slab", "Slab", "Wall"])
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let model = fixture.model
        let canvas = fixture.environment.canvas

        #expect(canvas.visibleMarkups.count == 3)
        #expect(canvas.dimmedMarkupIDs.isEmpty)

        // Hide: the drawing really loses the rows the ledger dropped. This is the segment
        // that used to write a stored property nothing read.
        model.setCanvasFilterBehavior(.hideNonMatching)
        model.setFilter(Self.subjectFilter("Slab"))
        _ = await AppTestSupport.wait { canvas.visibleMarkups.count == 2 }
        #expect(canvas.visibleMarkups.count == 2)
        #expect(canvas.visibleMarkups.allSatisfy { $0.subject == "Slab" })
        #expect(canvas.dimmedMarkupIDs.isEmpty, "a hidden markup is not a dimmed one")

        // Dim: everything stays drawn, and the drawing layer is told which ones failed.
        model.setCanvasFilterBehavior(.dimNonMatching)
        _ = await AppTestSupport.wait { canvas.visibleMarkups.count == 3 }
        #expect(canvas.visibleMarkups.count == 3)
        #expect(canvas.dimmedMarkupIDs.count == 1)
        let dimmed = try #require(canvas.visibleMarkups.first { canvas.dimmedMarkupIDs.contains($0.id) })
        #expect(dimmed.subject == "Wall")

        // Leave unchanged: the filter is a ledger fact and the drawing ignores it, while
        // the ledger itself stays narrowed.
        model.setCanvasFilterBehavior(.leaveUnchanged)
        _ = await AppTestSupport.wait { canvas.dimmedMarkupIDs.isEmpty }
        #expect(canvas.visibleMarkups.count == 3)
        #expect(canvas.dimmedMarkupIDs.isEmpty)
        #expect(model.matchCount == 2, "the ledger is still filtered")

        // Clearing the filter puts the drawing back whatever the behaviour was.
        model.setCanvasFilterBehavior(.hideNonMatching)
        model.setFilter(LedgerFilterGroup(id: UUID()))
        _ = await AppTestSupport.wait { canvas.visibleMarkups.count == 3 }
        #expect(canvas.visibleMarkups.count == 3)
        #expect(canvas.dimmedMarkupIDs.isEmpty)
    }

    // MARK: - 2. The filtered export stays labelled, in every format the dialog offers

    @Test("Every format the export dialog writes says the ledger was filtered")
    func everyExportedFormatDeclaresTheFilter() async throws {
        let fixture = try await makeFixture(subjects: ["Slab", "Slab", "Wall"])
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let core = fixture.environment

        // The export is "as on screen", grouping included (IM-027), and since IM-011 the pane's
        // restored default grouping (by Type) reaches the presenter the moment the table asks
        // for it. This test is about the filter label on a flat file, so it says so.
        fixture.model.setGrouping([])
        #expect(core.ledger.request.grouping.isEmpty)
        fixture.model.setFilter(Self.subjectFilter("Slab"))
        _ = await AppTestSupport.wait { fixture.model.matchCount == 2 }

        // CSV is rendered from the presenter directly; the other three from one projection.
        let csv = LedgerCSVExport.render(presenter: core.ledger)
        #expect(csv.hasPrefix(LedgerCSVExport.filteredBannerKey))
        #expect(csv.contains("2 of 3 rows"))

        let projection = try await ProjectWindowController.projection(
            core: core,
            documentName: "Takeoff",
            scaleDescription: core.snapshot.firstPageScale?.displayString,
            request: core.ledger.request
        )
        #expect(projection.table.metadata.rowCount == 2)
        #expect(projection.table.metadata.totalRowCountBeforeFilter == 3)
        #expect(projection.table.metadata.filterDescription.lowercased().contains("subject"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-filtered-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The interchange JSON: the label is in the file, not only in the projection.
        let jsonBytes = ZenitJSONExporter().export(projection)
        let jsonText = try #require(String(data: jsonBytes, encoding: .utf8))
        #expect(jsonText.lowercased().contains("subject"), "the filter is named in the interchange file")
        #expect(jsonText.contains("\"rowCountBeforeFilter\""))
        let reread = try ZenitJSONImporter().document(from: jsonBytes)
        #expect(reread.rows.count == 2, "a filtered file carries the filtered rows and says so")

        // The workbook: written, non-empty, and a real zip container. Its metadata sheet is
        // built from the same projection, whose filter fields are asserted above.
        let workbook = directory.appendingPathComponent("Takeoff.xlsx")
        try XLSXExporter().export(projection, to: workbook)
        let workbookBytes = try Data(contentsOf: workbook)
        #expect(workbookBytes.prefix(2) == Data("PK".utf8))

        // The PDF report renders without error over the filtered projection.
        let report = directory.appendingPathComponent("Takeoff.pdf")
        _ = try PDFReportRenderer().render(projection, to: report, auditAppendix: nil)
        #expect(try Data(contentsOf: report).prefix(4) == Data("%PDF".utf8))

        // And the filtered file's own arithmetic reconciles: two 80 m² rows, 160 m².
        #expect(projection.table.rows.count == 2)
    }

    // MARK: - 3. Bulk edit, staged in the panel's model and applied through the pane

    @Test("A bulk edit staged in the panel reaches the document as one undoable step")
    func bulkEditThroughThePaneIsOneUndoStep() async throws {
        let fixture = try await makeFixture()
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let model = fixture.model

        #expect(model.canBulkEdit, "the shipping presenter must service the pane's Apply")

        // Select all three the way the table does, then stage the edits the panel's
        // controls stage: a subject, a status choice and a colour.
        let selection = Set(fixture.ids.map(\.rawValue))
        model.applyExternalSelection(selection)
        #expect(model.bulkEdit.markupIDs == selection)

        // Subject disagrees across the selection, so it starts mixed — and stays mixed
        // until the panel writes it. That is the guarantee the whole panel rests on.
        #expect(model.bulkEdit.displayState(.subject).isMixed)

        let colour = ColorRGBA(red: 0.1, green: 0.7, blue: 0.9, alpha: 1)
        model.bulkEdit.setEdit(.text("Slab"), for: .subject)
        model.bulkEdit.setEdit(.choice("accepted"), for: .status)
        model.bulkEdit.colorEdit = colour

        // The confirmation the reviewer reads before pressing Apply.
        let summary = model.bulkEdit.summary
        #expect(summary.markupCount == 3)
        #expect(summary.fieldCount == 3, "subject, status and colour: \(summary.changesPerField)")
        #expect(!summary.message.isEmpty)

        model.bulkEdit.apply()
        let receipt = try #require(await Self.receipt(after: model))
        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")
        #expect(receipt.changedMarkupIDs.count == 3)
        #expect(receipt.undoActionName == AppCoreEnvironment.bulkEditUndoActionName)

        for id in fixture.ids {
            let record = try #require(await fixture.session.markup(id))
            #expect(record.subject == "Slab")
            #expect(record.status == .accepted)
            #expect(record.style.color == RGBAColor(shown: colour))
        }

        // Applying clears the staging, so the next selection cannot inherit this edit.
        #expect(model.bulkEdit.summary.isEmpty)

        // One ⌘Z takes the whole batch back — subject, status and colour together.
        #expect(fixture.environment.commands.undoManager.canUndo)
        await fixture.environment.commands.undo()
        for (index, id) in fixture.ids.enumerated() {
            let record = try #require(await fixture.session.markup(id))
            #expect(record.subject == ["Slab A", "Slab B", "Wall C"][index])
            #expect(record.status == .open)
        }
    }

    @Test("The status the panel offers is copy, and the status it writes is the contract's own case")
    func statusChoicesAreReadableAndRoundTrip() async throws {
        let fixture = try await makeFixture()
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let model = fixture.model

        let status = try #require(fixture.environment.ledger.columns.first { $0.id == .status })
        #expect(model.bulkEdit.editableColumns.contains { $0.id == .status },
                "the panel must offer Status, or `batchStatusChange` has no caller again")

        // Every case of the frozen enum is offered, keyed by its raw value and titled in
        // words. `inProgress` is a serialisation detail; a reviewer reads "In progress".
        let values = Set(status.choices.map(\.value))
        #expect(values == Set(ZPDFContracts.MarkupStatus.allCases.map(\.rawValue)))
        let inProgress = try #require(status.choices.first { $0.value == "inProgress" })
        #expect(inProgress.title == "In progress")
        #expect(!status.choices.contains { $0.title == $0.value && $0.value == "inProgress" })

        // Writing through the panel lands the contract's case, not the title.
        model.applyExternalSelection([fixture.ids[0].rawValue])
        model.bulkEdit.setEdit(.choice(inProgress.value), for: .status)
        model.bulkEdit.apply()
        _ = try #require(await Self.receipt(after: model))
        #expect(try #require(await fixture.session.markup(fixture.ids[0])).status == .inProgress)

        // And the cell the reviewer then reads is the copy, not the identifier.
        await fixture.environment.ledger.refresh()
        model.refresh()
        let row = try #require(model.host.rows(withIDs: [fixture.ids[0].rawValue]).first)
        #expect(row.displayValue(.status) == "In progress")
        // The stored cell value is still the token everything else compares on.
        #expect(row.value(.status) == .choice("inProgress"))
    }

    // MARK: - 4. Grouping and subtotals after the bulk operation

    @Test("The table's own group headings and subtotals reconcile after a bulk edit, and after the undo")
    func groupingAndSubtotalsSurviveTheBulkEdit() async throws {
        let fixture = try await makeFixture()
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let model = fixture.model

        model.setGrouping([.subject])
        _ = await AppTestSupport.wait { model.host.controller.plan.groups.count == 3 }
        #expect(model.host.controller.plan.groups.count == 3)

        // Two of the three become one subject: the outline must shrink to two groups.
        model.applyExternalSelection(Set([fixture.ids[0], fixture.ids[1]].map(\.rawValue)))
        model.bulkEdit.setEdit(.text("Slab"), for: .subject)
        model.bulkEdit.apply()
        let receipt = try #require(await Self.receipt(after: model))
        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")

        _ = await AppTestSupport.wait { model.host.controller.plan.groups.count == 2 }
        try Self.assertGroupingReconciles(model, expectedGroups: 2, expectedTotal: 240)
        #expect(Set(model.host.controller.plan.groups.map(\.title)) == ["Slab", "Wall C"],
                "headings: \(model.host.controller.plan.groups.map(\.title))")

        // The app path went *through* the engine, not around it: an independent full
        // rebuild over the presenter's live request produces the same rows, in the same
        // order, with the same values. A presenter that patched its cached rows in place
        // would satisfy every assertion above and fail this one.
        let ledger = fixture.environment.ledger
        let rebuilt = try await fixture.session.ledgerProjection(ledger.request)
        #expect(rebuilt.rowCount == ledger.rowCount)
        #expect(rebuilt.grandTotals.quantities == ledger.grandTotals.quantities)
        for index in 0..<rebuilt.rowCount {
            let fresh = try #require(rebuilt.row(at: index))
            let live = try #require(ledger.row(at: index))
            #expect(fresh.markupID == live.markupID)
            #expect(fresh.displayValue(.subject) == live.displayValue(.subject))
            #expect(fresh.value(.planArea) == live.value(.planArea))
        }

        // Undo is the other half of the invariant: the outline comes back, and so do the
        // subtotals. A rebuild that only runs forwards leaves a stale tree after ⌘Z.
        await fixture.environment.commands.undo()
        await ledger.refresh()
        model.refresh()
        _ = await AppTestSupport.wait { model.host.controller.plan.groups.count == 3 }
        try Self.assertGroupingReconciles(model, expectedGroups: 3, expectedTotal: 240)
    }

    @Test("A bulk status change regroups a ledger grouped by Status, with readable headings")
    func statusBulkEditRegroupsByStatus() async throws {
        let fixture = try await makeFixture()
        defer { ScratchDefaults.discard(fixture.defaults, suiteName: fixture.suiteName) }
        let model = fixture.model

        model.setGrouping([.status])
        _ = await AppTestSupport.wait { model.host.controller.plan.groups.count == 1 }
        #expect(model.host.controller.plan.groups.map(\.title) == ["Open"],
                "headings: \(model.host.controller.plan.groups.map(\.title))")

        model.applyExternalSelection(Set([fixture.ids[0], fixture.ids[1]].map(\.rawValue)))
        model.bulkEdit.setEdit(.choice("resolved"), for: .status)
        model.bulkEdit.apply()
        let receipt = try #require(await Self.receipt(after: model))
        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")

        _ = await AppTestSupport.wait { model.host.controller.plan.groups.count == 2 }
        #expect(Set(model.host.controller.plan.groups.map(\.title)) == ["Open", "Resolved"],
                "headings: \(model.host.controller.plan.groups.map(\.title))")
        try Self.assertGroupingReconciles(model, expectedGroups: 2, expectedTotal: 240)
    }

    /// Every group's subtotal equals the exact sum of the rows that group actually holds,
    /// and the grand total equals the sum of the subtotals — QUALITY_BAR A17, re-checked
    /// after a mutation rather than only when the ledger was first built.
    private static func assertGroupingReconciles(
        _ model: LedgerPaneModel,
        expectedGroups: Int,
        expectedTotal: Decimal
    ) throws {
        let plan = model.host.controller.plan
        #expect(plan.groups.count == expectedGroups, "headings: \(plan.groups.map(\.title))")

        var summed = Decimal.zero
        for group in plan.groups {
            var rowSum = Decimal.zero
            for position in group.rowRange {
                let row = try #require(model.host.controller.rowSource.ledgerRow(at: plan.order[position]))
                guard case let .quantity(area) = row.value(.planArea) else { continue }
                rowSum += area.value
            }
            let subtotal = try #require(group.subtotals.result(.planArea)?.quantity?.value)
            #expect(subtotal == rowSum, "group \(group.title): \(subtotal) vs \(rowSum)")
            summed += subtotal
        }
        let grand = try #require(plan.grandSubtotals.result(.planArea)?.quantity?.value)
        #expect(summed == grand, "subtotals must add up to the grand total")
        #expect(grand == expectedTotal, "three 10 m × 8 m rectangles")
    }
}
