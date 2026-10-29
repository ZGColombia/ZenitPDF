import Foundation
import ImageIO
import ZPDFXlsxWriter

/// A table of finished strings as a workbook, with an optional picture per row (NL-COLLAB-16:
/// the review report — page, kind, author, status, thread — beside each markup's snapshot).
///
/// Not the ledger's exporter: nothing here is a quantity, so every cell is text. The one rule it
/// shares with the ledger sheet is the formula guard: a cell that begins with `=`, `+`, `-` or
/// `@` is written with a quote prefix, so a note typed as `=HYPERLINK(…)` is text in every
/// spreadsheet and never a formula.
public struct XLSXTextTable: Hashable, Sendable {
    public var sheetName: String
    public var header: [String]
    public var rows: [[String]]
    /// One PNG or JPEG per row, or `nil`; placed in a last column titled ``imageColumnTitle``.
    public var images: [Data?]
    public var imageColumnTitle: String

    public init(sheetName: String, header: [String], rows: [[String]], images: [Data?] = [], imageColumnTitle: String = "Snapshot") {
        self.sheetName = sheetName
        self.header = header
        self.rows = rows
        self.images = images
        self.imageColumnTitle = imageColumnTitle
    }

    /// Whether a text needs the quote prefix that keeps it from being read as a formula.
    public static func needsFormulaGuard(_ text: String) -> Bool {
        text.first.map { "=+-@".contains($0) } ?? false
    }

    var carriesImages: Bool { images.contains { $0 != nil } }
}

public enum XLSXTextTableExporter {

    /// The tallest a row's picture is drawn, in pixels (≈ points at 96 dpi); wider pictures are
    /// scaled to fit ``maximumImageWidth``.
    public static let maximumImageHeight: Double = 120
    public static let maximumImageWidth: Double = 240

    /// The scale a picture of `pixels` is placed at: it fits the box, and is never enlarged.
    public static func imageScale(width: Double, height: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return min(1, maximumImageWidth / width, maximumImageHeight / height)
    }

    public static func export(_ table: XLSXTextTable, to url: URL) throws {
        do {
            try XlsxWriter.write(
                to: url, options: XlsxWorkbookOptions(constantMemory: false),
                properties: XlsxDocumentProperties(title: table.sheetName, author: "Zenit PDF")
            ) { workbook in
                let sheet = try workbook.addWorksheet(name: XLSXExporter.SheetNames.sanitised(table.sheetName))
                let bold = try workbook.format(XlsxFormatSpec(bold: true, bottomBorder: .thin))
                let wrap = try workbook.format(XlsxFormatSpec(alignment: .left, textWrap: true))
                let guarded = try workbook.format(XlsxFormatSpec(alignment: .left, textWrap: true, quotePrefix: true))
                let imageColumn = table.carriesImages ? table.header.count : nil
                for (index, title) in table.header.enumerated() {
                    let widest = ([title] + table.rows.map { index < $0.count ? $0[index] : "" })
                        .map { $0.split(separator: "\n").map(\.count).max() ?? 0 }.max() ?? 8
                    try sheet.setColumnWidth(first: index, last: index, width: min(60, max(10, Double(widest) + 2)))
                    try sheet.writeString(row: 0, column: index, XLSXExporter.cellText(title), format: bold)
                }
                if let imageColumn {
                    try sheet.setColumnWidth(first: imageColumn, last: imageColumn, width: maximumImageWidth / 7)
                    try sheet.writeString(row: 0, column: imageColumn, XLSXExporter.cellText(table.imageColumnTitle), format: bold)
                }
                try sheet.freezePanes(row: 1, column: 0)
                for (offset, cells) in table.rows.enumerated() {
                    let row = offset + 1
                    for (column, text) in cells.enumerated() where !text.isEmpty {
                        try sheet.writeString(
                            row: row, column: column, XLSXExporter.cellText(text),
                            format: XLSXTextTable.needsFormulaGuard(text) ? guarded : wrap
                        )
                    }
                    if let imageColumn, offset < table.images.count, let data = table.images[offset],
                       let size = pixelSize(data) {
                        let scale = imageScale(width: size.width, height: size.height)
                        // Row height in points; a pixel is 0.75 pt at the sheet's 96 dpi.
                        try sheet.setRowHeight(row, height: max(15, size.height * scale * 0.75 + 4))
                        try sheet.insertImage(row: row, column: imageColumn, data: data, scale: scale,
                                              description: cells.first)
                    }
                }
            }
        } catch let error as XlsxError {
            throw ExportError.xlsx(error)
        }
    }

    /// The pixel size of PNG or JPEG bytes, or `nil` for anything else.
    static func pixelSize(_ data: Data) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double ?? (properties[kCGImagePropertyPixelWidth] as? Int).map(Double.init),
              let height = properties[kCGImagePropertyPixelHeight] as? Double ?? (properties[kCGImagePropertyPixelHeight] as? Int).map(Double.init)
        else { return nil }
        return (width, height)
    }
}
