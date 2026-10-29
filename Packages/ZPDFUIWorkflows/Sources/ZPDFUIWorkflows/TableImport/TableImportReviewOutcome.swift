import Foundation

/// What a column's cells are, as the person assigned it: plain text or numbers.
///
/// The default is text, and text is always safe. Number is a claim the review panel checks
/// cell by cell before it is believed — see ``TableImportReviewModel/unparsedRowIndexes(forColumn:)``.
public enum TableImportColumnKind: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Plain text, verbatim. The default.
    case text
    /// A number. Cells that do not read as one are flagged and stay text — never zero.
    case number

    public var id: String { rawValue }

    /// The picker's name for this kind.
    public var displayName: String {
        switch self {
        case .text:
            return NSLocalizedString("Text", comment: "Table import column type choice")
        case .number:
            return NSLocalizedString("Number", comment: "Table import column type choice")
        }
    }
}

/// The person's decision, handed back to the app tier when they accept.
///
/// Together with the proposal the app tier already holds, this is everything the acceptance
/// path needs: the acceptance builds the `.read` records from the proposal **exactly as the
/// engine produced it** (the derivation must record what was read, not what was renamed),
/// and the app tier names the minted ledger columns with ``Column/title`` and kinds them
/// with ``Column/kind`` when it creates the column definitions.
public struct TableImportReviewOutcome: Hashable, Sendable {

    /// One reviewed column: its final name and its assigned kind.
    public struct Column: Hashable, Sendable {
        /// The column's zero-based position in the proposal — the correlation key back to
        /// the engine's column and to the acceptance's minted binding at the same index.
        public let index: Int
        /// The ledger column's name: the person's edit, trimmed, or the proposal's title
        /// where the edit was blank. Never empty.
        public let title: String
        /// The kind the person assigned. Defaults to text.
        public let kind: TableImportColumnKind
        /// For a number column: the rows (zero-based, in table order) whose cell was read
        /// but does not parse as a number. **These cells stay text.** The app tier must not
        /// coerce them — a schedule cell that says "PLAN 2" in a quantity column is a fact
        /// to show, never a zero to invent. Always empty for a text column.
        public let unparsedRowIndexes: [Int]

        /// Creates a reviewed column.
        public init(index: Int, title: String, kind: TableImportColumnKind, unparsedRowIndexes: [Int]) {
            self.index = index
            self.title = title
            self.kind = kind
            self.unparsedRowIndexes = unparsedRowIndexes
        }
    }

    /// The reviewed columns, in proposal order — one per proposal column, always.
    public let columns: [Column]
    /// Which column classifies the row: the acceptance's subject (grouping) key.
    /// The leftmost, matching the acceptance's default.
    public let subjectColumnIndex: Int

    /// Creates an outcome.
    public init(columns: [Column], subjectColumnIndex: Int) {
        self.columns = columns
        self.subjectColumnIndex = subjectColumnIndex
    }
}
