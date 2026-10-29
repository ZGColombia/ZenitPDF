import Foundation

/// A ledger workbook that came back from a spreadsheet (NL-PLAT-07), and the review of what it
/// would change.
///
/// The workbook must be one Zenit wrote with row identity: its round-trip sheet names the format,
/// the project, the ledger sheet, the hidden Row ID column and — by exact header text — which
/// columns may be brought back. Everything else is read as untrusted text, and a changed measured
/// quantity is **refused**, never applied: a quantity comes from geometry, not from a cell.
public struct LedgerRoundTripWorkbook: Sendable, Equatable {

    public struct Column: Sendable, Equatable {
        public let header: String
        public let key: String
        public let editable: Bool
    }

    public let projectID: String
    public let exportedAt: String
    public let columns: [Column]
    /// Data rows, by markup id: the cell text under each column key (absent = empty cell).
    public let rows: [(markupID: String, values: [String: String])]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID && lhs.exportedAt == rhs.exportedAt && lhs.columns == rhs.columns
            && lhs.rows.map(\.markupID) == rhs.rows.map(\.markupID)
            && zip(lhs.rows, rhs.rows).allSatisfy { $0.values == $1.values }
    }

    public enum ReadError: Error, Equatable, Sendable, CustomStringConvertible {
        case spreadsheet(SpreadsheetError)
        case notARoundTripWorkbook
        case unsupportedVersion(String)
        case missingSheet(String)
        case missingRowIDColumn
        case duplicateRow(String)

        public var description: String {
            switch self {
            case let .spreadsheet(error): return error.description
            case .notARoundTripWorkbook:
                return "This workbook was not exported by Zenit PDF with row identity, so its rows cannot be matched to markups."
            case let .unsupportedVersion(version): return "This workbook uses round-trip version \(version), which this build does not read."
            case let .missingSheet(name): return "The workbook has no “\(name)” sheet."
            case .missingRowIDColumn: return "The Row ID column was removed from the ledger sheet, so rows cannot be matched to markups."
            case let .duplicateRow(id): return "Row \(id) appears more than once in the workbook."
            }
        }
    }

    public init(data: Data, limits: ZipLimits = .standard) throws {
        let reader: XLSXWorkbookReader
        do { reader = try XLSXWorkbookReader(data: data, limits: limits) } catch let error as SpreadsheetError {
            throw ReadError.spreadsheet(error)
        }
        guard let meta = reader.sheets.first(where: { $0.cell(row: 0, column: 1) == "zenit.ledger.roundtrip" }) else {
            throw ReadError.notARoundTripWorkbook
        }
        var pairs: [String: String] = [:]
        var columnTableStart: Int?
        for row in 0..<meta.rows.count {
            guard let key = meta.cell(row: row, column: 0) else { continue }
            if key == "Column", meta.cell(row: row, column: 1) == "Key" { columnTableStart = row + 1; break }
            pairs[key] = meta.cell(row: row, column: 1) ?? ""
        }
        guard pairs["Version"] == "1" else { throw ReadError.unsupportedVersion(pairs["Version"] ?? "?") }
        var columns: [Column] = []
        if let start = columnTableStart {
            for row in start..<meta.rows.count {
                guard let header = meta.cell(row: row, column: 0), let key = meta.cell(row: row, column: 1) else { continue }
                columns.append(Column(header: header, key: key, editable: meta.cell(row: row, column: 2) == "editable"))
            }
        }
        let sheetName = pairs["Sheet"] ?? "Ledger"
        guard let ledger = reader.sheet(named: sheetName) else { throw ReadError.missingSheet(sheetName) }
        let rowIDHeader = pairs["Row ID column"] ?? "Row ID"
        let headerRow = ledger.rows.first ?? []
        guard let idColumn = headerRow.firstIndex(where: { $0 == rowIDHeader }) else { throw ReadError.missingRowIDColumn }
        // A column is found by its header text, wherever the person moved it.
        var positions: [String: Int] = [:]
        for column in columns {
            if let index = headerRow.firstIndex(where: { $0 == column.header }) { positions[column.key] = index }
        }
        var rows: [(String, [String: String])] = []
        var seen: Set<String> = []
        for index in 1..<max(1, ledger.rows.count) {
            guard let id = ledger.cell(row: index, column: idColumn)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { continue }
            guard seen.insert(id).inserted else { throw ReadError.duplicateRow(id) }
            var values: [String: String] = [:]
            for (key, position) in positions {
                if let text = ledger.cell(row: index, column: position) { values[key] = text }
            }
            rows.append((id, values))
        }
        projectID = pairs["Project"] ?? ""
        exportedAt = pairs["Exported"] ?? ""
        self.columns = columns
        self.rows = rows.map { (markupID: $0.0, values: $0.1) }
    }
}

