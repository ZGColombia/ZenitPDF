import Foundation

/// One cell of a tab-separated table, and whether it is a number the ledger rendered.
///
/// The flag is what the cell *is*, never what its characters look like (X-013): a displayed
/// negative quantity "-3.2 m²" stays a number, and a Subject typed as `-2+3+cmd|…` is text.
public struct LedgerTabularField: Hashable, Sendable {
    /// The displayed text.
    public let text: String
    /// Whether the text is a rendered number — a quantity, an amount, a free-typed number or a
    /// total — which a spreadsheet must keep reading as a number.
    public let isNumber: Bool

    public init(_ text: String, isNumber: Bool = false) {
        self.text = text
        self.isNumber = isNumber
    }

    /// A text cell: typed or imported words, a title, a heading.
    public static func text(_ text: String) -> LedgerTabularField { LedgerTabularField(text) }

    /// A rendered number.
    public static func number(_ text: String) -> LedgerTabularField { LedgerTabularField(text, isNumber: true) }
}

/// The one writer for the tab-separated text the ledger puts on the pasteboard: Copy, a row
/// dragged out of the table (NL-UX-15) and the Summary Matrix's Copy as Table.
///
/// Every route applies the same two rules, in this order:
///
/// 1. **The spreadsheet formula guard** (``formulaGuarded(_:isNumber:)``), the rule the app's
///    CSV export applies (BH-382, R-102, X-013).
/// 2. **Quoting** — a field holding a tab, a line break or a double quote is quoted and its
///    quotes doubled, so it stays one cell.
///
/// X-030: Copy and drag-out quoted but had no formula guard, so a Subject such as
/// `=HYPERLINK("http://…","Wall")` pasted into a spreadsheet as a live formula; the Summary
/// Matrix joined its titles with a bare tab and neither guarded nor quoted, so a Subject with a
/// line break also shifted every column after it.
public enum LedgerTabularText {

    /// The scalars a spreadsheet reads as the start of a formula when a text cell begins with
    /// one: `=`, `+`, `-`, `@`, a tab and a carriage return.
    public static let formulaLeaders: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// `text` with a leading apostrophe when it is text — not a rendered number — whose first
    /// scalar is one of ``formulaLeaders``. The first *scalar*, because Swift folds "\r\n" into
    /// one `Character` that equals neither "\r" nor "\n" (BH-383).
    public static func formulaGuarded(_ text: String, isNumber: Bool) -> String {
        guard !isNumber, let first = text.unicodeScalars.first, formulaLeaders.contains(first) else { return text }
        return "'" + text
    }

    /// One field, safe inside a tab-separated line and in a spreadsheet: the formula guard,
    /// then quoting.
    ///
    /// The quoting test runs on Unicode scalars, not Characters (U-062): a comment holding a
    /// Windows line break — common in PDF annotation contents — used to go out unquoted and
    /// split the pasted table.
    public static func field(_ text: String, isNumber: Bool = false) -> String {
        let guarded = formulaGuarded(text, isNumber: isNumber)
        let needsQuotes = guarded.unicodeScalars.contains { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }
        guard needsQuotes else { return guarded }
        return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Lines of fields as one tab-separated document, every line ended by a line feed.
    public static func document(_ lines: [[LedgerTabularField]]) -> String {
        lines.map { line in
            line.map { field($0.text, isNumber: $0.isNumber) }.joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    /// Whether a ledger cell is a number the ledger rendered — a free-typed number, a measured
    /// quantity or an amount. Every other cell is text, whatever its characters.
    public static func isNumber(_ value: LedgerCellValue) -> Bool {
        switch value {
        case .number, .quantity, .currency: true
        case .empty, .text, .date, .checkbox, .choice: false
        }
    }
}
