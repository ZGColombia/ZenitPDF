import Foundation
import ZPDFContracts

/// A saved layout for handing the ledger to another system (NL-PLAT-08): which columns, in which
/// order, under which headers, with how many decimals, in which CSV dialect and encoding.
///
/// It renders through the one ``ExportProjection`` every export uses, so the numbers are the
/// ledger's own exact decimals (QUALITY_BAR A29/A30), rounded once, here, to the profile's places.
/// A `.zpdfprofile` file is this value as JSON; like a `.zpdftools` set it holds a description and
/// nothing that runs.
public struct LedgerExportProfile: Codable, Hashable, Sendable {

    public static let currentFormatVersion = 1
    public static let fileExtension = "zpdfprofile"

    public struct Column: Codable, Hashable, Sendable {
        /// The ledger column key (`subject`, `planArea`, a custom column's key).
        public var key: String
        /// The header the receiving system expects; `nil` keeps the ledger's title.
        public var header: String?
        /// Decimal places for a number; `nil` keeps the ledger's own formatting.
        public var decimals: Int?
        /// The unit a quantity column is written in (`mm`, `ft`, `m2`, `ft2`, `m3`, `l`…), converted
        /// from the stored SI value and rounded once; `nil` keeps the ledger's display unit.
        /// A cell whose dimension does not match the unit is written empty and named, never
        /// converted by guess (NL-PLAT-08).
        public var unit: String?

        public init(key: String, header: String? = nil, decimals: Int? = nil, unit: String? = nil) {
            self.key = key
            self.header = header
            self.decimals = decimals
            self.unit = unit
        }
    }

    /// Rows grouped by one column's value, each group followed by a subtotal row, the receiving
    /// system's "cost code" layout (NL-PLAT-08).
    public struct Grouping: Codable, Hashable, Sendable {
        /// The column whose value groups the rows (`costCode`, `trade`, `subject`…).
        public var key: String
        /// Whether each group is followed by a subtotal row.
        public var subtotals: Bool
        /// The subtotal row's label, in the grouping column; `{group}` is the group's value.
        public var subtotalLabel: String
        /// Whether a grand total row closes the file.
        public var grandTotal: Bool
        /// The grand total row's label, in the first column.
        public var grandTotalLabel: String

        public init(key: String, subtotals: Bool = true, subtotalLabel: String = "{group} subtotal",
                    grandTotal: Bool = false, grandTotalLabel: String = "Total") {
            self.key = key
            self.subtotals = subtotals
            self.subtotalLabel = subtotalLabel
            self.grandTotal = grandTotal
            self.grandTotalLabel = grandTotalLabel
        }
    }

    public enum Encoding: String, Codable, Hashable, Sendable {
        case utf8
        case utf8WithBOM
        /// Windows-1252, which many older estimating imports in the Nordics still expect.
        case windows1252
    }

    public enum LineEnding: String, Codable, Hashable, Sendable { case crlf, lf }

    public var formatVersion: Int
    public var name: String
    public var columns: [Column]
    public var delimiter: String
    public var decimalSeparator: String
    public var quoteAllFields: Bool
    public var includeHeader: Bool
    public var encoding: Encoding
    public var lineEnding: LineEnding
    /// File name without extension; `{project}` and `{date}` (yyyy-MM-dd) are substituted.
    public var fileNamePattern: String
    /// Rows grouped with subtotals; `nil` writes the rows in ledger order, ungrouped.
    public var grouping: Grouping?

    public init(name: String, columns: [Column], delimiter: String = ";", decimalSeparator: String = ",",
                quoteAllFields: Bool = false, includeHeader: Bool = true, encoding: Encoding = .utf8WithBOM,
                lineEnding: LineEnding = .crlf, fileNamePattern: String = "{project} {date}") {
        self.formatVersion = Self.currentFormatVersion
        self.name = name
        self.columns = columns
        self.delimiter = delimiter
        self.decimalSeparator = decimalSeparator
        self.quoteAllFields = quoteAllFields
        self.includeHeader = includeHeader
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.fileNamePattern = fileNamePattern
        self.grouping = nil
    }

    public enum ProfileError: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedVersion(Int)
        case invalid(String)
        case notEncodable(character: String)

