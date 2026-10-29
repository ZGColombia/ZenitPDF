import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Quality-loop iteration 3, area "ui-presentation-measure": the Review List's row build and its
/// day, the ledger row's error diagnostics and the Rectangle Area's point rule.
@Suite("Iteration 3 ui-presentation-measure (review list, ledger row, measurement rules)")
struct Iter3UIPresentationMeasureTests {

    // MARK: - T-059

    /// Old output: two lookups per row — `assignee` and `due` each called
    /// `assignment(for:)` — so 2 × markups per render of the pane.
    @MainActor
    @Test("T-059: the Review List row build asks for each markup's assignment once")
    func oneAssignmentLookupPerRow() {
        let presenter = MockReviewThreadPresenter(author: "Reviewer")
        let markups = Array(ZenitSampleProject.shared.markups.prefix(6))
        #expect(markups.count == 6)
        presenter.reviewMarkups = markups
        let due = Date(timeIntervalSince1970: 1_790_000_000)
        presenter.assign([markups[0].id, markups[3].id], to: "Anna", due: due)
        let before = presenter.assignmentLookupCount
        let rows = ReviewList.rows(markups: markups, threads: presenter)
        #expect(presenter.assignmentLookupCount - before == markups.count, "old output: \(markups.count * 2)")
        #expect(rows[0].assignee == "Anna")
        #expect(rows[0].due == due)
        #expect(rows[3].assignee == "Anna")
        #expect(rows[1].assignee.isEmpty)
        #expect(rows[1].due == nil)
    }

    // MARK: - T-061

    private static func row(due: Date?) -> ReviewListRow {
        ReviewListRow(
            id: UUID(), pageLabel: "A-101", pageIndex: 0, kind: .text, kindName: "Text", subject: "S",
            note: "", author: "a", status: .open, replyCount: 0,
            lastActivity: Date(timeIntervalSince1970: 0), searchText: "S", due: due
        )
    }

