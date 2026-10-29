import Foundation
import ZPDFExport
import ZPDFUILedger
import ZPDFUIPresentation

/// Writes the Quantity Ledger to CSV exactly as it is on screen.
///
/// "As it is on screen" is the whole contract: the visible columns, in their current order, with
/// the values already formatted for the user's units and locale. An export that quietly reordered
/// or reformatted would put a different number in the tender from the one the estimator checked,
/// which is the failure mode `QUALITY_BAR` C3 exists to prevent.
///
/// RFC 4180 quoting, and a UTF-8 BOM so a Swedish `å` survives a double-click into Excel.
@MainActor
public enum LedgerCSVExport {

    /// The first field of the banner a filtered export carries. Machine-stable, so a
    /// downstream importer can recognise a partial file without parsing prose.
    public static let filteredBannerKey = "FILTERED"

    /// The first field of the banner a selected-rows export carries (NL-QTY-14).
    public static let selectedBannerKey = "SELECTED"

    /// Renders the presenter's rows to CSV text.
    ///
    /// A **filtered** ledger is exported with a leading banner naming the filter and the
    /// row count it produced. Without it the file is a subset of the takeoff that looks
    /// exactly like the whole takeoff, and the person it is sent to has no way to know —
    /// which is the failure QUALITY_BAR A35 is about and the reason the projection has
    /// carried `filterDescription` and `totalRowCountBeforeFilter` all along. An
    /// unfiltered export is byte-identical to what it has always been: header row first,
    /// one record per row, nothing else.
    ///
    /// - Parameter traces: each row's measurement trace, by markup (feature 16). When given,
    ///   the six trace columns follow the visible columns, exactly as the projected formats
    ///   append them; a row the map does not know reads the unknown trace, never a blank scale.
    ///   Empty — the default — writes the file byte for byte as before.
    ///
    /// - Parameter onlyMarkups: when given, only these rows are written, under a banner that
    ///   says so — "Export selected rows" (NL-QTY-14).
    public static func render(
        presenter: any LedgerPresenting,
        delimiter: Character = ",",
        traces: [UUID: ExportRowTrace] = [:],
        onlyMarkups: Set<UUID>? = nil
    ) -> String {
        let columns = presenter.visibleColumns
        let separator = String(delimiter)
        let withTrace = !traces.isEmpty
        var lines: [String] = []
        if let onlyMarkups {
            lines.append([
                field(selectedBannerKey, delimiter: delimiter),
                field(String(
                    format: NSLocalizedString(
                        "%1$d selected of %2$d rows",
                        comment: "CSV banner for an export of the selected rows: exported rows, rows in the whole takeoff"
                    ),
                    (0..<presenter.rowCount).filter { presenter.row(at: $0).map { onlyMarkups.contains($0.markupID) } ?? false }.count,
                    presenter.unfilteredRowCount
                ), delimiter: delimiter)
            ].joined(separator: separator))
            lines.append("")
        }
        lines.append(contentsOf: filterBanner(presenter: presenter, delimiter: delimiter))
        var header = columns.map { field($0.title, delimiter: delimiter) }
        if withTrace { header += ExportRowTrace.columnTitles.map { field($0, delimiter: delimiter) } }
        lines.append(header.joined(separator: separator))
        for index in 0..<presenter.rowCount {
            guard let row = presenter.row(at: index) else { continue }
            if let onlyMarkups, !onlyMarkups.contains(row.markupID) { continue }
            var cells = columns.map { column in
                field(cellText(row, column: column.id), delimiter: delimiter, isNumber: isNumber(row.value(column.id)))
            }
            if withTrace {
                cells += (traces[row.markupID] ?? .unknown).fieldTexts.map { field($0, delimiter: delimiter) }
            }
            lines.append(cells.joined(separator: separator))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The text one cell is written with: what the row displays in that column.
    ///
    /// The `Unit` column (`displayUnit`) holds no stored value — the store has nothing to write
    /// there — so it was written blank, and a length row read `Plan Length 12,30` with no unit
    /// beside it (L-25). It carries the row's unit as the ledger's Unit column shows it: the
    /// primary quantity's symbol (m, m², m³, pcs, or the project's unit), and blank only for a
    /// row with no quantity. A display column (`Value`, the table's `Unit`) is rendered the way
    /// the table renders it, should a presenter ever list one.
    static func cellText(_ row: LedgerRow, column: LedgerColumnID) -> String {
        if LedgerDefaultColumns.isDisplayColumn(column) {
            return LedgerDefaultColumns.displayText(for: row, columnID: column)
        }
        let stored = row.displayValue(column)
        if stored.isEmpty, column == .displayUnit {
            return LedgerDefaultColumns.unitText(for: row)
        }
        return stored
    }

    /// The delimiter a spreadsheet in this locale splits a double-clicked CSV on.
    ///
    /// Where the decimal separator is a comma — Swedish among them — Excel splits on `;`,
    /// and a comma-delimited file landed entirely in column A (BH-915). The displayed values
    /// there already carry comma decimals, so `;` is also the delimiter that needs no quoting.
    public static func delimiter(for locale: Locale) -> Character {
        locale.decimalSeparator == "," ? ";" : ","
    }

    /// The banner lines, or nothing at all when the ledger is unfiltered.
    static func filterBanner(presenter: any LedgerPresenting, delimiter: Character = ",") -> [String] {
        guard presenter.isFiltered else { return [] }
        let rowsText = String(
            format: NSLocalizedString(
                "%1$d of %2$d rows",
                comment: "Filtered CSV banner: exported rows, rows in the whole takeoff"
            ),
            presenter.rowCount,
            presenter.unfilteredRowCount
        )
        let description = LedgerExportWriter.describe(
            filter: presenter.filter,
            columns: presenter.columns
        )
        return [
            [
                field(filteredBannerKey, delimiter: delimiter),
                field(rowsText, delimiter: delimiter),
                field(description, delimiter: delimiter)
            ].joined(separator: String(delimiter)),
            ""
        ]
    }

    /// Writes the CSV to a file.
    public static func write(presenter: any LedgerPresenting, to url: URL) throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(render(presenter: presenter, delimiter: delimiter(for: .current)).utf8))
        try data.write(to: url, options: .atomic)
    }

