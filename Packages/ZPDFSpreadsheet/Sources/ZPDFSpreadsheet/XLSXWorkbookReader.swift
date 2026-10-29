import Foundation

/// One worksheet as a grid of cell texts, in sheet order. `nil` is an empty cell.
///
/// Values stay **text**: a number is the literal the file stores (`12.5`, `1E-3`), never a
/// binary `Double`, so an exact decimal typed by a person survives until a caller parses it with
/// the precision it needs.
public struct SpreadsheetSheet: Sendable, Equatable {
    public let name: String
    public private(set) var rows: [[String?]]

    public init(name: String, rows: [[String?]]) {
        self.name = name
        self.rows = rows
    }

    public func cell(row: Int, column: Int) -> String? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column]
    }
}

public enum SpreadsheetError: Error, Equatable, Sendable, CustomStringConvertible {
    case zip(ZipError)
    case notAWorkbook(String)
    case malformedXML(part: String)
    case tooManyCells(limit: Int)
    case tooManySheets(count: Int, limit: Int)
    case tooManySharedStrings(limit: Int)
    /// One archive entry named twice — two sheets sharing a target, or a sheet pointing at the
    /// workbook's own parts (V-089).
    case partReferencedTwice(part: String)

    public var description: String {
        switch self {
        case let .zip(error): return "The workbook could not be read: \(error.description)."
        case let .notAWorkbook(detail): return "The file is not an Excel workbook: \(detail)."
        case let .malformedXML(part): return "The workbook is damaged (\(part) is not well-formed)."
        case let .tooManyCells(limit): return "The workbook holds more than \(limit) cells."
        case let .tooManySheets(count, limit): return "The workbook has \(count) sheets; the limit is \(limit)."
        case let .tooManySharedStrings(limit): return "The workbook holds more than \(limit) shared strings."
        case let .partReferencedTwice(part): return "The workbook is damaged (\(part) is referenced more than once)."
        }
    }
}

/// Reads the worksheets of an `.xlsx` (SpreadsheetML) workbook.
public struct XLSXWorkbookReader: Sendable {

    /// The workbook-wide budget: every cell element read, plus every empty slot and empty row
    /// the dense grid pads in front of a value (U-099).
    public static let maximumCells = 5_000_000

    /// Worksheets in one workbook (V-089). A ledger round trip writes two; a person's workbook
    /// rarely passes a few dozen.
    public static let maximumSheets = 256

    /// Entries in the shared-string table (V-089): one per `<si>`, so never more than a
    /// workbook can have cells that point at them.
    public static let maximumSharedStrings = maximumCells

    public let sheets: [SpreadsheetSheet]

    public init(data: Data, limits: ZipLimits = .standard) throws {
        let zip: ZipArchiveReader
        do { zip = try ZipArchiveReader(data: data, limits: limits) } catch let error as ZipError {
            throw SpreadsheetError.zip(error)
        }
        // V-089. Every entry is inflated at most once. The limits in `ZipLimits` are checked
        // once, over the sizes the central directory declares, so they bound the whole read
        // only while no entry is inflated twice. Two `<sheet>` elements naming one 256 MiB
        // part used to cost two full inflates and two parses, and N of them N, all charged
        // once.
        var inflated: Set<String> = []
        func part(_ name: String) throws -> Data {
            guard inflated.insert(name).inserted else { throw SpreadsheetError.partReferencedTwice(part: name) }
            do { return try zip.contents(of: name) } catch let error as ZipError {
                if case .missingEntry = error { throw SpreadsheetError.notAWorkbook("no \(name)") }
                throw SpreadsheetError.zip(error)
            }
        }
        let workbook = try part("xl/workbook.xml")
        let relationships = try part("xl/_rels/workbook.xml.rels")
        let sharedStrings: [String] = zip.entry(named: "xl/sharedStrings.xml") != nil
            ? try SharedStringsParser.parse(try part("xl/sharedStrings.xml"))
            : []
        let targets = try RelationshipsParser.parse(relationships)
        let declared = try WorkbookParser.parse(workbook)
        guard declared.count <= Self.maximumSheets else {
            throw SpreadsheetError.tooManySheets(count: declared.count, limit: Self.maximumSheets)
        }
        var sheets: [SpreadsheetSheet] = []
        var cellBudget = Self.maximumCells
        for (name, relationshipID) in declared {
            guard let target = targets[relationshipID] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            let rows = try SheetParser.parse(try part(path), sharedStrings: sharedStrings, part: path, budget: &cellBudget)
            sheets.append(SpreadsheetSheet(name: name, rows: rows))
        }
        self.sheets = sheets
    }

    public func sheet(named name: String) -> SpreadsheetSheet? { sheets.first { $0.name == name } }

    /// Zero-based column index of an A1 reference's letters ("C7" → 2).
    public static func columnIndex(of reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            index = index * 26 + Int((scalar.value & ~0x20) - 64)
            sawLetter = true
            guard index <= 16_384 else { return nil }
        }
        return sawLetter ? index - 1 : nil
    }
}

// MARK: - Parsers

