import Foundation
import Observation
import ZPDFDesignSystem

/// Drives the table-import review panel (feature 31).
///
/// The model owns exactly what the person can change before accepting — column names and
/// column kinds — and the two ways out: ``accept()`` hands a ``TableImportReviewOutcome``
/// to the closure the app tier injected, ``cancel()`` says no. It never touches a session,
/// a document, or a command bus; a review that was never accepted leaves no trace anywhere.
///
/// Two honesty rules are enforced here rather than in the view, so they are testable
/// without a window:
///
/// - **A number column never invents a number.** Assigning a column the number kind checks
///   every read cell against one deterministic parse; the cells that fail are flagged and
///   the outcome names them, so the app tier keeps them as text. Nothing is zeroed, nothing
///   is dropped.
/// - **A refusal is a refusal.** A model built over a ``TableImportReviewRefusal`` has no
///   grid, offers no acceptance, and ``accept()`` on it does nothing at all.
@MainActor @Observable
public final class TableImportReviewModel {

    /// What the panel is showing: a table to review, or the reason there is none.
    public enum Content {
        /// A proposed table, open for review.
        case table(TableImportReviewTable)
        /// The engine's typed refusal, shown as a full-panel state.
        case refusal(TableImportReviewRefusal)
    }

    /// What the panel shows. Fixed at construction: a proposal never becomes a refusal
    /// mid-review, nor the reverse.
    public let content: Content

    /// The editable column names, seeded from the proposal's titles. Bound to the header
    /// fields; ``finalTitle(forColumn:)`` is what an edit becomes at acceptance time.
    public var columnTitles: [String]

    /// The per-column kind assignment. Text is always safe, number is a claim that gets
    /// checked. A column starts as Number only when at least nine in ten of its read cells
    /// already parse as one (IM-153) — the claim is still checked and every cell that fails it
    /// is still flagged; the suggestion only saves the click.
    public var columnKinds: [TableImportColumnKind]

    /// Which column classifies the row: the acceptance's subject (grouping) key. Starts on the
    /// first column that is mostly text — a schedule's mark column — rather than always on the
    /// leftmost, and the person can change it (IM-153).
    public var subjectColumnIndex: Int

    /// For each column, the rows whose cell was read but does not parse as a number, whatever
    /// the column's kind. Computed once: the proposal is fixed at construction, so a cell's
    /// parse can never change.
    ///
    /// The flag used to be recomputed per cell — `isCellFlagged` re-parsed the whole column for
    /// every cell the grid drew — so a 300-row schedule with three number columns ran about
    /// 270 000 parses per body pass, and every keystroke in a column title re-ran the body.
    /// Findings BH-313, IM-034. Now each read cell is parsed exactly once.
    @ObservationIgnored private let unparseableRows: [[Int]]
    /// The same rows as sets, so ``isCellFlagged(row:column:)`` is a lookup.
    @ObservationIgnored private let unparseableRowSets: [Set<Int>]
    /// How many cells were parsed to build the flag cache. Exposed to tests so the linear
    /// parse count is a measured fact, not a claim.
    @ObservationIgnored internal private(set) var cellParseCount = 0
    /// Fixed column widths for the lazy grid, measured once from the proposal.
    @ObservationIgnored private let columnWidths: [Double]

    private let onAccept: (TableImportReviewOutcome) -> Void
    private let onCancel: () -> Void

    /// Builds the review of a proposed table.
    ///
    /// - Parameters:
    ///   - table: the proposal, in the panel's vocabulary.
    ///   - onAccept: receives the person's decision. The app tier turns it, together with
    ///     the proposal it already holds, into `.read` rows through the acceptance path —
    ///     this model never does.
    ///   - onCancel: closes without importing anything.
    public init(
        table: TableImportReviewTable,
        onAccept: @escaping (TableImportReviewOutcome) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.content = .table(table)
        self.columnTitles = table.columns.map(\.title)
        var parses = 0
        var unparseable: [[Int]] = []
        var suggestedKinds: [TableImportColumnKind] = []
        for column in table.columns.indices {
            var failing: [Int] = []
            var readCount = 0
            for (rowIndex, row) in table.rows.enumerated() {
                guard row.cells.indices.contains(column) else { continue }
                let cell = row.cells[column]
                guard !cell.isUnread else { continue }
                readCount += 1
                parses += 1
                if Self.numberValue(of: cell.text) == nil { failing.append(rowIndex) }
            }
            unparseable.append(failing)
            let parsed = readCount - failing.count
            suggestedKinds.append(
                readCount > 0 && Double(parsed) >= Self.numberSuggestionShare * Double(readCount)
                    ? .number : .text
            )
        }
        self.unparseableRows = unparseable
        self.unparseableRowSets = unparseable.map(Set.init)
        self.columnWidths = table.columns.indices.map { column in
            let longest = table.rows.reduce(table.columns[column].title.count) { widest, row in
                row.cells.indices.contains(column) ? max(widest, row.cells[column].text.count) : widest
            }
            return min(320, max(96, Double(longest) * 7.5 + 16))
        }
        self.cellParseCount = parses
        self.columnKinds = suggestedKinds
        self.subjectColumnIndex = suggestedKinds.firstIndex(of: .text) ?? 0
        self.onAccept = onAccept
        self.onCancel = onCancel
    }

