import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Manual-test findings: the ledger bar's Markups chip counts the markups that carry no
/// quantity (L-50), and every History row names the markup and the change (L-79). Both drive the
/// command bus the manual test went through, then read the presenters the panes read.
@Suite("Manual-test findings — ledger and History (L-50, L-79)")
struct L8LedgerHistoryTests {

    @MainActor
    static func environment() async throws -> (AppCoreEnvironment, ZPDFContracts.PageDescriptor) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, page)
    }

    static func record(
        _ page: ZPDFContracts.PageDescriptor,
        kind: ZPDFContracts.MarkupKind,
        tool: MeasurementTool? = nil,
        x: Double = 0,
        y: Double = 0,
        subject: String = "",
        label: String = ""
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let geometry = MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: y), PDFPoint(x: x + 100, y: y), PDFPoint(x: x + 100, y: y + 80), PDFPoint(x: x, y: y + 80)
        ], isClosed: true))])
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: kind, tool: tool,
            subject: subject, label: label, author: "A. Berg", geometry: geometry,
            createdAt: stamp, modifiedAt: stamp
        )
    }

    // MARK: - L-50

    /// Old output: "Markups 0" on a sheet with four text markups — the chip showed the ledger's
    /// row count, and a markup without a quantity or a subject has no row.
    @Test("L-50: the Markups chip's figure is the markups that carry no quantity")
    @MainActor
    func markupsChipCountsNonMeasurementMarkups() async throws {
        let (environment, page) = try await Self.environment()
        for index in 0..<4 {
            try await environment.commands.perform(.addMarkup(Self.record(page, kind: .text, x: Double(index) * 120)))
        }
        await environment.refresh()
        #expect(environment.ledger.rowCount == 0, "text boxes without a subject have no ledger row")
        let counting: any LedgerMarkupCounting = environment.ledger
        #expect(counting.nonMeasurementMarkupCount == 4)

        // The manual test's sheet: a text, a callout given a subject (so it has a row), and a
        // measured area. Two markups without a quantity; the area is not one of them.
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        try await environment.commands.perform(.addMarkup(Self.record(page, kind: .callout, x: 500, subject: "Note to site")))
        try await environment.commands.perform(.addMarkup(Self.record(page, kind: .measurement, tool: .area, x: 0, subject: "Slab")))
        await environment.refresh()
        #expect(environment.ledger.rowCount == 2, "the callout (it has a subject) and the area")
        #expect(environment.ledger.nonMeasurementMarkupCount == 5, "four texts and the callout")

        // A filter narrows the rows, never the count of markups on the drawing.
        environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), conjunction: .all, rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Slab"))
        ]))
        await environment.ledger.refresh()
        #expect(environment.ledger.rowCount == 1)
        #expect(environment.ledger.nonMeasurementMarkupCount == 5)
    }

    // MARK: - L-79

    @MainActor
    static func attachedHistory(_ environment: AppCoreEnvironment, page: ZPDFContracts.PageDescriptor) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-l8-ledger-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("history.sqlite"))
        environment.history.attach(database: database, projectID: page.documentID.rawValue.uuidString)
        return directory
    }

    /// Old output: every row's markup line was its subject, empty for a text box, a callout or a
    /// shape, so each row read only "1" (the page); Group and Send to Back read "Edited" with
    /// nothing beside them.
    @Test("L-79: every History row names its markup, and a step that changed no value names the command")
    @MainActor
    func historyRowsNameTheMarkupAndTheChange() async throws {
        let (environment, page) = try await Self.environment()
        let directory = try await Self.attachedHistory(environment, page: page)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let text = Self.record(page, kind: .text, x: 0)
        let rectangle = Self.record(page, kind: .rectangle, x: 150, label: "Detail 4")
        let area = Self.record(page, kind: .measurement, tool: .area, x: 300, subject: "Slab", label: "R-1")
        for markup in [text, rectangle, area] {
            try await environment.commands.perform(.addMarkup(markup))
        }
        try await environment.commands.perform(.setMarkupGroup(ids: [text.id, rectangle.id], groupID: MarkupGroupID(UUID())))
        try await environment.commands.perform(.arrangeMarkups(ids: [area.id], arrangement: .sendToBack))
        try await environment.commands.perform(.moveMarkup(id: text.id, dx: 10, dy: 0))
        try await environment.commands.perform(.removeMarkup(rectangle.id))
        await environment.history.settle()

        let events = environment.history.events
        func rows(_ id: MarkupID) -> [LedgerAuditEvent] { events.filter { $0.markupID == id.rawValue } }

        // The markup is named on every row about it, the deletion included.
        #expect(rows(text.id).allSatisfy { $0.markupName == "Text" }, "\(rows(text.id).map(\.markupName))")
        #expect(rows(rectangle.id).allSatisfy { $0.markupName == "Rectangle Detail 4" }, "\(rows(rectangle.id).map(\.markupName))")
        #expect(rows(area.id).allSatisfy { $0.markupName == "Area R-1" }, "\(rows(area.id).map(\.markupName))")
        #expect(rows(rectangle.id).last?.action == "markup_deleted")

        // A text box placed is not "Measured" (the presented action, L-99); an area is.
        #expect(rows(text.id).first?.actionDisplayName != "Measured")
        #expect(rows(area.id).first?.actionDisplayName == "Measured")

        // Group, Send to Back and a move change no value, so the row says which command ran.
        let grouped = rows(text.id).filter { $0.commandName == "Group" }
        #expect(grouped.count == 1)
        #expect(grouped.first?.changes.isEmpty == true)
        #expect(rows(area.id).contains { $0.commandName == "Send to Back" })
        #expect(rows(text.id).contains { $0.commandName == "Move Markup" })

        // A label renamed later renames the older rows too, as a subject rename already did.
        try await environment.commands.perform(.editLabel(id: area.id, label: "R-2"))
        await environment.history.settle()
        await environment.refresh()
        #expect(environment.history.events.filter { $0.markupID == area.id.rawValue }.allSatisfy { $0.markupName == "Area R-2" })
    }

    /// Re-check of L-79. Old output, on a calibrated area: the Send to Back row read
    /// "Edited · Area R-1 · Slab · Page 1" over "Plan Area 80 m²\nPerimeter 36 m" — every
    /// measured value, unchanged, written on both sides — and the command's name never showed.
    /// Group, Align and a move read the same. `historyDetail` is what `HistoryPaneContent.detailText`
    /// shows (`L8LedgerShellTests` pins that).
    @Test("L-79: on a measured area, a step that changed no value reads the command, not the unchanged values")
    @MainActor
    func measuredMarkupRowsNameTheCommand() async throws {
        let (environment, page) = try await Self.environment()
        let directory = try await Self.attachedHistory(environment, page: page)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        // Off-grid coordinates, so a translation can move the last bits of the computed area.
        let area = Self.record(page, kind: .measurement, tool: .area, x: 300.37, y: 12.11, subject: "Slab", label: "R-1")
        let other = Self.record(page, kind: .measurement, tool: .area, x: 37.9, y: 0.7, subject: "Slab", label: "R-2")
        for markup in [area, other] {
            try await environment.commands.perform(.addMarkup(markup))
        }
        // R-2 was placed last, so it is the one Send to Back moves.
        try await environment.commands.perform(.arrangeMarkups(ids: [other.id], arrangement: .sendToBack))
        try await environment.commands.perform(.setMarkupGroup(ids: [area.id, other.id], groupID: MarkupGroupID(UUID())))
        #expect(await environment.layOutMarkups([area.id.rawValue, other.id.rawValue], .top) == nil)
        try await environment.commands.perform(.moveMarkup(id: area.id, dx: 13.7, dy: -4.3))
        await environment.history.settle()

        let ids: Set<UUID> = [area.id.rawValue, other.id.rawValue]
        func row(_ command: String) -> LedgerAuditEvent? {
            environment.history.events.last { $0.commandName == command && $0.markupID.map(ids.contains) == true }
        }
        let sent = try #require(row("Send to Back"))
        #expect(sent.action == "markup_modified")
        #expect(sent.historyDetail == "Send to Back", "\(sent.historyDetail ?? "nil")")
        // Group rewrites the record, so its row holds every measured value on both sides — the
        // trail keeps the whole state — and none of them moved.
        let grouped = try #require(row("Group"))
        #expect(grouped.changes.contains { $0.field == "netArea" }, "the trail still records the whole state: \(grouped.changes.map(\.field))")
        #expect(grouped.visibleChanges.isEmpty, "\(grouped.visibleChanges)")
        #expect(grouped.historyDetail == "Group", "\(grouped.historyDetail ?? "nil")")
        #expect(row("Align Top")?.historyDetail == "Align Top", "\(row("Align Top")?.historyDetail ?? "nil")")
        #expect(row("Move Markup")?.historyDetail == "Move Markup", "\(row("Move Markup")?.historyDetail ?? "nil")")

        // The creation still lists what was measured, and a step that changed something lists
        // only what moved.
        let measured = try #require(environment.history.events.first { $0.markupID == area.id.rawValue })
        #expect(measured.historyDetail?.contains("Plan Area") == true, "\(measured.historyDetail ?? "nil")")
        try await environment.commands.perform(.editSubject(id: area.id, subject: "Roof"))
        await environment.history.settle()
        let renamed = try #require(row("Edit Subject") ?? environment.history.events.last { $0.markupID == area.id.rawValue })
        #expect(renamed.historyDetail == "Subject Slab → Roof", "\(renamed.historyDetail ?? "nil")")

        // Undoing a step that changed no value names that step, not the compensation's
        // bookkeeping note ("compensates <id>").
        try await environment.commands.perform(.arrangeMarkups(ids: [other.id], arrangement: .bringToFront))
        await environment.commands.undo()
        await environment.history.settle()
        let undone = try #require(environment.history.events.last)
        #expect(undone.action == "compensated")
        #expect(undone.historyDetail == "Bring to Front", "\(undone.historyDetail ?? "nil")")
    }

    /// Re-check of L-79, the smaller gap. Old output: the name lived only in this session's
    /// memory, so after a reopen every row of a markup deleted earlier named nothing.
    @Test("L-79: a markup deleted before the project was closed is still named after a reopen")
    @MainActor
    func deletedMarkupIsNamedAfterReopen() async throws {
        let (environment, page) = try await Self.environment()
        let directory = try await Self.attachedHistory(environment, page: page)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let area = Self.record(page, kind: .measurement, tool: .area, x: 300, subject: "Slab", label: "R-1")
        let note = Self.record(page, kind: .text, x: 0)
        for markup in [area, note] {
            try await environment.commands.perform(.addMarkup(markup))
        }
        try await environment.commands.perform(.arrangeMarkups(ids: [area.id], arrangement: .bringToFront))
        try await environment.commands.perform(.removeMarkup(area.id))
        try await environment.commands.perform(.removeMarkup(note.id))
        await environment.history.settle()
        environment.history.detach()

        // The project reopened: a new feed over the same file, which has never seen either markup.
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("history.sqlite"))
        let reopened = AppHistoryPresenter(actorName: "A. Berg")
        reopened.attach(database: database, projectID: page.documentID.rawValue.uuidString)
        await reopened.settle()

        let areaRows = reopened.events.filter { $0.markupID == area.id.rawValue }
        let noteRows = reopened.events.filter { $0.markupID == note.id.rawValue }
        #expect(areaRows.count == 3, "created, brought to front, deleted: \(areaRows.map(\.action))")
        #expect(areaRows.allSatisfy { $0.markupName == "Area R-1" }, "\(areaRows.map(\.markupName))")
        #expect(noteRows.count == 2)
        #expect(noteRows.allSatisfy { $0.markupName == "Text" }, "\(noteRows.map(\.markupName))")
        // The stored name is the row's name, never one of its changes.
        let all = areaRows + noteRows
        #expect(all.allSatisfy { !$0.changes.contains { $0.field == AppHistoryPresenter.recordedNameField } })
        #expect(noteRows.first?.actionDisplayName == "Added", "a text box is still added, not measured")
        #expect(areaRows.first(where: { $0.commandName == "Bring to Front" })?.historyDetail == "Bring to Front")
    }

    @Test("L-79: a label that already says the kind is the whole name")
    func markupNameRule() {
        #expect(AppHistoryPresenter.markupName(kind: .measurement, tool: .length, label: "Length A") == "Length A")
        #expect(AppHistoryPresenter.markupName(kind: .measurement, tool: .length, label: "Kerb run") == "Length Kerb run")
        #expect(AppHistoryPresenter.markupName(kind: .image, tool: nil, label: "  ") == "Image")
        #expect(AppHistoryPresenter.markupName(kind: .note, tool: nil, label: "") == "Note")
    }
}