private final class ParserDelegate: NSObject, XMLParserDelegate {
    weak var parser: XMLParser?
    /// Set by ``stop()``: the parse ended because a budget ran out, not because the XML is bad.
    private(set) var stopped = false
    var start: (String, [String: String]) -> Void = { _, _ in }
    var end: (String) -> Void = { _ in }
    var characters: (String) -> Void = { _ in }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        start(localName(elementName), attributes)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        end(localName(elementName))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { characters(string) }
    /// Ends the parse now (V-089). A part over its budget used to be read to its last byte
    /// after the budget ran out, only to be refused at the end.
    func stop() {
        guard !stopped else { return }
        stopped = true
        parser?.abortParsing()
    }
    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private func run(_ data: Data, part: String, _ configure: (ParserDelegate) -> Void) throws {
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false
    let delegate = ParserDelegate()
    delegate.parser = parser
    configure(delegate)
    parser.delegate = delegate
    guard parser.parse() || delegate.stopped else { throw SpreadsheetError.malformedXML(part: part) }
}

enum WorkbookParser {
    /// Sheet names and their relationship ids, in workbook order.
    static func parse(_ data: Data) throws -> [(String, String)] {
        var sheets: [(String, String)] = []
        try run(data, part: "xl/workbook.xml") { delegate in
            delegate.start = { name, attributes in
                guard name == "sheet", let sheetName = attributes["name"] else { return }
                if let id = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value {
                    sheets.append((sheetName, id))
                }
            }
        }
        return sheets
    }
}

enum RelationshipsParser {
    static func parse(_ data: Data) throws -> [String: String] {
        var targets: [String: String] = [:]
        try run(data, part: "xl/_rels/workbook.xml.rels") { delegate in
            delegate.start = { name, attributes in
                guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
                targets[id] = target
            }
        }
        return targets
    }
}

enum SharedStringsParser {
    /// Every `<si>`, rich-text runs concatenated, phonetic runs (`<rPh>`) left out.
    static func parse(_ data: Data) throws -> [String] {
        var strings: [String] = []
        var current = ""
        var inItem = false, inText = false, inPhonetic = false
        var overBudget = false
        try run(data, part: "xl/sharedStrings.xml") { delegate in
            delegate.start = { [unowned delegate] name, _ in
                switch name {
                case "si":
                    // V-089: counted on the way in, so about 53 million empty `<si/>` in one
                    // 256 MiB part can no longer grow an array of some 860 MB.
                    guard strings.count < XLSXWorkbookReader.maximumSharedStrings else {
                        overBudget = true
                        delegate.stop()
                        return
                    }
                    inItem = true; current = ""
                case "rPh": inPhonetic = true
                case "t": inText = inItem && !inPhonetic
                default: break
                }
            }
            delegate.end = { name in
                switch name {
                case "si":
                    guard inItem else { return }
                    strings.append(current); inItem = false
                case "rPh": inPhonetic = false
                case "t": inText = false
                default: break
                }
            }
            delegate.characters = { text in if inText { current += text } }
        }
        if overBudget { throw SpreadsheetError.tooManySharedStrings(limit: XLSXWorkbookReader.maximumSharedStrings) }
        return strings
    }
}

enum SheetParser {
    static func parse(_ data: Data, sharedStrings: [String], part: String, budget: inout Int) throws -> [[String?]] {
        var rows: [[String?]] = []
        var rowIndex = -1
        var cellColumn = 0
        var cellType = ""
        var value = ""
        var inValue = false, inInline = false
        var overBudget = false
        var remaining = budget
        try run(data, part: part) { delegate in
            delegate.start = { name, attributes in
                switch name {
                case "row":
                    if let r = attributes["r"], let number = Int(r) { rowIndex = number - 1 } else { rowIndex += 1 }
                    cellColumn = 0
                case "c":
                    if let reference = attributes["r"], let column = XLSXWorkbookReader.columnIndex(of: reference) {
                        cellColumn = column
                    }
                    cellType = attributes["t"] ?? "n"
                    value = ""
                case "v": inValue = true
                case "t": inInline = cellType == "inlineStr"
                default: break
                }
            }
            delegate.end = { [unowned delegate] name in
                switch name {
                case "v": inValue = false
                case "t": inInline = false
                case "c":
                    defer { cellColumn += 1 }
                    guard rowIndex >= 0, rowIndex < 1_048_576 else { return }
                    remaining -= 1
                    if remaining < 0 { overBudget = true; delegate.stop(); return }
                    let text: String?
                    switch cellType {
                    case "s": text = Int(value).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil }
                    case "b": text = value == "1" ? "TRUE" : (value.isEmpty ? nil : "FALSE")
                    default: text = value.isEmpty ? nil : value
                    }
                    guard let text else { return }
                    // The grid is dense, so every empty slot a cell forces into existence costs
                    // the budget too (U-099). One `<c r="XFD7">` used to be charged as one cell
                    // while it padded its row with 16,383 empty slots, and about 20,000 such rows
                    // — under a megabyte of XML — asked for some 5 GiB.
                    let skippedRows = max(0, rowIndex - rows.count)
                    let rowLength = rowIndex < rows.count ? rows[rowIndex].count : 0
                    remaining -= skippedRows + max(0, cellColumn - rowLength)
                    if remaining < 0 { overBudget = true; delegate.stop(); return }
                    while rows.count <= rowIndex { rows.append([]) }
                    while rows[rowIndex].count <= cellColumn { rows[rowIndex].append(nil) }
                    rows[rowIndex][cellColumn] = text
                default: break
                }
            }
            delegate.characters = { text in if inValue || inInline { value += text } }
        }
        if overBudget { throw SpreadsheetError.tooManyCells(limit: XLSXWorkbookReader.maximumCells) }
        budget = remaining
        return rows
    }
}
