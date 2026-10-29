import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The ledger's power tools, driven through the shipping presenter and the shipping
/// command bus — no test double stands in for either.
///
/// Three claims are under test, and all three are the kind that only fail in front of a
/// user:
///
/// 1. **One undo for the whole batch.** A reviewer who changes nineteen rows presses ⌘Z
///    once, not nineteen times.
/// 2. **One audit entry per affected markup** (ADR-0007 §2), all under one `undo_group`,
///    with the undo appending one compensation for each.
/// 3. **The grouping and subtotal invariants survive the edit**, because the app path
///    rebuilds the projection through the engine rather than patching rows behind it.
@Suite("Ledger bulk edit")
struct LedgerBulkEditTests {

    // MARK: Fixture

    private struct Fixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let documentID: DocumentID
        let page: ZPDFContracts.PageDescriptor
        let ids: [MarkupID]
    }

    /// One calibrated page carrying three identical 100 × 80 pt rectangles at 0.1 m/pt,
    /// so every row is exactly 80 m² and any arithmetic slip is visible by eye.
    @MainActor
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
        for subject in subjects {
            let id = MarkupID(UUID())
            try await environment.commands.perform(
                .addMarkup(Self.markup(id: id, documentID: documentID, pageID: page.id, subject: subject))
            )
            ids.append(id)
        }
        await environment.ledger.refresh()
        return Fixture(
            environment: environment,
            session: session,
            documentID: documentID,
            page: page,
            ids: ids
        )
    }

    private static func markup(
        id: MarkupID,
        documentID: DocumentID,
        pageID: PageID,
        subject: String,
        locked: Bool = false
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: subject,
            author: "test",
            status: .open,
            locked: locked,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    private static func makeDatabase() async throws -> (ProjectDatabaseActor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-bulkedit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        return (database, directory)
    }

    // MARK: 1 — One undo for the whole batch

    @Test("The summary the Inspector reads carries every style field, not just the colour")
    @MainActor
    func theSummaryCarriesTheWholeStyle() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)

        _ = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: [fixture.ids[0].rawValue],
                style: MarkupStyleEdit(
                    color: ColorRGBA(red: 0.9, green: 0.2, blue: 0.1, alpha: 1),
                    lineWidth: 7,
                    opacity: 0.5,
                    lineStyle: .dotted,
                    fontSize: 21
                )
            )
        )

        // Until 2026-08-27 `MarkupSummary` carried only `colorRGBA`, so the Inspector had nothing
        // to show a line width *from*. Half of "you cannot change the line width" was that
        // nothing could display one.
        await environment.refresh()
        let summary = try #require(
            environment.canvas.allMarkupsForTesting.first { $0.id == fixture.ids[0].rawValue },
            "the markup is not in the canvas snapshot"
        )
        #expect(summary.lineWidth == 7)
        #expect(summary.opacity == 0.5)
        #expect(summary.lineStyle == MarkupLineStyle.dotted)
        #expect(summary.fontSize == 21)
        #expect(summary.colorRGBA.hexString.uppercased() == "#E6331A")
    }

    // MARK: - Appearance, from the Inspector

    @Test("An appearance edit writes every named field and leaves the rest alone")
    @MainActor
    func styleEditWritesOnlyWhatItNames() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)

        let before = try #require(await fixture.session.markup(fixture.ids[0]))
        let originalColour = before.style.color
        let originalFont = before.style.fontSize

        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                style: MarkupStyleEdit(lineWidth: 6.5, opacity: 0.4, lineStyle: .dashed)
            )
        )
        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")
        #expect(receipt.changedMarkupIDs.count == 3)

        for id in fixture.ids {
            let record = try #require(await fixture.session.markup(id))
            #expect(record.style.lineWidth == 6.5)
            #expect(record.style.opacity == 0.4)
            #expect(record.style.lineStyle == .dashed)
            // Untouched, because the edit did not name them. This is the rule that lets one
            // control reach a selection the user has not made uniform.
            #expect(record.style.color == originalColour, "the colour moved without being asked")
            #expect(record.style.fontSize == originalFont, "the text size moved without being asked")
        }
    }

    @Test("An appearance edit over three markups is one undo step")
    @MainActor
    func styleEditIsOneUndoStep() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)
        let before = try #require(await fixture.session.markup(fixture.ids[0])).style.lineWidth

        _ = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                style: MarkupStyleEdit(lineWidth: 9)
            )
        )
        for id in fixture.ids {
            #expect(try #require(await fixture.session.markup(id)).style.lineWidth == 9)
        }

        await environment.commands.undo()
        for id in fixture.ids {
            #expect(
                try #require(await fixture.session.markup(id)).style.lineWidth == before,
                "one Undo did not take all three widths back"
            )
        }
    }

    @Test("Setting a field to the value it already holds writes no command")
    @MainActor
    func aNoOpStyleEditChangesNothing() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)
        let current = try #require(await fixture.session.markup(fixture.ids[0])).style.lineWidth

        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                style: MarkupStyleEdit(lineWidth: current)
            )
        )
        // Not a failure — simply nothing to do. An undo step that restores what was already
        // there is noise on the stack, and an audit entry saying "changed nothing" is worse.
        #expect(receipt.changedMarkupIDs.isEmpty)
        #expect(receipt.auditEntryCount == 0)
    }

    @Test("An empty appearance edit is an empty request")
    func anEmptyStyleEditIsEmpty() {
        #expect(MarkupStyleEdit().isEmpty)
        #expect(MarkupStyleEdit(lineWidth: 2).isEmpty == false)
        #expect(LedgerBulkEditRequest(markupIDs: [UUID()]).isEmpty)
        #expect(LedgerBulkEditRequest(markupIDs: [UUID()], style: MarkupStyleEdit(opacity: 0.5)).isEmpty == false)
    }

    @Test("Subject, status and colour across three markups is one undo step")
    @MainActor
    func bulkEditIsOneUndoStep() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        let colour = ColorRGBA(red: 0.1, green: 0.7, blue: 0.9, alpha: 1)

        // The presenter is reached through the protocol the pane uses, not through a
        // concrete type: if the conformance is ever dropped the pane loses Apply, and so
        // does this test.
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                values: [.subject: .text("Slab"), .status: .choice("accepted")],
                color: colour
            )
        )

        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")
        #expect(receipt.changedMarkupIDs.count == 3)
        #expect(receipt.undoActionName == AppCoreEnvironment.bulkEditUndoActionName)

        for id in fixture.ids {
            let record = try #require(await fixture.session.markup(id))
            #expect(record.subject == "Slab")
            #expect(record.status == .accepted)
            #expect(record.style.color == RGBAColor(shown: colour))
        }

        // One ⌘Z, and all three are back — subject, status and colour together.
        #expect(environment.commands.undoManager.canUndo)
        await environment.commands.undo()
        for (index, id) in fixture.ids.enumerated() {
            let record = try #require(await fixture.session.markup(id))
            #expect(record.subject == ["Slab A", "Slab B", "Wall C"][index])
            #expect(record.status == .open)
            #expect(record.style.color != RGBAColor(shown: colour))
        }

        // And the entry it consumed was exactly one: the next ⌘Z is the third `addMarkup`,
        // not more of the bulk edit.
        await environment.commands.undo()
        #expect(await fixture.session.markup(fixture.ids[2]) == nil)
        #expect(await fixture.session.markup(fixture.ids[1]) != nil)
    }

    @Test("Redo puts the whole batch back, also in one step")
    @MainActor
    func bulkEditRedoIsOneStep() async throws {
        let fixture = try await makeFixture()
        let editor = try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
        _ = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                values: [.label: .text("L-01")]
            )
        )
        await fixture.environment.commands.undo()
        #expect(try #require(await fixture.session.markup(fixture.ids[0])).label.isEmpty)

        await fixture.environment.commands.redo()
        for id in fixture.ids {
            #expect(try #require(await fixture.session.markup(id)).label == "L-01")
        }
    }

    // MARK: 2 — Refusals are whole, and loud

    @Test("A locked markup in the selection refuses the whole batch and changes nothing")
    @MainActor
    func lockedMarkupRefusesTheBatch() async throws {
        let fixture = try await makeFixture()
        let lockedID = MarkupID(UUID())
        try await fixture.environment.commands.perform(
            .addMarkup(Self.markup(
                id: lockedID,
                documentID: fixture.documentID,
                pageID: fixture.page.id,
                subject: "Locked",
                locked: true
            ))
        )

        let editor = try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set((fixture.ids + [lockedID]).map(\.rawValue)),
                values: [.subject: .text("Slab")]
            )
        )

        #expect(receipt.didFail)
        #expect(receipt.changedMarkupIDs.isEmpty)
        // Not one of the unlocked three moved: a partly-applied bulk edit is the outcome
        // the reviewer then has to unpick by hand.
        for (index, id) in fixture.ids.enumerated() {
            let record = try #require(await fixture.session.markup(id))
            #expect(record.subject == ["Slab A", "Slab B", "Wall C"][index])
        }
        #expect(try #require(await fixture.session.markup(lockedID)).subject == "Locked")
    }

    @Test("Writing the value a markup already holds registers no undo entry")
    @MainActor
    func noOpEditRegistersNothing() async throws {
        let fixture = try await makeFixture(subjects: ["Slab", "Slab", "Slab"])
        let editor = try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
        let manager = fixture.environment.commands.undoManager
        let before = manager.undoActionName

        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                values: [.subject: .text("Slab")]
            )
        )
        #expect(!receipt.didFail)
        #expect(receipt.changedMarkupIDs.isEmpty)
        // The Edit menu still offers the previous step, not "Undo Bulk Edit" over nothing.
        #expect(manager.undoActionName == before)
        #expect(manager.undoActionName != AppCoreEnvironment.bulkEditUndoActionName)
    }

    // MARK: 3 — One audit entry per affected markup (ADR-0007 §2)

    @Test("The trail records one entry per markup under one undo group, and undo compensates every one")
    @MainActor
    func auditFansOutPerMarkup() async throws {
        let fixture = try await makeFixture()
        let (database, directory) = try await Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = fixture.environment
        environment.history.attach(
            database: database,
            projectID: fixture.documentID.rawValue.uuidString
        )
        await environment.history.settle()
        let baseline = environment.history.events.count

        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set(fixture.ids.map(\.rawValue)),
                values: [.status: .choice("resolved")]
            )
        )
        await environment.history.settle()
        #expect(receipt.auditEntryCount == 3)

        let appended = Array(environment.history.events.dropFirst(baseline))
        #expect(appended.count == 3, "one entry per affected markup, got \(appended.count)")
        #expect(Set(appended.compactMap(\.markupID)) == Set(fixture.ids.map(\.rawValue)))
        #expect(appended.allSatisfy { $0.action == "markup_modified" })
        let groups = Set(appended.compactMap(\.undoGroup))
        #expect(groups.count == 1, "one undo_group for the whole step, got \(groups)")
        // A status-only step is named for what it did. Old output: "Bulk Edit".
        #expect(appended.allSatisfy { $0.commandName == "Change Status (3 Markups)" })

        // The undo appends three compensations — one per original — and edits nothing.
        await environment.commands.undo()
        await environment.history.settle()
        let compensations = Array(environment.history.events.dropFirst(baseline + 3))
        #expect(compensations.count == 3)
        #expect(compensations.allSatisfy { $0.action == "compensated" })
        #expect(Set(compensations.compactMap(\.markupID)) == Set(fixture.ids.map(\.rawValue)))
        #expect(Set(compensations.compactMap(\.undoGroup)).count == 1)
        // Append-only: the three originals are still exactly where they were.
        #expect(Array(environment.history.events.dropFirst(baseline).prefix(3)).map(\.action)
                == ["markup_modified", "markup_modified", "markup_modified"])

        // And a redo compensates the compensations, so the chain keeps growing forwards.
        await environment.commands.redo()
        await environment.history.settle()
        let redone = Array(environment.history.events.dropFirst(baseline + 6))
        #expect(redone.count == 3)
        #expect(redone.allSatisfy { $0.action == "recompensated" })
    }

    @Test("A plain batch status change also fans out, one entry per markup")
    @MainActor
    func batchStatusChangeFansOut() async throws {
        let fixture = try await makeFixture()
        let (database, directory) = try await Self.makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        fixture.environment.history.attach(
            database: database,
            projectID: fixture.documentID.rawValue.uuidString
        )
        await fixture.environment.history.settle()
        let baseline = fixture.environment.history.events.count

        try await fixture.environment.commands.perform(
            .batchStatusChange(ids: fixture.ids, status: .accepted)
        )
        await fixture.environment.history.settle()

        let appended = Array(fixture.environment.history.events.dropFirst(baseline))
        #expect(appended.count == 3, "a twelve-markup status change is not a one-markup entry")
        #expect(Set(appended.compactMap(\.markupID)) == Set(fixture.ids.map(\.rawValue)))
        #expect(Set(appended.compactMap(\.undoGroup)).count == 1)
    }

    // MARK: 4 — Grouping and subtotal invariants after the edit

    @Test("Grouped subtotals reconcile with their rows, and with a full rebuild, after a bulk edit")
    @MainActor
    func groupingSurvivesBulkEdit() async throws {
        let fixture = try await makeFixture()
        let environment = fixture.environment
        environment.ledger.setGrouping([.subject])
        await environment.ledger.refresh()
        #expect(environment.ledger.rootGroups.count == 3)

        // Two of the three become one subject: the group tree must shrink to two.
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(
            LedgerBulkEditRequest(
                markupIDs: Set([fixture.ids[0], fixture.ids[1]].map(\.rawValue)),
                values: [.subject: .text("Slab")]
            )
        )
        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")
        await environment.ledger.refresh()

        let ledger = environment.ledger
        #expect(ledger.rowCount == 3)
        #expect(ledger.rootGroups.count == 2, "titles: \(ledger.rootGroups.map(\.title))")

        // Every group's subtotal equals the exact sum of the rows the group actually
        // holds — the reconciliation QUALITY_BAR A17 asks for, re-checked after the
        // mutation rather than only when the ledger was first built.
        let rows = (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }
        var perSubject: [String: Decimal] = [:]
        for row in rows {
            guard case let .quantity(area) = row.value(.planArea) else { continue }
            perSubject[row.displayValue(.subject), default: 0] += area.value
        }
        var groupSum = Decimal.zero
        for group in ledger.rootGroups {
            let subtotal = try #require(group.totals.total(.planArea)?.value)
            #expect(subtotal == perSubject[Self.groupedValue(of: group)], "group \(group.title)")
            groupSum += subtotal
        }
        // And the grand total is the sum of the subtotals, exactly.
        let grand = try #require(ledger.grandTotals.total(.planArea)?.value)
        #expect(groupSum == grand)
        #expect(grand == Decimal(240), "three 10 m × 8 m rectangles")

        // The app path went *through* the engine, not around it: an independent full
        // rebuild over the same request produces the same tree, the same order and the
        // same totals. A presenter that patched its cached rows in place would pass every
        // assertion above and fail this one.
        let rebuilt = try await fixture.session.ledgerProjection(ledger.request)
        #expect(rebuilt.rowCount == ledger.rowCount)
        #expect(rebuilt.grandTotals.quantities == ledger.grandTotals.quantities)
        #expect(rebuilt.rootGroups.map(\.title) == ledger.rootGroups.map(\.title))
        #expect(
            rebuilt.rootGroups.map { $0.totals.total(.planArea)?.value }
                == ledger.rootGroups.map { $0.totals.total(.planArea)?.value }
        )
        for index in 0..<rebuilt.rowCount {
            let fresh = try #require(rebuilt.row(at: index))
            let live = try #require(ledger.row(at: index))
            #expect(fresh.markupID == live.markupID)
            #expect(fresh.displayValue(.subject) == live.displayValue(.subject))
            #expect(fresh.value(.planArea) == live.value(.planArea))
        }
    }

    /// The grouped value behind an outline node.
    ///
    /// `groupingValue` is the engine's *typed* group token — `"t:Slab"` for a text key,
    /// `"o:<uuid>"` for a choice — and stays that way, because ordering, expansion identity
    /// and round-tripping all compare on it. `title` is the heading a person reads and is
    /// asserted separately by ``groupTitlesAreCopy``; this helper decodes the token because
    /// the arithmetic, not the wording, is what the caller is checking.
    private static func groupedValue(of group: ZPDFUIPresentation.LedgerGroupNode) -> String {
        let token = group.groupingValue ?? group.title
        guard let colon = token.firstIndex(of: ":") else { return token }
        return String(token[token.index(after: colon)...])
    }

    @Test("Group headings and choice cells are copy; the tokens underneath them are unchanged")
    @MainActor
    func groupTitlesAreCopy() async throws {
        let fixture = try await makeFixture()
        let ledger = fixture.environment.ledger

        // A text key: the heading is the subject, not `t:Slab A`.
        ledger.setGrouping([.subject])
        await ledger.refresh()
        #expect(ledger.rootGroups.map(\.title).sorted() == ["Slab A", "Slab B", "Wall C"])
        // …and the value everything compares on is still the typed token.
        #expect(ledger.rootGroups.allSatisfy { ($0.groupingValue ?? "").hasPrefix("t:") })

        // A choice key: `MarkupStatus.inProgress` is a serialisation detail. The heading,
        // the cell and the bulk-edit menu all have to read "In progress".
        let editor = try #require(ledger as? any LedgerBulkEditPresenting)
        let receipt = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: Set([fixture.ids[0]].map(\.rawValue)),
            values: [.status: .choice("inProgress")]
        ))
        #expect(!receipt.didFail, "refusal: \(receipt.failureDescription ?? "")")
        ledger.setGrouping([.status])
        await ledger.refresh()
        #expect(ledger.rootGroups.map(\.title).sorted() == ["In progress", "Open"],
                "headings: \(ledger.rootGroups.map(\.title))")
        #expect(ledger.rootGroups.allSatisfy { ($0.groupingValue ?? "").hasPrefix("o:") })

        let row = try #require((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }
            .first { $0.markupID == fixture.ids[0].rawValue })
        #expect(row.displayValue(.status) == "In progress")
        #expect(row.value(.status) == .choice("inProgress"), "the stored token is untouched")

        let status = try #require(ledger.columns.first { $0.id == .status })
        #expect(Set(status.choices.map(\.value))
            == Set(ZPDFContracts.MarkupStatus.allCases.map(\.rawValue)))
        #expect(status.choices.first { $0.value == "inProgress" }?.title == "In progress")
    }

    // MARK: 5 — A filtered export stays labelled as filtered (QUALITY_BAR A35)

    @Test("A filtered ledger exports as filtered: labelled, counted, and reconciling with its own rows")
    @MainActor
    func filteredExportStaysLabelled() async throws {
        let fixture = try await makeFixture(subjects: ["Slab", "Slab", "Wall"])
        let ledger = fixture.environment.ledger

        let unfiltered = try await fixture.session.exportReportWithDiagnostics(title: "T", request: ledger.request).report
        #expect(unfiltered.metadata.rowCount == 3)
        #expect(unfiltered.metadata.totalRowCountBeforeFilter == 3)
        #expect(!ledger.isFiltered)
        #expect(ledger.unfilteredRowCount == 3)

        ledger.setFilter(
            LedgerFilterGroup(
                id: UUID(),
                rules: [LedgerFilterRule(
                    id: UUID(),
                    column: .subject,
                    comparison: .equals,
                    operand: .text("Slab")
                )]
            )
        )
        await ledger.refresh()

        #expect(ledger.rowCount == 2)
        #expect(ledger.isFiltered)
        #expect(ledger.unfilteredRowCount == 3, "the pane's denominator is the whole takeoff")

        // The export is built over the *live* request, so it is the ledger on screen —
        // and it says so. Built over an empty spec (as it was) this reports three rows,
        // three before the filter and "No filter applied", under a save panel that
        // promises "the Quantity Ledger as it is on screen".
        let report = try await fixture.session.exportReportWithDiagnostics(title: "T", request: ledger.request).report
        #expect(report.metadata.rowCount == 2)
        #expect(report.metadata.totalRowCountBeforeFilter == 3)
        #expect(report.metadata.filterDescription != unfiltered.metadata.filterDescription)
        #expect(report.metadata.filterDescription.contains("subject"))

        // A35, inside the file: the printed total equals the exact sum of the printed rows.
        let areaColumn = try #require(report.columns.first { $0.key == "planArea" })
        var rowSum = Decimal.zero
        for row in report.allRows() {
            guard let cell = row.cells.first(where: { $0.column == areaColumn.id }),
                  let raw = cell.rawDecimal else { continue }
            rowSum += raw
        }
        let grand = try #require(
            report.grandTotals.first { $0.column == areaColumn.id && $0.function == .sum }?.rawDecimal
        )
        #expect(rowSum == grand)
        #expect(grand == Decimal(160), "two of the three rectangles, 80 m² each")
    }
}