        public var description: String {
            switch self {
            case let .unsupportedVersion(v): return "This export profile uses format \(v), which this build does not read."
            case let .invalid(why): return "This export profile is not valid: \(why)."
            case let .notEncodable(c): return "“\(c)” cannot be written in the profile's Windows-1252 encoding."
            }
        }
    }

    /// Reads a `.zpdfprofile`, trusting nothing: version, sizes and dialect are checked.
    public static func read(_ data: Data) throws -> LedgerExportProfile {
        guard data.count <= 1_000_000 else { throw ProfileError.invalid("the file is larger than 1 MB") }
        let profile: LedgerExportProfile
        do { profile = try JSONDecoder().decode(LedgerExportProfile.self, from: data) } catch {
            throw ProfileError.invalid("it is not a Zenit export profile")
        }
        guard profile.formatVersion == currentFormatVersion else { throw ProfileError.unsupportedVersion(profile.formatVersion) }
        try profile.validate()
        return profile
    }

    public func validate() throws {
        guard !columns.isEmpty, columns.count <= 500 else { throw ProfileError.invalid("it must list 1 to 500 columns") }
        guard delimiter.count == 1, decimalSeparator.count == 1 else { throw ProfileError.invalid("the delimiter and decimal separator must be one character each") }
        guard delimiter != decimalSeparator else { throw ProfileError.invalid("the delimiter and the decimal separator are the same") }
        guard !["\"", "\r", "\n"].contains(delimiter) else { throw ProfileError.invalid("the delimiter cannot be a quote or a line break") }
        guard columns.allSatisfy({ ($0.decimals ?? 0) >= 0 && ($0.decimals ?? 0) <= 12 && $0.key.count <= 200 }) else {
            throw ProfileError.invalid("a column has an impossible number of decimals")
        }
        for column in columns {
            if let unit = column.unit, ProfileUnit(symbol: unit) == nil {
                throw ProfileError.invalid("“\(unit)” is not a unit this build converts to (\(ProfileUnit.supportedSymbols.joined(separator: ", ")))")
            }
        }
        if let grouping {
            guard !grouping.key.isEmpty, grouping.key.count <= 200,
                  grouping.subtotalLabel.count <= 200, grouping.grandTotalLabel.count <= 200 else {
                throw ProfileError.invalid("the grouping names no column, or its labels are too long")
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The file name for `project` on `date`, with characters a file system refuses replaced.
    public func fileName(project: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = fileNamePattern.replacingOccurrences(of: "{project}", with: project)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        let safe = base.map { "/:\\".contains($0) ? "-" : $0 }
        return String(safe) + ".csv"
    }

    // MARK: - Rendering

    /// What a render produced and what it could not honour.
    public struct Rendered: Sendable, Equatable {
        public var data: Data
        /// Columns the ledger does not have; written empty.
        public var missingKeys: [String]
        /// Columns whose unit does not fit a cell's dimension (a length column asked for in m²);
        /// those cells are written empty.
        public var unitMismatchKeys: [String]
        /// The projection's scale notice when some written rows hold a value kept under an older
        /// scale (ADR-0030 §2, K-04), else `nil`. A profile's layout belongs to the system that
        /// receives the file, so no column is added for it: the caller must say it beside the
        /// export instead (it1r K-04).
        public var staleScaleNotice: String? = nil
    }

    /// The CSV bytes for the data rows of `projection`, in this profile's layout. Columns the
    /// ledger does not have are written empty (and named in `missingKeys`), never guessed.
    public func render(_ projection: ExportProjection) throws -> (data: Data, missingKeys: [String]) {
        let rendered = try renderDetailed(projection)
        return (rendered.data, rendered.missingKeys)
    }

    /// ``render(_:)`` with the unit mismatches reported too, and the profile's grouping applied:
    /// rows ordered by the grouping column's value (ledger order kept inside a group, groups in
    /// the order they first appear), each group closed by a subtotal row whose quantities are the
    /// sums of the exact stored values, converted and rounded once.
    public func renderDetailed(_ projection: ExportProjection) throws -> Rendered {
        try validate()
        var rendered = grouping == nil ? try renderFlat(projection) : try renderGrouped(projection)
        rendered.staleScaleNotice = projection.table.metadata.staleScaleNotice
        return rendered
    }

    private func renderFlat(_ projection: ExportProjection) throws -> Rendered {
        let table = projection.table
        let index = Dictionary(table.columns.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = columns.map(\.key).filter { index[$0] == nil }
        let delimiterCharacter = Character(delimiter)
        let newline = lineEnding == .crlf ? "\r\n" : "\n"
        var text = ""
        if includeHeader {
            text += columns.map { column in
                escape(column.header ?? index[column.key].map { table.columns[$0].title } ?? column.key, delimiter: delimiterCharacter)
            }.joined(separator: delimiter) + newline
        }
        var mismatches: Set<String> = []
        for row in table.allRows() {
            text += columns.map { column -> String in
                guard let position = index[column.key], position < row.cells.count else { return "" }
                let cell = row.cells[position]
                guard let rendered = value(cell, column: column, in: table.columns[position]) else {
                    mismatches.insert(column.key)
                    return ""
                }
                return escape(rendered, delimiter: delimiterCharacter, isNumber: cell.number != nil)
            }.joined(separator: delimiter) + newline
        }
        return Rendered(data: try encode(text), missingKeys: missing,
                        unitMismatchKeys: columns.map(\.key).filter { mismatches.contains($0) })
    }

    private func renderGrouped(_ projection: ExportProjection) throws -> Rendered {
        guard let grouping else { return try renderFlat(projection) }
        let table = projection.table
        let index = Dictionary(table.columns.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = columns.map(\.key).filter { index[$0] == nil }
        let delimiterCharacter = Character(delimiter)
        let newline = lineEnding == .crlf ? "\r\n" : "\n"
        var text = ""
        if includeHeader {
            text += columns.map { column in
                escape(column.header ?? index[column.key].map { table.columns[$0].title } ?? column.key, delimiter: delimiterCharacter)
            }.joined(separator: delimiter) + newline
        }
        // Groups in the order they first appear; rows keep ledger order inside a group.
        var order: [String] = []
        var members: [String: [ExportRow]] = [:]
        for row in table.allRows() {
            let key: String
            if let position = index[grouping.key], position < row.cells.count { key = row.cells[position].text } else { key = "" }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(row)
        }
        // Columns that hold a number in any row. A subtotal or total label never takes one of
        // them: it used to overwrite that column's sum when the column came first (S-069).
        let numberKeys = Set(columns.compactMap { column -> String? in
            guard let position = index[column.key] else { return nil }
            let holdsNumber = members.values.contains { rows in
                rows.contains { position < $0.cells.count && $0.cells[position].number != nil }
            }
            return holdsNumber ? column.key : nil
        })
        // Each ledger column the profile writes adds once per row, however many profile columns
        // write it: one quantity listed in m² and in ft² used to add every row twice, so both
        // subtotals and the grand total read double (U-049).
        var seenKeys: Set<String> = []
        let summedPositions = columns.compactMap { column -> (key: String, position: Int)? in
            guard seenKeys.insert(column.key).inserted, let position = index[column.key] else { return nil }
            return (column.key, position)
        }
        var mismatches: Set<String> = []
        var grand = SubtotalAccumulator()
        for group in order {
            var subtotal = SubtotalAccumulator()
            for row in members[group] ?? [] {
                for (key, position) in summedPositions where position < row.cells.count {
                    subtotal.add(row.cells[position], key: key)
                    grand.add(row.cells[position], key: key)
                }
                text += columns.map { column -> String in
                    guard let position = index[column.key], position < row.cells.count else { return "" }
                    let cell = row.cells[position]
                    guard let rendered = value(cell, column: column, in: table.columns[position]) else {
                        mismatches.insert(column.key)
                        return ""
                    }
                    return escape(rendered, delimiter: delimiterCharacter, isNumber: cell.number != nil)
                }.joined(separator: delimiter) + newline
            }
            if grouping.subtotals {
                let label = grouping.subtotalLabel.replacingOccurrences(of: "{group}", with: group)
                text += totalRow(subtotal, label: label, labelKey: grouping.key, numberKeys: numberKeys,
                                 table: table, index: index, delimiter: delimiterCharacter, mismatches: &mismatches) + newline
            }
        }
        if grouping.grandTotal {
            text += totalRow(grand, label: grouping.grandTotalLabel, labelKey: columns.first?.key ?? grouping.key,
                             numberKeys: numberKeys, table: table, index: index, delimiter: delimiterCharacter,
                             mismatches: &mismatches) + newline
        }
        return Rendered(data: try encode(text), missingKeys: missing,
                        unitMismatchKeys: columns.map(\.key).filter { mismatches.contains($0) })
    }

    /// One subtotal or total row: each summable quantity column's sum, and the label in
    /// `labelKey`'s column — or, when the profile does not write that one or it holds numbers,
    /// in the first column that holds none. When every column holds numbers the label is left
    /// out: the file's columns are fixed by the system that reads it, and a sum is never
    /// dropped for its own label (S-069).
    private func totalRow(_ totals: SubtotalAccumulator, label: String, labelKey: String, numberKeys: Set<String>,
                          table: ExportTable, index: [String: Int], delimiter: Character,
                          mismatches: inout Set<String>) -> String {
        let candidates = columns.filter { $0.key == labelKey } + columns
        let labelColumn = candidates.first { !numberKeys.contains($0.key) }?.key
        return columns.map { column -> String in
            if column.key == labelColumn { return escape(label, delimiter: delimiter) }
            guard let sum = totals.sums[column.key] else { return "" }
            guard let rendered = total(sum, column: column, in: index[column.key].map { table.columns[$0] }) else {
                mismatches.insert(column.key)
                return ""
            }
            return escape(rendered, delimiter: delimiter, isNumber: true)
        }.joined(separator: String(delimiter))
    }

    /// Sums of the exact stored values of each summable column. A column whose cells disagree on
    /// dimension, or holds a refusal, has no sum: its subtotal cell is left empty rather than
    /// adding metres to square metres.
    ///
    /// Cells that agree on dimension but not on display unit — one markup shown in metres of its
    /// own in a feet column (NL-MEASURE-10) — still have a sum: the SI ``Sum/raw`` is exact
    /// whatever each row showed. Only ``Sum/converted``, which would add the metres to the feet,
    /// stops being one. That used to blank the subtotal and the grand total of the whole column,
    /// without a word in the post-export note (T-043).
    struct SubtotalAccumulator {
        struct Sum {
            var raw: Decimal
            var converted: Decimal
            var dimension: QuantityDimension?
            var unitSymbol: String
            var places: Int?
            /// False once two cells disagreed on display unit: ``converted`` is then no sum.
            var convertedIsConsistent = true
        }
        var sums: [String: Sum] = [:]
        var poisoned: Set<String> = []

        mutating func add(_ cell: ExportCell, key: String) {
            guard !poisoned.contains(key) else { return }
            switch cell {
            case .blank, .text, .date, .boolean:
                return
            case .refusal:
                poisoned.insert(key); sums[key] = nil
            case let .number(number):
                guard LedgerExportProfile.isSummable(number.dimension) else { poisoned.insert(key); sums[key] = nil; return }
                if var existing = sums[key] {
                    guard existing.dimension == number.dimension else {
                        poisoned.insert(key); sums[key] = nil; return
                    }
                    existing.raw += number.raw
                    if existing.unitSymbol == number.unitSymbol {
                        existing.converted += number.convertedRaw
                    } else {
                        existing.convertedIsConsistent = false
                    }
                    existing.places = max(existing.places ?? 0, LedgerExportProfile.places(of: number))
                    sums[key] = existing
                } else {
                    sums[key] = Sum(raw: number.raw, converted: number.convertedRaw, dimension: number.dimension,
                                    unitSymbol: number.unitSymbol, places: LedgerExportProfile.places(of: number))
                }
            }
        }
    }

    /// Whether quantities of this dimension add up: counts, lengths, areas, volumes and money.
    /// Rates (money per metre), ratios and angles do not.
    static func isSummable(_ dimension: QuantityDimension?) -> Bool {
        guard let dimension else { return false }
        return dimension.lengthPower >= 0 && !dimension.ratio && !dimension.angle
    }

    /// A subtotal or total in `column`'s layout, `tableColumn` being the ledger column it reads;
    /// `nil` when no unit fits the sum.
    ///
    /// With a profile unit the SI sum is converted to it. Without one the sum is in the ledger's
    /// display unit — the column's: the rows' own display sum when every row showed that unit,
    /// and otherwise the SI sum converted to the column's unit, the unit its overridden rows are
    /// written in too (T-041, T-043).
    private func total(_ sum: SubtotalAccumulator.Sum, column: Column, in tableColumn: ExportColumn?) -> String? {
        if let symbol = column.unit {
            return converted(sum.raw, dimension: sum.dimension, to: symbol, places: column.decimals ?? 3)
        }
        let ownUnit = tableColumn?.showsInOwnUnit(unitSymbol: sum.unitSymbol, dimension: sum.dimension) ?? false
        guard !sum.convertedIsConsistent || ownUnit else {
            return Self.localise(Self.rounded(sum.converted, places: column.decimals ?? sum.places ?? 3), separator: decimalSeparator)
        }
        guard let tableColumn else { return nil }
        return converted(sum.raw, dimension: sum.dimension, to: tableColumn.unitSymbol,
                         places: column.decimals ?? Self.places(of: tableColumn))
    }

    /// A cell in `column`'s layout, `tableColumn` being the ledger column it comes from, or `nil`
    /// when no unit fits the cell.
    ///
    /// A column with no profile unit keeps the ledger's display unit, which is the ledger
    /// column's. A row shown in units of its own (NL-MEASURE-10) is converted back to it from its
    /// stored SI value: written as it was shown, `3.81` metres sat under a feet column beside
    /// `12.5000` feet and the receiving system read it as 3.81 ft (T-041).
    func value(_ cell: ExportCell, column: Column, in tableColumn: ExportColumn? = nil) -> String? {
        guard case let .number(number) = cell else { return value(cell, decimals: column.decimals) }
        if let symbol = column.unit {
            return converted(number.raw, dimension: number.dimension, to: symbol, places: column.decimals ?? 3)
        }
        if let tableColumn, tableColumn.showsInOwnUnit(number) {
            return converted(number.raw, dimension: number.dimension, to: tableColumn.unitSymbol,
                             places: column.decimals ?? Self.places(of: tableColumn))
        }
        return value(cell, decimals: column.decimals)
    }

    /// `raw` (SI) in the unit `symbol`, rounded once to `places`, or `nil` when `symbol` is not a
    /// unit a profile converts to or does not fit the dimension — never converted by guess.
    private func converted(_ raw: Decimal, dimension: QuantityDimension?, to symbol: String, places: Int) -> String? {
        guard let unit = ProfileUnit(symbol: symbol), let dimension,
              unit.lengthPower == dimension.lengthPower, dimension.currencyCode == nil, !dimension.ratio, !dimension.angle
        else { return nil }
        return Self.localise(Self.rounded(unit.convert(fromSI: raw), places: places), separator: decimalSeparator)
    }

    /// The places a value converted into a ledger column's unit is written with: the column's
    /// declared precision, or, for a feet-and-inches column, the four places of decimal feet
    /// every other row of it is written with (``places(of:)``).
    static func places(of column: ExportColumn) -> Int {
        column.decimalPlaces ?? ExportProjector.imperialFeetDecimalPlaces
    }

    /// `value` rounded half away from zero to `places`, as plain digits, never "-0.00".
    static func rounded(_ value: Decimal, places: Int) -> String {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, places, .plain)
        var text = plain(result, places: places)
        if text.hasPrefix("-"), text.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) { text.removeFirst() }
        return text
    }

    /// The fraction digits a number is written with when the column names none: the ledger's
    /// own, or — for a feet-and-inches length, which has no decimal count — decimal feet to the
    /// four places the workbook uses. `nil` used to print every digit of 653/192 and to count as
    /// zero places in a subtotal, which then rounded 8.5677 ft to "9" (R-101).
    static func places(of number: ExportNumber) -> Int {
        number.decimalPlaces ?? ExportProjector.imperialFeetDecimalPlaces
    }

    func value(_ cell: ExportCell, decimals: Int?) -> String {
        guard case let .number(number) = cell else { return cell.text }
        guard let decimals else {
            // The ledger's own rounding and places, with this profile's decimal separator.
            guard let places = number.decimalPlaces else {
                return Self.localise(Self.rounded(number.display, places: Self.places(of: number)), separator: decimalSeparator)
            }
            return Self.localise(Self.plain(number.display, places: places), separator: decimalSeparator)
        }
        var source = number.convertedRaw
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, decimals, .plain)
        var text = Self.plain(rounded, places: decimals)
        if text.hasPrefix("-"), text.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) { text.removeFirst() }   // never "-0.00"
        return Self.localise(text, separator: decimalSeparator)
    }

    /// A decimal as plain digits, `places` after the point when given (padded), no grouping.
    static func plain(_ value: Decimal, places: Int? = nil) -> String {
        var text = NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
        guard let places else { return text }
        if places == 0 { return text.split(separator: ".").first.map(String.init) ?? text }
        if !text.contains(".") { text += "." }
        let fraction = text.split(separator: ".", omittingEmptySubsequences: false).last?.count ?? 0
        if fraction < places { text += String(repeating: "0", count: places - fraction) }
        return text
    }

    static func localise(_ text: String, separator: String) -> String {
        separator == "." ? text : text.replacingOccurrences(of: ".", with: separator)
    }

    /// RFC 4180 quoting plus the spreadsheet formula guard, by what the field is (CR-57): every
    /// text field (a subject, a label, a date, a header, a group or total label, a refusal) that
    /// starts with `=`, `+`, `-`, `@`, a tab or a carriage return gets an apostrophe; a number the
    /// projector rendered never does (R-102). The rule itself is ``CSVExporter``'s — one copy for
    /// every CSV the product writes; the two copies drifting apart was R-102 (S-072).
    func escape(_ field: String, delimiter: Character, isNumber: Bool = false) -> String {
        CSVExporter.escape(
            field, delimiter: delimiter, quoting: quoteAllFields ? .all : .minimal,
            guardFormulas: isNumber ? .none : .apostrophe
        )
    }

    func encode(_ text: String) throws -> Data {
        switch encoding {
        case .utf8: return Data(text.utf8)
        case .utf8WithBOM: return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .windows1252:
            // By character, composed first — the one Windows-1252 rule the seal and the OCR layer
            // use — so "Zoë" encodes whether its ë is stored as one scalar or as e + U+0308.
            // Scalar by scalar, the decomposed spelling failed the export on U+0308 (S-068).
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            for character in text {
                guard let encoded = Windows1252.bytes(for: character) else {
                    throw ProfileError.notEncodable(character: String(character))
                }
                bytes.append(contentsOf: encoded)
            }
            return Data(bytes)
        }
    }
}