    /// Old output: a filter made on day D kept `today = D` (its `Date()` default), so the next
    /// day a markup due on D was still "not overdue" and the Overdue filter hid it.
    @Test("T-061: an unset 'today' is the day the list is built, not the day the filter was made")
    func overdueFollowsTheDayTheListIsBuilt() throws {
        var filter = ReviewListFilter()
        #expect(filter.today == nil)
        filter.onlyOverdue = true
        let calendar = Calendar.current
        let noon = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000)))
        let nextNoon = try #require(calendar.date(byAdding: .day, value: 1, to: noon))
        let dueToday = Self.row(due: noon)
        // Built on the due day: not overdue. Built the next day, with the same filter: overdue.
        #expect(ReviewList.visible([dueToday], filter: filter, sort: .page, now: noon).isEmpty)
        #expect(ReviewList.visible([dueToday], filter: filter, sort: .page, now: nextNoon).map(\.id) == [dueToday.id])
        // A filter pinned to a day still counts against that day.
        filter.today = noon
        #expect(ReviewList.visible([dueToday], filter: filter, sort: .page, now: nextNoon).isEmpty)
        // Two fresh filters are the same filter (they used to differ by their creation instant).
        #expect(ReviewListFilter() == ReviewListFilter())
    }

    // MARK: - T-057

    @Test("T-057: a ledger row carries an error cell's diagnostic, and rows encoded without it still decode")
    func ledgerRowCellNotes() throws {
        let column = LedgerColumnID("quotient")
        var row = LedgerRow(
            markupID: UUID(),
            values: [column: .text("Divide by zero")],
            displayValues: [column: "Divide by zero"],
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            kind: .measurement
        )
        #expect(row.cellNote(column) == nil)
        row.cellNotes = [column: "Division by zero in `100 / [Divisor]`."]
        #expect(row.cellNote(column) == "Division by zero in `100 / [Divisor]`.")
        let encoded = try JSONEncoder().encode(row)
        #expect(try JSONDecoder().decode(LedgerRow.self, from: encoded) == row)

        // A row encoded before the field existed.
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "cellNotes")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LedgerRow.self, from: old)
        #expect(decoded.cellNotes == nil)
        #expect(decoded.displayValue(column) == "Divide by zero")
    }

    // MARK: - T-055

    /// Old output: 2 — two clicks along an edge satisfied every commit gate.
    @Test("T-055: a Rectangle Area needs three placed corners to commit")
    func rectangleNeedsThreeCorners() {
        #expect(MeasurementKind.rectangleArea.minimumPointCount == 3)
        // The one-gesture ellipse is still two opposite corners.
        #expect(MeasurementKind.ellipseArea.minimumPointCount == 2)
    }

    // MARK: - T-062

    private static let localizationDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization", isDirectory: true)

    /// A throwaway bundle whose only table is the shipped `<language>.lproj/Plurals.stringsdict`.
    private static func pluralBundle(_ language: String) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Iter3Plurals-\(UUID().uuidString)", isDirectory: true)
        let lproj = root.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: localizationDirectory.appendingPathComponent("\(language).lproj/Plurals.stringsdict"),
            to: lproj.appendingPathComponent("Plurals.stringsdict"))
        let info: [String: Any] = ["CFBundleDevelopmentRegion": language, "CFBundleIdentifier": "iter3.plural.\(language)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        return (try #require(Bundle(url: root)), root)
    }

    /// Old output: every key below was missing from `sv.lproj/Plurals.stringsdict` (en had 19
    /// keys, sv 11), so `LocalizedPlural` returned the "x"/"y" fallback for Swedish and
    /// `PlatformPluralShippingTests.swedishTwinMatches` failed on the key-set parity.
    @Test("T-062: the Swedish catalogue pluralises every measurement phrase the English one does")
    func swedishMeasurementPlurals() throws {
        let (bundle, root) = try Self.pluralBundle("sv")
        defer { try? FileManager.default.removeItem(at: root) }
        // Deliberately wrong fallbacks: each result must come from the Swedish catalogue.
        let expected: [(String, Int, String)] = [
            ("%lld measurements", 1, "1 mätning"),
            ("%lld measurements", 4, "4 mätningar"),
            ("%lld sheets", 1, "1 blad"),
            ("%lld sheets", 40, "40 blad"),
            ("%lld points", 1, "1 punkt"),
            ("%lld points", 3, "3 punkter"),
            ("%lld points placed.", 1, "1 punkt placerad."),
            ("%lld points placed.", 2, "2 punkter placerade."),
            ("%lld measurements keep their values and are flagged as measured against an older scale.", 1,
             "1 mätning behåller sitt värde och markeras som uppmätt mot en äldre skala."),
            ("%lld measurements keep their values and are flagged as measured against an older scale.", 5,
             "5 mätningar behåller sina värden och markeras som uppmätta mot en äldre skala."),
            ("%lld of these pages have a locked scale and will be skipped.", 1,
             "1 av de här sidorna har en låst skala och hoppas över."),
            ("Apply %lld Proposed Scales", 1, "Tillämpa 1 föreslagen skala"),
            ("Apply %lld Proposed Scales", 3, "Tillämpa 3 föreslagna skalor"),
            ("the scale behind %lld measurements. Move them out before deleting it, or their numbers change without anyone deciding to.", 1,
             "skalan bakom 1 mätning. Flytta ut den innan du tar bort området, annars ändras dess värde utan att någon har bestämt det."),
            ("the scale behind %lld measurements. Move them out before deleting it, or their numbers change without anyone deciding to.", 2,
             "skalan bakom 2 mätningar. Flytta ut dem innan du tar bort området, annars ändras deras värden utan att någon har bestämt det."),
        ]
        for (key, count, text) in expected {
            #expect(LocalizedPlural.string(key, count: count, one: "x", other: "y", bundle: bundle) == text, "\(key) × \(count)")
        }
    }
}
