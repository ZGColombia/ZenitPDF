import Foundation
import ZPDFContracts

/// What the printed report writes for one cell.
///
/// It is ``ExportCell/text`` — the one string every format writes — for everything except a date,
/// which the report humanises. See ``ExportDate/humanText``: the CSV, the workbook and the
/// interchange JSON are parsed and keep ISO-8601; the report is read off a sheet of paper by a
/// person, and a takeoff summary dated `2026-08-29T14:55:25Z` is a timestamp pretending to be a
/// date (live-test finding LT-19).
///
/// The same instant, spelled for the reader — never a different value. Nothing here rounds,
/// converts or re-renders a number: the projector finished those, once, and this switch cannot
/// reach them.
extension ExportCell {
    var printedText: String {
        if case .date(let value) = self { return value.humanText }
        return text
    }

    /// ``printedText``, with a number's unit after it in a column whose rows do not share one
    /// unit — a markup with display units of its own (NL-MEASURE-10). That column's heading
    /// names no unit, so each number must (T-042). Still the projector's string, never re-rendered.
    func printedText(inMixedUnitColumn mixed: Bool) -> String {
        guard mixed, case .number(let number) = self else { return printedText }
        return number.textNamingUnit
    }
}

extension PDFReportRenderer {

    /// Columns the report prints whatever they hold, because dropping them costs the reader the
    /// row's identity rather than saving them a blank strip.
    ///
    /// Type, Subject and Label say *which* markup a row is; Unit says what the row's number
    /// counts. The number itself needs no rule here — a quantity column with a quantity in it is
    /// filled by definition, and one without is exactly what ``printedColumns(table:options:)``
    /// exists to remove.
    ///
    /// Spelled as `StandardLedgerColumn` cases rather than as string literals, so renaming a
    /// built-in column is a compile error here instead of a silently dropped identity column.
    static let identityColumnKeys: Set<String> = [
        StandardLedgerColumn.icon.rawValue,
        StandardLedgerColumn.subject.rawValue,
        StandardLedgerColumn.label.rawValue,
        StandardLedgerColumn.displayUnit.rawValue
    ]

    /// The indices of the columns the report actually prints, in table order.
    ///
    /// # Live-test finding LT-18
    ///
    /// The ledger's report carries every column the store defines — forty of them — and the
    /// renderer printed all forty, banded six pages wide. A three-row takeoff came out as a
    /// seven-page report in which `Wall Area`, `Volume`, `Rise`, `Run` and the three slope
    /// columns were blank on every row: five pages of headings over nothing. Banding is the right
    /// answer to a table that is genuinely too wide (see ``PDFReportRenderer``); it is the wrong
    /// answer to a table that is mostly empty, because the extra pages carry no information at
    /// all.
    ///
    /// So a column is printed when **any** printed line has something in it — a row, a group
    /// subtotal or a grand total. Totals count deliberately: a column whose rows are all blank
    /// but whose total is a refusal token still has something to say, and hiding a refusal is the
    /// one failure mode worse than printing a blank column (QUALITY_BAR A11, A14).
    ///
    /// This narrows the *report* and nothing else. The CSV, the workbook and the interchange JSON
    /// still carry every column, because those are read by machines that want the whole schema.
    static func printedColumns(table: ExportTable, options: PDFReportOptions) -> [Int] {
        let all = Array(table.columns.indices)
        guard options.dropsEmptyColumns, !all.isEmpty else { return all }

        var filled = [Bool](repeating: false, count: table.columns.count)
        var remaining = filled.count
        func mark(_ cells: [ExportCell]) {
            guard remaining > 0 else { return }
            for (index, cell) in cells.enumerated() where index < filled.count {
                guard !filled[index], !cell.text.isEmpty else { continue }
                filled[index] = true
                remaining -= 1
            }
        }
        // A totals row whose function merely COUNTS puts a digit in every column — the
        // engine's Count/Rows line wrote "1" and "0" across all forty, so nothing was ever
        // empty and the drop never fired: the shipping report still printed 46 columns over
        // 8 pages for a two-row ledger (RT-11, retest of LT-18, 2026-08-31). A count of an
        // empty column says nothing the empty column did not; only VALUE-bearing totals —
        // Sum, Min, Max, Average, WeightedTotal, and any refusal token they carry — can
        // rescue a column whose rows are blank.
        let countingFunctions: Set<String> = ["Count", "Rows", "Distinct"]
        func markTotals(_ rows: [ExportTotalRow]) {
            for row in rows where !countingFunctions.contains(row.function) {
                mark(row.cells)
            }
        }
        func visit(_ group: ExportGroup) {
            for row in group.rows { mark(row.cells) }
            for subgroup in group.subgroups { visit(subgroup) }
            markTotals(group.subtotals)
        }
        for row in table.rows { mark(row.cells) }
        for group in table.groups { visit(group) }
        markTotals(table.grandTotals)

        let kept = all.filter { filled[$0] || identityColumnKeys.contains(table.columns[$0].key) }
        // A table in which nothing at all is filled and nothing is an identity column still needs
        // one column, or the report would be a stack of pages with no table on them.
        return kept.isEmpty ? [all[0]] : kept
    }
}
