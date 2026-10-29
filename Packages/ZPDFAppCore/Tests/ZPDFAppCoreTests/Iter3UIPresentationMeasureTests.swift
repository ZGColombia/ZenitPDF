import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The review presenter's assignment
/// lookup and the ledger bridge's error diagnostics.
@Suite("Iteration 3 — measurement presentation, app core")
struct Iter3UIPresentationMeasureTests {

    // MARK: - T-059

    private static func assignment(
        _ id: String, markup: UUID, to assignee: String, due: String?, at seconds: TimeInterval, by author: String = "Ada"
    ) throws -> ReviewEntryRecord {
        let body = try JSONEncoder().encode(AppReviewPresenter.AssignmentBody(assignee: assignee, due: due))
        return ReviewEntryRecord(
            id: id, projectId: "p", markupId: markup.uuidString,
            kind: ReviewEntryRecord.Kind.assignment.rawValue, authorName: author,
            body: String(decoding: body, as: UTF8.self),
            createdAt: PersistenceTimestamp.string(from: Date(timeIntervalSince1970: seconds))
        )
    }

    /// Old output: every call scanned every entry, decoded the body and built a DateFormatter —
    /// the Review List paid that once per row per render. Now the index is built once per change
    /// of the entries and answers every markup from it, with the same answers as before: the
    /// latest live assignment wins, a cleared one hides an older one, a retracted one does not
    /// count.
    @MainActor
    @Test("T-059: assignments are answered from one index per change, with the old answers")
    func assignmentIndex() throws {
        let presenter = AppReviewPresenter(undoManager: UndoManager())
        let a = UUID(), b = UUID(), c = UUID()
        presenter.recordWithoutUndo([
            try Self.assignment("1", markup: a, to: "Bo", due: "2026-10-01", at: 100),
            try Self.assignment("2", markup: a, to: "Cy", due: nil, at: 200),
            try Self.assignment("3", markup: b, to: "Bo", due: "2026-10-02", at: 100),
            try Self.assignment("4", markup: b, to: "", due: nil, at: 300),
            try Self.assignment("5", markup: c, to: "Di", due: "2026-10-03", at: 100)
        ])
        let builds = presenter.assignmentIndexBuildCount
        #expect(presenter.assignment(for: a)?.assignee == "Cy", "the latest assignment wins")
        #expect(presenter.assignment(for: a)?.due == nil)
        #expect(presenter.assignment(for: b) == nil, "a cleared assignment hides the older one")
        #expect(presenter.assignment(for: c)?.assignee == "Di")
        #expect(presenter.assignment(for: c)?.due == AppReviewPresenter.day(from: "2026-10-03"))
        #expect(presenter.assignment(for: c)?.assignedBy == "Ada")
        #expect(presenter.assignment(for: UUID()) == nil)
        for _ in 0..<500 { _ = presenter.assignment(for: a) }
        #expect(presenter.assignmentIndexBuildCount - builds == 1, "one build for 507 lookups")

        // A change to the entries is seen at once: withdrawing a's latest brings Bo back.
        presenter.applyRetraction("2", true)
        #expect(presenter.assignment(for: a)?.assignee == "Bo")
        #expect(presenter.assignment(for: a)?.due == AppReviewPresenter.day(from: "2026-10-01"))
        #expect(presenter.assignmentIndexBuildCount - builds == 2)
    }

    @MainActor
    @Test("T-059: a due day round-trips through the shared formatter")
    func dayRoundTrip() throws {
        let day = try #require(AppReviewPresenter.day(from: "2026-02-28"))
        #expect(AppReviewPresenter.dayString(day) == "2026-02-28")
        #expect(AppReviewPresenter.day(from: "not a day") == nil)
        #expect(AppReviewPresenter.dayString(try #require(AppReviewPresenter.day(from: "2026-12-31"))) == "2026-12-31")
    }

    // MARK: - T-057

    static let documentID = DocumentID(UUID(uuidString: "00000000-0000-4000-8000-00000000E001")!)
    static let pageID = PageID(UUID(uuidString: "00000000-0000-4000-8000-00000000E002")!)

    /// Old output: the Ratio cell read "Formula error" and the row carried nothing that said
    /// why; now it reads "Divide by zero" and carries the engine's diagnostic for the help tag.
    @Test("T-057: a formula cell that divides by zero says so, and its row carries the diagnostic")
    func bridgeCarriesTheDiagnostic() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-0000000000E3")!),
            documentID: Self.documentID, pageID: Self.pageID, kind: .measurement, tool: .length,
            subject: "Rebar", author: "t",
            geometry: MeasurementGeometry(pageID: Self.pageID, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 4, y: 0)]),
            measurement: MeasurementResult(values: [.planLength: .length(4)]),
            createdAt: stamp, modifiedAt: stamp
        )
        let standard = try LedgerColumnSet.standard()
        let ratioID = ColumnID(UUID(uuidString: "00000000-0000-4000-8000-0000000000E4")!)
        let ratio = LedgerColumnDefinition(
            id: ratioID, key: "custom.ratio", title: "Ratio", kind: .formula, dimension: .count,
            formula: FormulaExpression(source: "Length / (Length - Length)"), isEditable: false,
            order: standard.columns.count
        )
        let store = try LedgerStore(markups: [record], columns: LedgerColumnSet(columns: standard.columns + [ratio]))
        let view = store.makeView(LedgerViewSpec())
        let row = LedgerBridge.row(view: view, displayIndex: 0, formatter: QuantityFormatter(units: .metric))
        let column = LedgerColumnID("custom.ratio")
        #expect(row.displayValues[column] == "Divide by zero", "old output: Formula error")
        let note = try #require(row.cellNote(column), "old output: no diagnostic on the row")
        #expect(note.hasPrefix("Division by zero in `"), "\(note)")
        // Cells that did not fail carry no note.
        #expect(row.cellNotes?.count == 1)
    }
}