/// What a ledger row holds now, as the spreadsheet saw it on export.
public enum RoundTripValue: Sendable, Equatable {
    case text(String)
    /// The exact binary value the workbook was written with (`XLSXExporter` writes numbers as
    /// doubles), used only to tell "unchanged" from "changed".
    case number(Double)
    /// An Excel serial date (days since 1899-12-30). The workbook stores dates to the second or
    /// finer, so anything within a second is the same instant.
    case serialDate(Double)
    case empty
}

/// The review a person sees before anything is applied.
public struct LedgerRoundTripReview: Sendable, Equatable {

    public struct Change: Sendable, Equatable {
        public let markupID: String
        public let key: String
        public let header: String
        public let before: String
        /// The file's cell text, verbatim (a number is its literal, e.g. `125.5`).
        public let after: String
    }

    public struct Refusal: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// A measured or computed column: its value comes from geometry, never from a cell.
            case readOnlyColumn
            /// A money or number column whose new text is not a number.
            case notANumber
        }
        public let markupID: String
        public let header: String
        public let before: String
        public let after: String
        public let reason: Reason
    }

    public var changes: [Change]
    public var refusals: [Refusal]
    /// Rows in the file whose markup the ledger no longer has.
    public var onlyInFile: [String]
    /// Ledger rows the file does not have (filtered out on export, or deleted in the sheet).
    public var onlyInLedger: [String]
    /// The workbook names another project.
    public var fromAnotherProject: Bool

    public var isEmpty: Bool { changes.isEmpty && refusals.isEmpty }
}

public enum LedgerRoundTrip {

    /// Compares a returned workbook with the ledger as it is now.
    ///
    /// - Parameters:
    ///   - current: every ledger row by markup id, each column key's value as the export wrote it.
    ///   - numericKeys: keys whose values are numbers (money included): compared numerically,
    ///     and an edit to one must parse as a decimal.
    public static func review(
        _ workbook: LedgerRoundTripWorkbook,
        current: [String: [String: RoundTripValue]],
        numericKeys: Set<String>,
        projectID: String
    ) -> LedgerRoundTripReview {
        var changes: [LedgerRoundTripReview.Change] = []
        var refusals: [LedgerRoundTripReview.Refusal] = []
        var onlyInFile: [String] = []
        let columnByKey = Dictionary(workbook.columns.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for row in workbook.rows {
            guard let now = current[row.markupID] else { onlyInFile.append(row.markupID); continue }
            for column in workbook.columns {
                // A column the ledger does not carry is not comparable: reading it as empty made
                // every filled cell a change or a refusal nobody made (S-011).
                guard let value = now[column.key] else { continue }
                let fileText = row.values[column.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard differs(fileText, from: value) else { continue }
                let before = display(value)
                guard columnByKey[column.key]?.editable == true else {
                    refusals.append(.init(markupID: row.markupID, header: column.header, before: before, after: fileText, reason: .readOnlyColumn))
                    continue
                }
                if numericKeys.contains(column.key), !fileText.isEmpty, decimal(fileText) == nil {
                    refusals.append(.init(markupID: row.markupID, header: column.header, before: before, after: fileText, reason: .notANumber))
                    continue
                }
                changes.append(.init(markupID: row.markupID, key: column.key, header: column.header, before: before, after: fileText))
            }
        }
        let inFile = Set(workbook.rows.map(\.markupID))
        let onlyInLedger = current.keys.filter { !inFile.contains($0) }.sorted()
        return LedgerRoundTripReview(
            changes: changes, refusals: refusals, onlyInFile: onlyInFile, onlyInLedger: onlyInLedger,
            fromAnotherProject: !workbook.projectID.isEmpty && workbook.projectID != projectID
        )
    }

    /// A decimal from a spreadsheet literal (`125.5`, `1E-3`, `-0.25`), exactly, or `nil`.
    ///
    /// Whole-string (R-193): the old character-set filter let `"1.250.00"`, `"12-5"`, `"1e3e3"`
    /// and `"5e"` through to `Decimal(string:)`, a prefix parser, which read them as 1.25, 12,
    /// 1000 and 5 — so a mistyped cell passed the not-a-number check as a different amount.
    public static func decimal(_ text: String) -> Decimal? {
        StrictDecimal.parse(text.trimmingCharacters(in: .whitespaces))
    }

    static func differs(_ fileText: String, from value: RoundTripValue) -> Bool {
        switch value {
        case .empty: return !fileText.isEmpty
        case let .text(text): return fileText != text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .serialDate(days):
            guard let parsed = Double(fileText) else { return true }
            return abs(parsed - days) > 1.0 / 86_400
        case let .number(number):
            guard let parsed = Double(fileText) else { return true }
            // The writer prints a double with 16 significant digits, which may read back one
            // unit in the last place away; anything closer than that is the same number.
            return abs(parsed - number) > max(abs(number), 1) * 1e-15
        }
    }

    static func display(_ value: RoundTripValue) -> String {
        switch value {
        case .empty: return ""
        case let .text(text): return text
        case let .number(number), let .serialDate(number): return String(number)
        }
    }
}
