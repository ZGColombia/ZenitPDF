import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

/// Reads a written XLSX back the way a spreadsheet would: out of the zip, out of the XML.
///
/// The tests do not trust the exporter's own idea of what it wrote. They unzip the file with the
/// system `unzip`, parse the sheet XML, and assert on the stored values, the style indices and
/// the number-format codes that Excel will act on.
struct XLSXInspector {

    struct Cell {
        let reference: String
        let row: Int
        let column: Int
        /// `nil` for a numeric cell; `"s"`, `"inlineStr"`, `"b"` etc. otherwise.
        let type: String?
        let styleIndex: Int?
        let value: String
    }

    let sheetXML: String
    let stylesXML: String
    let sharedStrings: [String]
    let cells: [Cell]
    /// Number-format code by cell-format (`xf`) index.
    let numberFormats: [Int: String]

    init(url: URL, sheet: Int = 1) throws {
        sheetXML = try XLSXInspector.entry("xl/worksheets/sheet\(sheet).xml", of: url)
        stylesXML = try XLSXInspector.entry("xl/styles.xml", of: url)
        let sharedXML = try? XLSXInspector.entry("xl/sharedStrings.xml", of: url)
        sharedStrings = XLSXInspector.strings(in: sharedXML ?? "")
        cells = XLSXInspector.parseCells(sheetXML, sharedStrings: sharedStrings)
        numberFormats = XLSXInspector.parseNumberFormats(stylesXML)
    }

    func cell(_ reference: String) -> Cell? { cells.first { $0.reference == reference } }

    func numberFormat(of cell: Cell) -> String? {
        guard let index = cell.styleIndex else { return nil }
        return numberFormats[index]
    }

    /// What Excel shows for a numeric cell under its number format.
    ///
    /// Excel does not display the raw binary double: it displays the 15-significant-digit decimal
    /// form of it, then rounds that to the format's digit count, half away from zero. Reproducing
    /// that here is what makes "the rendered string equals the on-screen string" (QUALITY_BAR
    /// A32) an assertion rather than a hope — and it is why `1.005` shows as `1.01` and not as
    /// the `1.00` a naive `String(format:)` on the double would give.
    func rendered(_ cell: Cell, locale: ExportNumberLocale) throws -> String {
        let stored = try #require(Double(cell.value))
        let normalised = try NumericPolicy.decimal(from: stored)
        guard let code = numberFormat(of: cell) else {
            return locale.string(normalised, decimalPlaces: nil)
        }
        let places = code.split(separator: ".").count > 1
            ? code.split(separator: ".")[1].filter { $0 == "0" }.count
            : 0
        let rounded = PrecisionMode.decimalPlaces(places).apply(to: normalised)
        return locale.string(rounded, decimalPlaces: places)
    }

    /// An Excel date serial, read back as the ISO-8601 string the projection wrote.
    ///
    /// Excel counts days from 1899-12-30 (the 1900 system, with the famous phantom leap day
    /// already baked into the epoch), so the conversion is `(serial - 25569) * 86400` seconds
    /// from the Unix epoch.
    func renderedDate(_ cell: Cell) throws -> String {
        let serial = try #require(Double(cell.value))
        let seconds = (serial - 25_569) * 86_400
        return ExportProjector.iso8601(Date(timeIntervalSince1970: seconds.rounded()))
    }

    // MARK: - Zip

    static func entry(_ name: String, of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path(percentEncoded: false), name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - XML

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let range = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func strings(in sharedXML: String) -> [String] {
        var output: [String] = []
        var cursor = sharedXML.startIndex
        while let open = sharedXML.range(of: "<t", range: cursor..<sharedXML.endIndex),
              let contentStart = sharedXML.range(of: ">", range: open.upperBound..<sharedXML.endIndex),
              let close = sharedXML.range(of: "</t>", range: contentStart.upperBound..<sharedXML.endIndex) {
            output.append(unescape(String(sharedXML[contentStart.upperBound..<close.lowerBound])))
            cursor = close.upperBound
        }
        return output
    }

    private static func parseCells(_ xml: String, sharedStrings: [String]) -> [Cell] {
        var output: [Cell] = []
        var cursor = xml.startIndex
        while let open = xml.range(of: "<c ", range: cursor..<xml.endIndex) {
            guard let tagEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex) else { break }
            let tag = xml[open.upperBound..<tagEnd.lowerBound]
            let selfClosing = tag.hasSuffix("/")
            let reference = attribute("r", in: tag) ?? ""
            let type = attribute("t", in: tag)
            let style = attribute("s", in: tag).flatMap(Int.init)
            var value = ""
            if !selfClosing,
               let close = xml.range(of: "</c>", range: tagEnd.upperBound..<xml.endIndex) {
                let body = xml[tagEnd.upperBound..<close.lowerBound]
                if let vOpen = body.range(of: "<v>"), let vClose = body.range(of: "</v>") {
                    value = unescape(String(body[vOpen.upperBound..<vClose.lowerBound]))
                } else if let tOpen = body.range(of: "<t>"), let tClose = body.range(of: "</t>") {
                    value = unescape(String(body[tOpen.upperBound..<tClose.lowerBound]))
                }
                cursor = close.upperBound
            } else {
                cursor = tagEnd.upperBound
            }
            if type == "s", let index = Int(value), sharedStrings.indices.contains(index) {
                value = sharedStrings[index]
            }
            let (column, row) = reference.reduce(into: (0, 0)) { partial, character in
                if let digit = character.wholeNumberValue, character.isNumber {
                    partial.1 = partial.1 * 10 + digit
                } else if let ascii = character.asciiValue {
                    partial.0 = partial.0 * 26 + Int(ascii - 64)
                }
            }
            output.append(Cell(
                reference: reference,
                row: row - 1,
                column: column - 1,
                type: type,
                styleIndex: style,
                value: value
            ))
        }
        return output
    }

    /// Maps `xf` index to its number-format code, resolving the built-in ids libxlsxwriter uses.
    private static func parseNumberFormats(_ xml: String) -> [Int: String] {
        var custom: [Int: String] = [:]
        var cursor = xml.startIndex
        while let open = xml.range(of: "<numFmt ", range: cursor..<xml.endIndex),
              let close = xml.range(of: "/>", range: open.upperBound..<xml.endIndex) {
            let tag = xml[open.upperBound..<close.lowerBound]
            if let id = attribute("numFmtId", in: tag).flatMap(Int.init),
               let code = attribute("formatCode", in: tag) {
                custom[id] = unescape(code)
            }
            cursor = close.upperBound
        }
        guard let cellXfsOpen = xml.range(of: "<cellXfs"),
              let cellXfsClose = xml.range(of: "</cellXfs>", range: cellXfsOpen.upperBound..<xml.endIndex)
        else { return [:] }
        let body = xml[cellXfsOpen.upperBound..<cellXfsClose.lowerBound]
        var output: [Int: String] = [:]
        var index = 0
        var inner = body.startIndex
        while let open = body.range(of: "<xf ", range: inner..<body.endIndex),
              let end = body.range(of: ">", range: open.upperBound..<body.endIndex) {
            let tag = body[open.upperBound..<end.lowerBound]
            if let id = attribute("numFmtId", in: tag).flatMap(Int.init), let code = custom[id] {
                output[index] = code
            }
            index += 1
            inner = end.upperBound
        }
        return output
    }
}