    /// Builds the full-panel refusal state. There is nothing to accept; the only way out
    /// is ``cancel()``.
    public init(
        refusal: TableImportReviewRefusal,
        onCancel: @escaping () -> Void
    ) {
        self.content = .refusal(refusal)
        self.columnTitles = []
        self.columnKinds = []
        self.subjectColumnIndex = 0
        self.unparseableRows = []
        self.unparseableRowSets = []
        self.columnWidths = []
        self.onAccept = { _ in }
        self.onCancel = onCancel
    }

    // MARK: - What the grid shows

    /// The table under review, or `nil` in the refusal state.
    public var table: TableImportReviewTable? {
        if case .table(let table) = content { return table }
        return nil
    }

    /// The refusal, or `nil` when there is a table.
    public var refusal: TableImportReviewRefusal? {
        if case .refusal(let refusal) = content { return refusal }
        return nil
    }

    /// The columns of the grid. Empty in the refusal state — a refusal has no grid.
    public var columns: [TableImportReviewTable.Column] { table?.columns ?? [] }

    /// The data rows of the grid. Empty in the refusal state.
    public var rows: [TableImportReviewTable.Row] { table?.rows ?? [] }

    /// The name a column will carry into the ledger: the person's edit, trimmed, or the
    /// proposal's own title when the edit is blank. A column is never nameless.
    public func finalTitle(forColumn index: Int) -> String {
        guard columns.indices.contains(index) else { return "" }
        let edited = columnTitles.indices.contains(index)
            ? columnTitles[index].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return edited.isEmpty ? columns[index].title : edited
    }

    // MARK: - The number claim, checked

    /// One deterministic reading of a schedule cell as a number.
    ///
    /// Accepts an optional sign, digits, and one decimal separator — `.` or `,`, because
    /// drawings from a comma-decimal country say `12,5` — with plain or no-break spaces
    /// tolerated as digit grouping. Anything else is `nil`: not zero, not a guess. A text
    /// containing both `.` and `,` is refused outright rather than disambiguated by luck.
    /// This rule is now stated once, in `ZPDFDecimalParser`, and every Zenit field reads through
    /// it — the numeric field, the calibration entry and the two tool-preset parameter fields
    /// used to have four different answers to `12,5` and `1,234`. Finding CR-184. Exponents stay
    /// refused here: `1e5` in a schedule cell is a misread, not a hundred thousand.
    public static func numberValue(of text: String) -> Decimal? {
        ZPDFDecimalParser.decimal(text)
    }

    /// One cell of the grid, or `nil` when the row is short of that column.
    ///
    /// The engine's proposal is not guaranteed rectangular — a row that lost a cell to a merged
    /// header or a failed read comes through with fewer cells than there are columns — and both
    /// the flag pass and the grid used to subscript straight into `cells[index]`. One ragged row
    /// took the whole review panel down with an index-out-of-range trap. Finding CR-192.
    public func cell(row rowIndex: Int, column columnIndex: Int) -> TableImportReviewTable.Cell? {
        guard rows.indices.contains(rowIndex),
              rows[rowIndex].cells.indices.contains(columnIndex)
        else { return nil }
        return rows[rowIndex].cells[columnIndex]
    }

