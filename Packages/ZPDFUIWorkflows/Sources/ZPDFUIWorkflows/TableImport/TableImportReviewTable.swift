import Foundation

/// A table read off the drawing, as the review panel sees it (feature 31).
///
/// The table-import engine and its proposal live in the app-core tier, which this package
/// deliberately cannot see — the same seam as every other workflow here: `ToolSetImportReview`
/// is built by a validator the sheet never meets, and search results arrive as value
/// snapshots. The app tier maps the engine's proposal onto this type field for field, shows
/// the panel, and maps the person's decision back. Nothing in this directory can add a row
/// to the document, and nothing in it pretends to: the panel's whole output is a
/// ``TableImportReviewOutcome`` handed to a closure.
///
/// Cells are verbatim. A cell the OCR could not read is **empty and flagged**
/// (``Cell/isUnread``) — the review panel renders the flag as text, never fills the cell in.
public struct TableImportReviewTable: Hashable, Sendable {

    /// How the engine found the column boundaries. The person deciding whether to accept is
    /// entitled to know which claim is being made: a drawn grid is stronger evidence of a
    /// table than text that happens to line up.
    public enum ColumnOrigin: String, Hashable, Sendable, CaseIterable {
        /// Vertical rule lines drawn inside the region — the table's own grid.
        case ruleLines
        /// Clustered leading edges of the recognised text — alignment, not drawn structure.
        case textAlignment

        /// The sentence the panel shows for this origin.
        public var displayText: String {
            switch self {
            case .ruleLines:
                return NSLocalizedString(
                    "Columns follow the table's own rule lines.",
                    comment: "Table import review: how the columns were found"
                )
            case .textAlignment:
                return NSLocalizedString(
                    "Columns follow the alignment of the text. No grid is drawn on the sheet, so check the boundaries.",
                    comment: "Table import review: how the columns were found"
                )
            }
        }
    }

    /// One detected column, as offered for review.
    public struct Column: Hashable, Sendable, Identifiable {
        /// Zero-based position, left to right. Doubles as the stable identity — a proposal's
        /// columns never reorder while the panel is up.
        public let index: Int
        /// The name the column arrives under: the header cell verbatim when the drawing
        /// printed one, a positional English name when it did not.
        public let title: String
        /// Whether ``title`` was printed on the drawing. When `false` the panel says so,
        /// and nothing downstream pretends the drawing named this column.
        public let headerWasPrinted: Bool

        /// Creates a column.
        public init(index: Int, title: String, headerWasPrinted: Bool) {
            self.index = index
            self.title = title
            self.headerWasPrinted = headerWasPrinted
        }

        public var id: Int { index }
    }

    /// One cell: the recognised text, verbatim, or nothing.
    public struct Cell: Hashable, Sendable {
        /// The recognised text, verbatim. Empty when nothing was read inside the cell.
        public let text: String

        /// Creates a cell.
        public init(text: String) {
            self.text = text
        }

        /// `true` when the OCR read nothing here. Rendered as a text marker, never filled in.
        public var isUnread: Bool { text.isEmpty }
    }

    /// One data row: its cells in column order.
    public struct Row: Hashable, Sendable {
        /// One cell per column, in column order. Count equals the table's column count.
        public let cells: [Cell]
        /// Every recognised line of the row joined left to right, verbatim — the text the
        /// accepted row's audit trail will carry.
        public let sourceText: String

        /// Creates a row.
        public init(cells: [Cell], sourceText: String) {
            self.cells = cells
            self.sourceText = sourceText
        }

        /// How many of the row's cells the OCR could not read.
        public var unreadCellCount: Int { cells.count(where: \.isUnread) }
    }

    /// The detected columns, left to right. The engine never proposes fewer than two.
    public let columns: [Column]
    /// The data rows, top to bottom. The header row, when one was detected, is already
    /// folded into ``columns`` — it never appears as data.
    public let rows: [Row]
    /// How the column boundaries were found.
    public let columnOrigin: ColumnOrigin
    /// Recognised text inside the region that carried no page position and so sits in no
    /// cell. Listed under the grid so the person knows what was read but not filed.
    public let unplacedTexts: [String]

    /// Creates a review table. The app tier maps the engine's proposal here field for field.
    public init(
        columns: [Column],
        rows: [Row],
        columnOrigin: ColumnOrigin,
        unplacedTexts: [String]
    ) {
        self.columns = columns
        self.rows = rows
        self.columnOrigin = columnOrigin
        self.unplacedTexts = unplacedTexts
    }

    /// How many cells across all rows the OCR could not read.
    public var unreadCellCount: Int {
        rows.reduce(0) { $0 + $1.unreadCellCount }
    }
}

/// Why the engine refused to propose a table, in the panel's vocabulary.
///
/// A refusal is a full-panel state, never an empty grid pretending success. The four cases
/// mirror the engine's typed refusal one for one; the app tier maps them across the seam.
public enum TableImportReviewRefusal: Hashable, Sendable {

    /// No recognised text sits inside the selected region.
    case emptyRegion
    /// Text was recognised but arrived without page positions, so no grid can be built.
    case textWithoutPositions(lineCount: Int)
    /// Neither rule lines nor text alignment yields at least two columns.
    case noColumnStructure(interiorRuleCount: Int, alignmentClusterCount: Int)
    /// Columns were found but no row of text sits under them.
    case noRows

    /// The refusal's headline, in plain words.
    public var displayTitle: String {
        switch self {
        case .emptyRegion:
            return NSLocalizedString(
                "Nothing to read here",
                comment: "Table import refusal headline: the region holds no recognised text"
            )
        case .textWithoutPositions:
            return NSLocalizedString(
                "The text has no positions",
                comment: "Table import refusal headline: recognised text carries no page positions"
            )
        case .noColumnStructure:
            return NSLocalizedString(
                "No columns found",
                comment: "Table import refusal headline: no column structure in the region"
            )
        case .noRows:
            return NSLocalizedString(
                "No rows under the columns",
                comment: "Table import refusal headline: column structure but no data rows"
            )
        }
    }

    /// What happened and what the person can do about it, in plain words.
    public var displayMessage: String {
        switch self {
        case .emptyRegion:
            return NSLocalizedString(
                "No recognised text sits inside the selected region. Run text recognition on this page, or select the printed schedule itself.",
                comment: "Table import refusal detail: empty region"
            )
        case .textWithoutPositions(let lineCount):
            return WorkflowPlurals.linesWithoutPositions(lineCount)
        case .noColumnStructure(let interiorRuleCount, let alignmentClusterCount):
            return String(
                format: NSLocalizedString(
                    "A table needs at least two columns. This region has %1$@ and %2$@ — not enough of either. Try a selection that covers the whole schedule.",
                    comment: "Table import refusal detail: no column structure; '3 interior rule lines', '2 text alignment clusters'"
                ),
                WorkflowPlurals.interiorRuleLines(interiorRuleCount),
                WorkflowPlurals.alignmentClusters(alignmentClusterCount)
            )
        case .noRows:
            return NSLocalizedString(
                "Column structure was found, but no row of text sits under it — a header with nothing beneath it, for example. Nothing would be imported.",
                comment: "Table import refusal detail: no rows"
            )
        }
    }
}