    /// Whether a cell is a number the ledger rendered — a free-typed number, a measured
    /// quantity or an amount — whose displayed text ("-3,2 m") is written as it is. Every other
    /// cell is text, whatever its characters (X-013). The ledger's Copy asks the same rule (X-030).
    nonisolated static func isNumber(_ value: LedgerCellValue) -> Bool {
        LedgerTabularText.isNumber(value)
    }

    /// One CSV field: the spreadsheet formula guard, then RFC 4180 quoting.
    ///
    /// - Text — every field but a rendered number — that starts with `=`, `+`, `-`, `@`, a tab
    ///   or a carriage return gets a leading apostrophe: the rule `ZPDFExport.CSVExporter` and
    ///   the export profiles apply (R-102). A subject typed as `=HYPERLINK(…)`, or arriving in a
    ///   shared tool set, was executed when the tender CSV was opened (BH-382). The guard used
    ///   to let `-` through when a digit followed, to spare displayed negatives, and so wrote
    ///   `-2+3+cmd|' /C calc'!A0` unguarded and unquoted (X-013); a number is told by what the
    ///   cell is (`isNumber`), never by the characters after the minus.
    /// - Line breaks are found on unicode scalars: Swift folds CRLF into one `Character` that
    ///   equals neither `\n` nor `\r`, and a pasted Windows line break was written unquoted and
    ///   split the record (BH-383). The guard reads the first scalar for the same reason.
    nonisolated static func field(_ value: String, delimiter: Character = ",", isNumber: Bool = false) -> String {
        // One formula guard for this file and for the ledger's Copy, drag-out and Summary
        // Matrix (X-030).
        let text = LedgerTabularText.formulaGuarded(value, isNumber: isNumber)
        let breaksLine = text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" }
        let mustQuote = breaksLine
            || text.contains(delimiter)
            || text.contains("\"")
            || text.first == " " || text.last == " "
        guard mustQuote else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