    /// The rows whose cell in this column was read but does not parse as a number.
    ///
    /// Meaningful only while the column's kind is ``TableImportColumnKind/number`` — for a
    /// text column the answer is empty, because text makes no claim to check. Unread cells
    /// are not flagged either: absent is a different fact than unparsable, and the grid
    /// already marks it.
    public func unparsedRowIndexes(forColumn index: Int) -> [Int] {
        // A missing cell is not a cell that fails its column's number claim; it is a cell the
        // engine never produced, and the grid says so in its own place. The cache skips both
        // missing and unread cells.
        guard columnKinds.indices.contains(index), columnKinds[index] == .number,
              unparseableRows.indices.contains(index)
        else { return [] }
        return unparseableRows[index]
    }

    /// Whether one cell is flagged as failing its column's number claim. A set lookup.
    public func isCellFlagged(row rowIndex: Int, column columnIndex: Int) -> Bool {
        guard columnKinds.indices.contains(columnIndex), columnKinds[columnIndex] == .number,
              unparseableRowSets.indices.contains(columnIndex)
        else { return false }
        return unparseableRowSets[columnIndex].contains(rowIndex)
    }

    /// How many cells across the grid fail their column's number claim right now.
    public var flaggedCellCount: Int {
        columns.indices.reduce(0) { $0 + unparsedRowIndexes(forColumn: $1).count }
    }

    /// How many rows the grid builds eagerly before it switches to lazily built rows (IM-231).
    public static let defaultLazyRowThreshold = 200

    /// The threshold this review uses; tests raise it to measure the eager grid.
    @ObservationIgnored public var lazyRowThreshold = TableImportReviewModel.defaultLazyRowThreshold

    /// Whether the review builds its rows lazily, because the schedule is long.
    public var usesLazyRows: Bool { rows.count > lazyRowThreshold }

    /// The width of the row-leader column in the lazy grid, in points.
    public static let leaderColumnWidth: Double = 24

    /// A fixed width for one column in the lazy grid, from the longest text in it, so rows
    /// built at different times still line up. Measured once per review; 96…320 pt.
    public func columnWidth(forColumn index: Int) -> Double {
        guard columnWidths.indices.contains(index) else { return 96 }
        return columnWidths[index]
    }

    /// The share of a column's read cells that must parse before the column starts as Number.
    public static let numberSuggestionShare = 0.9

    // MARK: - The read-row marker (ADR-0012 rule 5)

    /// The glyph a `.read` row carries in the Quantity Ledger, shown in this grid's row
    /// leader so the person sees **at acceptance time** that these will be read rows —
    /// a different claim than a measurement, and never colour alone.
    public static let readRowGlyph = "⌐"

    /// The standing legend above the grid.
    ///
    /// It used to promise that the ⌐ "stays on these rows in the Quantity Ledger", and the
    /// ledger never drew it — the mark exists only in the export projection — so an imported
    /// row looked measured on screen right after the person was told it would not. Finding
    /// BH-314. The legend now says only what is true; the ledger's half is handed off.
    public static var readRowLegendText: String {
        NSLocalizedString(
            "Every row below will be added as a read row — read from the drawing, not measured. Exports mark these rows with ⌐.",
            comment: "Table import review: what the read-row marker means"
        )
    }

    /// What the glyph means, for VoiceOver and the legend.
    public static var readRowAccessibilityText: String {
        NSLocalizedString(
            "Will be added as a row read from the drawing, not measured",
            comment: "VoiceOver text for the read-row marker in the table import preview"
        )
    }

    // MARK: - The two ways out

    /// Whether there is anything to accept: a table with at least one row. A refusal never
    /// is, and the button bound to this stays disabled.
    public var canAccept: Bool {
        guard let table else { return false }
        return !table.rows.isEmpty
    }

    /// Hands the person's decision to the app tier. Does nothing in the refusal state —
    /// there is no path from a refusal to an import.
    public func accept() {
        guard canAccept, let table else { return }
        let outcome = TableImportReviewOutcome(
            columns: table.columns.indices.map { index in
                TableImportReviewOutcome.Column(
                    index: index,
                    title: finalTitle(forColumn: index),
                    kind: columnKinds[index],
                    unparsedRowIndexes: unparsedRowIndexes(forColumn: index)
                )
            },
            subjectColumnIndex: columns.indices.contains(subjectColumnIndex) ? subjectColumnIndex : 0
        )
        onAccept(outcome)
    }

    /// Closes the review. Nothing has been imported and nothing will be.
    public func cancel() {
        onCancel()
    }
}
