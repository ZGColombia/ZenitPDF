import Foundation
import ZPDFXlsxWriter

/// A subject-by-subject summary workbook (NL-QTY-15 phase 2: the batch summary over closed
/// projects): a "Combined" sheet, one sheet per project, and — when any package could not be
/// read — a "Not Included" sheet naming each one and why.
///
/// Every total is a real number in its display unit, carrying the number format that shows the
/// digits the screen shows; the unit is its own column, so two units of one subject stay two
/// rows, as they are in the summary (QUALITY_BAR A36). The values arrive already converted — the
/// caller's formatter did that once — and nothing here adds anything up.
public struct XLSXSubjectSummaryWorkbook: Hashable, Sendable {

    public struct Line: Hashable, Sendable {
        public var subject: String
        public var unit: String
        public var rowCount: Int
        /// The total in ``unit``, unrounded.
        public var value: Decimal
        /// Digits the screen shows; drives the cell's number format.
        public var decimalPlaces: Int

        public init(subject: String, unit: String, rowCount: Int, value: Decimal, decimalPlaces: Int) {
            self.subject = subject
            self.unit = unit
            self.rowCount = rowCount
            self.value = value
            self.decimalPlaces = max(0, min(9, decimalPlaces))
        }
    }

    public struct Sheet: Hashable, Sendable {
        public var name: String
        public var lines: [Line]
        public init(name: String, lines: [Line]) {
            self.name = name
            self.lines = lines
        }
    }

    public var title: String
    public var combined: [Line]
    public var projects: [Sheet]
    /// (package name, reason).
    public var notIncluded: [[String]]

    public init(title: String, combined: [Line], projects: [Sheet], notIncluded: [[String]]) {
        self.title = title
        self.combined = combined
        self.projects = projects
        self.notIncluded = notIncluded
    }

    public static let combinedSheetName = "Combined"
    public static let notIncludedSheetName = "Not Included"
    public static let header = ["Subject", "Unit", "Rows", "Total"]

    public func export(to url: URL) throws {
        do {
            try XlsxWriter.write(
                to: url, options: XlsxWorkbookOptions(constantMemory: false),
                properties: XlsxDocumentProperties(title: title, author: "Zenit PDF", category: "Quantity takeoff")
            ) { workbook in
                var names = XLSXExporter.SheetNames()
                let bold = try workbook.format(XlsxFormatSpec(bold: true, bottomBorder: .thin))
                let text = try workbook.format(XlsxFormatSpec())
                let guarded = try workbook.format(XlsxFormatSpec(quotePrefix: true))
                var numberFormats: [Int: XlsxFormatHandle] = [:]
                func number(_ places: Int) throws -> XlsxFormatHandle {
                    if let cached = numberFormats[places] { return cached }
                    let made = try workbook.format(XlsxFormatSpec(
                        numberFormat: ExportProjector.numberFormatCode(decimalPlaces: places, grouped: false)
                    ))
                    numberFormats[places] = made
                    return made
                }
                func string(_ sheet: XlsxWorksheet, _ row: Int, _ column: Int, _ value: String) throws {
                    try sheet.writeString(
                        row: row, column: column, XLSXExporter.cellText(value),
                        format: XLSXTextTable.needsFormulaGuard(value) ? guarded : text
                    )
                }
                func write(_ name: String, _ lines: [Line]) throws {
                    let sheet = try workbook.addWorksheet(name: names.claim(name))
                    try sheet.setColumnWidth(first: 0, last: 0, width: 32)
                    try sheet.setColumnWidth(first: 1, last: 3, width: 14)
                    for (index, title) in Self.header.enumerated() {
                        try sheet.writeString(row: 0, column: index, title, format: bold)
                    }
                    for (offset, line) in lines.enumerated() {
                        let row = offset + 1
                        try string(sheet, row, 0, line.subject)
                        try string(sheet, row, 1, line.unit)
                        try sheet.writeNumber(row: row, column: 2, Double(line.rowCount))
                        try sheet.writeNumber(
                            row: row, column: 3, NSDecimalNumber(decimal: line.value).doubleValue,
                            format: try number(line.decimalPlaces)
                        )
                    }
                }
                try write(Self.combinedSheetName, combined)
                for project in projects { try write(project.name, project.lines) }
                if !notIncluded.isEmpty {
                    let sheet = try workbook.addWorksheet(name: names.claim(Self.notIncludedSheetName))
                    try sheet.setColumnWidth(first: 0, last: 0, width: 32)
                    try sheet.setColumnWidth(first: 1, last: 1, width: 80)
                    try sheet.writeString(row: 0, column: 0, "Project", format: bold)
                    try sheet.writeString(row: 0, column: 1, "Reason", format: bold)
                    for (offset, pair) in notIncluded.enumerated() {
                        for (column, value) in pair.prefix(2).enumerated() { try string(sheet, offset + 1, column, value) }
                    }
                }
            }
        } catch let error as XlsxError {
            throw ExportError.xlsx(error)
        }
    }
}