/// The units a profile column can be written in, with the exact factor from the SI base unit of
/// the dimension (metre, square metre, cubic metre, or one for a count). Converting is a division
/// by the unit's size in SI, in `Decimal`, rounded once when the cell is written.
///
/// The length, area and volume rows are the contract's own units (`LengthUnit`, `AreaUnit`,
/// `VolumeUnit`) and factors: every display unit the app offers is one a profile writes, and a
/// row shown in acres or km² of its own converts like any other. A hand-typed copy of the table
/// lacked mi, km², in², acre, mi², cm³ and in³, so those rows exported blank (U-050).
public struct ProfileUnit: Sendable, Equatable {
    public let symbol: String
    public let lengthPower: Int
    /// The size of one of this unit in the SI base unit: 0.3048 for a foot.
    public let sizeInSI: Decimal

    /// Each row's first symbol is the file spelling (`m2`, `ft3`: the contract's raw value), then
    /// the contract's display symbol (`m²`, `ft³`) and any extra alias.
    static let table: [(symbols: [String], power: Int, size: Decimal)] = {
        var rows: [(symbols: [String], power: Int, size: Decimal)] = [(["pcs", "st", "ea"], 0, 1)]
        func add<Unit: DisplayUnit>(_: Unit.Type, aliases: [Unit: [String]] = [:]) {
            for unit in Unit.allCases {
                let symbols = [unit.rawValue] + (unit.symbol == unit.rawValue ? [] : [unit.symbol]) + (aliases[unit] ?? [])
                rows.append((symbols, Unit.dimension.lengthPower, unit.factorToBase))
            }
        }
        add(LengthUnit.self)
        add(AreaUnit.self, aliases: [.squareFoot: ["sq ft"]])
        add(VolumeUnit.self)
        return rows
    }()

    public static var supportedSymbols: [String] { table.map { $0.symbols[0] } }

    /// Every spelling ``init(symbol:)`` accepts, file spellings and aliases alike, in table order.
    /// The published `Docs/Formats/zpdfprofile.schema.json` lists exactly these as `unit`'s enum;
    /// `FormatSchemaConformanceTests` fails when the two drift apart (U-050).
    public static var allSpellings: [String] { table.flatMap(\.symbols) }

    public init?(symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        guard let row = Self.table.first(where: { $0.symbols.contains(trimmed) }) else { return nil }
        self.symbol = row.symbols[0]
        self.lengthPower = row.power
        self.sizeInSI = row.size
    }

    /// `value` (in the SI base unit) in this unit, exact to `Decimal`'s precision, unrounded.
    public func convert(fromSI value: Decimal) -> Decimal {
        sizeInSI == 1 ? value : value / sizeInSI
    }
}
