import Foundation
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

// MARK: - The library (NL-QTY-05)

/// One material or labour item with its rate (NL-QTY-05).
///
/// The rate is per SI base unit of its basis — per square metre, metre, cubic metre or piece —
/// exactly as ADR-0020 prices a Unit Cost, so applying an entry writes the rate unchanged.
public struct RateLibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var basis: LedgerRateBasis
    public var rate: Decimal
    public var currencyCode: String
    /// Waste as a factor (0.10 for 10 %), or `nil`.
    public var waste: Decimal?
    /// One pack's size in the basis unit (2.88 for a 2.88 m² board), or `nil`.
    public var packSize: Decimal?
    public var costCode: String
    public var trade: String
    public var notes: String

    public init(
        id: UUID = UUID(), name: String, basis: LedgerRateBasis, rate: Decimal, currencyCode: String,
        waste: Decimal? = nil, packSize: Decimal? = nil, costCode: String = "", trade: String = "", notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.basis = basis
        self.rate = rate
        self.currencyCode = currencyCode
        self.waste = waste
        self.packSize = packSize
        self.costCode = costCode
        self.trade = trade
        self.notes = notes
    }
}

/// The office's rate library as a file in Application Support (NL-QTY-05). Local-first: shared by
/// copying the file, like a tool set; never a server.
///
/// A project never reads the library for its numbers: applying an entry writes the rate onto the
/// rows, so a bid keeps the rates it was priced with until "Update rates" is chosen.
public struct RateLibraryStore: Sendable {

    public static let formatIdentifier = "zenit.rateLibrary"
    public static let currentSchemaVersion = 1

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("rate-library.json") }

    /// A store over an explicit directory. Tests pass a temporary one.
    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Zenit PDF/RateLibrary`.
    public static func standard() -> RateLibraryStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return RateLibraryStore(directory: base
            .appendingPathComponent("Zenit PDF", isDirectory: true)
            .appendingPathComponent("RateLibrary", isDirectory: true))
    }

    struct Envelope: Codable {
        var format: String
        var schemaVersion: Int
        var entries: [RateLibraryEntry]
    }

    /// The entries, or `[]` when no library has been written yet. A file this build cannot read
    /// is an error, never an empty library — a library that silently reads as empty is how a
    /// person loses it.
    public func read() throws -> [RateLibraryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.format == Self.formatIdentifier, envelope.schemaVersion == Self.currentSchemaVersion else {
            throw DocumentCommandError.ledgerFailed("not a rate library this version can read")
        }
        return envelope.entries
    }

    /// Replaces the library, atomically.
    public func write(_ entries: [RateLibraryEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(Envelope(format: Self.formatIdentifier, schemaVersion: Self.currentSchemaVersion, entries: entries))
            .write(to: fileURL, options: .atomic)
    }
}

// MARK: - Importing a supplier list

/// Reads a supplier price list pasted from a spreadsheet or saved as CSV (NL-QTY-05).
///
/// The first line names the columns — `Name, Unit, Rate, Currency, Waste, Pack, Cost Code, Trade,
/// Notes`, in any order, in English or Swedish. Tabs, semicolons or commas separate the fields;
/// with tabs or semicolons a decimal comma is read as a decimal point. A line that cannot be
/// read is reported with its number and why — never guessed.
public enum RateLibraryCSV {

    public struct Rejection: Hashable, Sendable {
        public let line: Int
        public let reason: String
    }

    enum Field: CaseIterable { case name, unit, rate, currency, waste, pack, costCode, trade, notes }

    static let headerNames: [Field: Set<String>] = [
        .name: ["name", "namn", "material", "artikel", "description", "beskrivning"],
        .unit: ["unit", "enhet", "basis"],
        .rate: ["rate", "price", "pris", "à-pris", "a-pris", "apris", "unit cost", "unit price"],
        .currency: ["currency", "valuta"],
        .waste: ["waste", "waste %", "spill", "spill %", "svinn", "svinn %"],
        .pack: ["pack", "pack size", "förpackning", "forpackning", "pack size (unit)"],
        .costCode: ["cost code", "kontokod", "code", "kod", "bsab"],
        .trade: ["trade", "yrke", "yrkesgrupp", "entreprenad"],
        .notes: ["notes", "note", "anteckning", "kommentar"]
    ]

    public static func parse(_ text: String, defaultCurrency: String) -> (entries: [RateLibraryEntry], rejected: [Rejection]) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0) }
        guard let headerIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return ([], [])
        }
        let header = lines[headerIndex]
        let delimiter: Character = header.contains("\t") ? "\t" : (header.contains(";") ? ";" : ",")
        let decimalComma = delimiter != ","
        var positions: [Field: Int] = [:]
        for (index, title) in split(header, delimiter).enumerated() {
            let key = title.trimmingCharacters(in: .whitespaces).lowercased()
            if let field = headerNames.first(where: { $0.value.contains(key) })?.key, positions[field] == nil {
                positions[field] = index
            }
        }
        guard positions[.name] != nil, positions[.unit] != nil, positions[.rate] != nil else {
            return ([], [Rejection(line: headerIndex + 1, reason: NSLocalizedString(
                "The first line must name at least the Name, Unit and Rate columns.",
                comment: "Rate library import: the header line lacks required columns"
            ))])
        }
        var entries: [RateLibraryEntry] = []
        var rejected: [Rejection] = []
        // A bare waste number is read once for the whole list (T-024): as a percentage when the
        // column's header says "%" or any bare value in the list exceeds 1, otherwise as a
        // fraction. A cell that says "%" itself is a percentage either way. Cell by cell, a
        // "Waste %" column of 1, 2 and 5 read the 1 as 100 %, and a 0.5 as 50 %.
        var wasteHeaderSaysPercent = false
        if let index = positions[.waste] {
            let titles = split(header, delimiter)
            wasteHeaderSaysPercent = index < titles.count && titles[index].contains("%")
        }
        var bareWaste: Set<Int> = []   // entries whose waste cell is a bare number
        for (offset, line) in lines.enumerated() where offset > headerIndex {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let fields = split(line, delimiter)
            func value(_ field: Field) -> String {
                guard let index = positions[field], index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespaces)
            }
            let number = { (text: String) -> Decimal? in parseNumber(text, decimalComma: decimalComma) }
            let name = value(.name)
            guard !name.isEmpty else {
                rejected.append(.init(line: offset + 1, reason: NSLocalizedString("No name.", comment: "Rate library import: a line without a name")))
                continue
            }
            guard let basis = LedgerRateBasis(unitText: value(.unit)) else {
                rejected.append(.init(line: offset + 1, reason: String(format: NSLocalizedString(
                    "“%@” is not a unit this list understands (m, m², m³, pcs).", comment: "Rate library import: unknown unit"
                ), value(.unit))))
                continue
            }
            guard let rate = number(value(.rate)), rate >= 0 else {
                rejected.append(.init(line: offset + 1, reason: String(format: NSLocalizedString(
                    "“%@” is not a rate.", comment: "Rate library import: the rate is not a number"
                ), value(.rate))))
                continue
            }
            let currency = value(.currency).uppercased()
            var waste: Decimal?
            var wasteIsBare = false
            let wasteText = value(.waste)
            if !wasteText.isEmpty {
                guard let parsed = number(wasteText.replacingOccurrences(of: "%", with: "")), parsed >= 0 else {
                    rejected.append(.init(line: offset + 1, reason: String(format: NSLocalizedString(
                        "“%@” is not a waste percentage.", comment: "Rate library import: the waste is not a number"
                    ), wasteText)))
                    continue
                }
                wasteIsBare = !wasteText.contains("%")
                waste = wasteIsBare ? parsed : parsed / 100
            }
            let packText = value(.pack)
            let packSize = packText.isEmpty ? nil : number(packText)
            guard packText.isEmpty || packSize != nil else {
                rejected.append(.init(line: offset + 1, reason: String(format: NSLocalizedString(
                    "“%@” is not a pack size.", comment: "Rate library import: the pack size is not a number"
                ), packText)))
                continue
            }
            entries.append(RateLibraryEntry(
                name: name, basis: basis, rate: rate,
                currencyCode: QuantityDimension.isValidCurrencyCode(currency) ? currency : defaultCurrency,
                waste: waste, packSize: packSize,
                costCode: value(.costCode), trade: value(.trade), notes: value(.notes)
            ))
            if wasteIsBare { bareWaste.insert(entries.count - 1) }
        }
        // "10", "10 %" and "0.10" all mean ten per cent — the bare ones decided for the list.
        if wasteHeaderSaysPercent || bareWaste.contains(where: { (entries[$0].waste ?? 0) > 1 }) {
            for index in bareWaste {
                if let waste = entries[index].waste { entries[index].waste = waste / 100 }
            }
        }
        return (entries, rejected)
    }

    /// Splits one line, honouring double-quoted fields.
    static func split(_ line: String, _ delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = Array(line).makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                quoted.toggle()
            } else if character == delimiter, !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    /// A number with an optional thousands space, in the list's decimal convention.
    static func parseNumber(_ text: String, decimalComma: Bool) -> Decimal? {
        var cleaned = text.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "")
        for suffix in ["kr", "sek", "eur", "usd", ":-"] where cleaned.lowercased().hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        if decimalComma { cleaned = cleaned.replacingOccurrences(of: ",", with: ".") }
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }),
              cleaned.filter({ $0 == "." }).count <= 1
        else { return nil }
        // "5." and ".5" are a person's spellings of 5 and 0.5; the strict grammar wants a digit
        // on both sides of the point.
        if cleaned.hasPrefix(".") { cleaned = "0" + cleaned }
        if cleaned.hasPrefix("-.") { cleaned = "-0" + cleaned.dropFirst() }
        if cleaned.hasSuffix(".") { cleaned += "0" }
        // Whole-string, not `Decimal(string:)`: that is a prefix parser, and it read "12-5" as 12,
        // "120-150" as 120 and a waste of "5-10" as 5 %, so the line was priced wrongly instead of
        // being refused with its line number (S-036). The same strict literal as R-193's.
        return DecimalString(text: cleaned)?.value
    }
}

extension LedgerRateBasis {
    /// The basis a unit spelling names.
    init?(unitText: String) {
        switch unitText.trimmingCharacters(in: .whitespaces).lowercased() {
        case "m2", "m²", "kvm", "sqm", "m^2": self = .area
        case "m", "lm", "löpmeter", "lopmeter": self = .length
        case "m3", "m³", "kbm", "m^3": self = .volume
        case "st", "pcs", "pc", "each", "ea", "styck", "stk": self = .count
        default: return nil
        }
    }

    /// The length power a quantity of this basis has.
    var lengthPower: Int {
        switch self {
        case .count: 0
        case .length: 1
        case .area: 2
        case .volume: 3
        }
    }

    /// Whether a rate of this basis prices a row drawn with `tool`: the quantity Total Cost
    /// prices for the tool (ADR-0020, ``LedgerStore/pricedColumn(for:)``) has this basis's length
    /// power. A tool that prices nothing — a rise, a slope, an angle — is priced by no rate.
    /// Applying an entry and updating a row's rate from it both ask this, so the library never
    /// writes a rate onto a row it could not have priced (T-027).
    func prices(_ tool: Domain.Tool?) -> Bool {
        LedgerStore.pricedColumn(for: tool)?.measurementField?.dimension.lengthPower == lengthPower
    }
}

// MARK: - Applying and updating rates

extension AppCoreEnvironment {

    /// The entries of the library this environment uses.
    public func rateLibraryEntries() -> [RateLibraryEntry] {
        (try? rateLibraryStore.read()) ?? []
    }

    /// Adds the lines of a supplier list to the library; an entry whose name is already there is
    /// replaced, so re-importing an updated list updates it.
    public func importRateList(_ text: String) throws -> (imported: Int, rejected: [RateLibraryCSV.Rejection]) {
        let currency = ledger.defaultCurrencyCode
        let parsed = RateLibraryCSV.parse(text, defaultCurrency: currency)
        var entries = try rateLibraryStore.read()
        for entry in parsed.entries {
            if let index = entries.firstIndex(where: { $0.name.lowercased() == entry.name.lowercased() }) {
                var replaced = entry
                replaced.id = entries[index].id
                entries[index] = replaced
            } else {
                entries.append(entry)
            }
        }
        if !parsed.entries.isEmpty { try rateLibraryStore.write(entries) }
        return (parsed.entries.count, parsed.rejected)
    }

    /// Removes an entry from the library. Rows priced with it keep their rates.
    public func removeRateEntry(_ id: UUID) throws {
        try rateLibraryStore.write(try rateLibraryStore.read().filter { $0.id != id })
    }

    /// Writes an entry onto rows — Material, Unit Cost, Cost Code, Trade, and Waste and Pack size
    /// when the ledger has those columns — as **one** undoable bulk edit. Refused when a row's
    /// quantity is not what the entry is priced by (a per-m² rate on a length).
    public func applyRateEntry(_ id: UUID, to markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        guard let entry = rateLibraryEntries().first(where: { $0.id == id }) else {
            return .failure(NSLocalizedString("Nothing was changed: that item is no longer in the rate library.", comment: "Rate library refusal: unknown entry"))
        }
        var mismatched = 0
        for raw in markupIDs {
            guard let record = await session.markup(MarkupID(raw)) else { continue }
            if !entry.basis.prices(record.tool) { mismatched += 1 }
        }
        if mismatched > 0 {
            return .failure(String(format: NSLocalizedString(
                "Nothing was changed: “%1$@” is priced per %2$@, and %3$d of the selected rows measure something else.",
                comment: "Rate library refusal: a rate applied to rows of another quantity; entry, unit, count"
            ), entry.name, entry.basis.unitSymbol, mismatched))
        }
        var values: [LedgerColumnID: ZPDFUIPresentation.LedgerCellValue] = [
            .material: .text(entry.name),
            .unitCost: .currency(amount: entry.rate, code: entry.currencyCode)
        ]
        if !entry.costCode.isEmpty { values[.costCode] = .text(entry.costCode) }
        if !entry.trade.isEmpty { values[.trade] = .text(entry.trade) }
        let columns = await session.ledgerColumns
        func userColumn(titled title: String) -> LedgerColumnDefinition? {
            columns.columns.first { LedgerBridge.isManageable($0) && $0.title.lowercased() == title.lowercased() && $0.kind == .number }
        }
        if let waste = entry.waste, let column = userColumn(titled: NSLocalizedString("Waste", comment: "Column Manager: waste factor column title")) {
            values[LedgerColumnID(column.key)] = .number(waste)
        }
        if let pack = entry.packSize, let column = userColumn(titled: NSLocalizedString("Pack size", comment: "Column Manager: pack size column title")) {
            values[LedgerColumnID(column.key)] = column.dimension.map {
                .quantity(ZPDFUIPresentation.DecimalQuantity(value: pack, dimension: Shown.Dimension(domain: $0)))
            } ?? .number(pack)
        }
        return await applyBulkEdit(LedgerBulkEditRequest(markupIDs: markupIDs, values: values))
    }

    /// Rows whose Unit Cost no longer matches the library's rate for their Material, with the
    /// money each change would move — the before/after "Update rates" shows (NL-QTY-05).
    ///
    /// Only rows the entry prices are offered: Material and Unit Cost are typed columns, so a
    /// person can put "Concrete" at 100 SEK on a Rise/Drop, a Slope or a Length row. Its Total
    /// Cost is an error cell (Rise/Drop, Slope) or a per-metre price (Length), and a per-m³ rate
    /// written over it would price nothing or price the wrong quantity — the refusal
    /// ``applyRateEntry(_:to:)`` makes, kept here too (T-027).
    public func pendingRateUpdates() async -> [LedgerRateUpdate] {
        let entries = Dictionary(rateLibraryEntries().map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        guard !entries.isEmpty, let projection = try? await session.ledgerProjection(.flat) else { return [] }
        var updates: [LedgerRateUpdate] = []
        for index in 0..<projection.rowCount {
            guard let row = projection.row(at: index) else { continue }
            guard case .text(let material) = row.value(.material),
                  let entry = entries[material.lowercased()],
                  case .currency(let current, let code) = row.value(.unitCost),
                  code == entry.currencyCode, current != entry.rate else { continue }
            let tool = row.measurementKind.map { Domain.Tool(shown: $0) }
            guard entry.basis.prices(tool), let priced = LedgerStore.pricedColumn(for: tool) else { continue }
            // The quantity Total Cost prices — the priced column's own cell, Repeat × and the
            // cutout rule included — never the Value's fallback chain, which read a Rise/Drop by
            // its rise and a Slope by its ratio while Total Cost stayed an error cell (T-027).
            let quantity = row.quantity(LedgerColumnID(priced.rawValue))?.value ?? 0
            updates.append(LedgerRateUpdate(
                markupID: row.markupID, subject: row.displayValue(.subject), material: entry.name,
                before: current, after: entry.rate, currencyCode: code,
                moneyDelta: quantity * (entry.rate - current)
            ))
        }
        return updates
    }

    /// Writes the library's rate onto the chosen rows, as **one** undoable step.
    public func applyRateUpdates(_ markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        let actionName = NSLocalizedString("Update Rates", comment: "Undo action name: rates updated from the library")
        let updates = await pendingRateUpdates().filter { markupIDs.contains($0.markupID) }
        guard let unitCost = await session.ledgerColumns.columnID(standard: .unitCost) else {
            return .failure(NSLocalizedString("This ledger cannot be edited.", comment: "Bulk edit refusal when no document is attached to the ledger"))
        }
        let batch = updates.map {
            DocumentCommand.editCustomValue(id: MarkupID($0.markupID), column: unitCost, value: .currency(amount: $0.after, code: $0.currencyCode))
        }
        guard !batch.isEmpty else { return LedgerBulkEditReceipt(undoActionName: actionName) }
        do {
            let outcome = try await commands.performBatch(batch, actionName: actionName)
            await ledger.refresh()
            return LedgerBulkEditReceipt(changedMarkupIDs: Set((outcome?.changedMarkupIDs ?? []).map(\.rawValue)), undoActionName: actionName)
        } catch {
            return .failure(String(describing: error))
        }
    }
}

// MARK: - The presenter's side

extension AppLedgerPresenter: LedgerRateLibraryManaging {

    public var rateEntries: [LedgerRateEntrySummary] {
        (rateLibrarySeam?.entries() ?? []).map {
            LedgerRateEntrySummary(
                id: $0.id, name: $0.name, basis: $0.basis, rate: $0.rate, currencyCode: $0.currencyCode,
                waste: $0.waste, packSize: $0.packSize, costCode: $0.costCode, trade: $0.trade
            )
        }
    }

    public func importRateList(_ text: String) async -> LedgerRateImportResult {
        guard let seam = rateLibrarySeam else { return LedgerRateImportResult(imported: 0, rejectedLines: [], failure: "no document") }
        do {
            let result = try seam.importList(text)
            return LedgerRateImportResult(
                imported: result.imported,
                rejectedLines: result.rejected.map { String(format: NSLocalizedString(
                    "Line %1$d: %2$@", comment: "Rate library import: a rejected line; the line number, the reason"
                ), $0.line, $0.reason) },
                failure: nil
            )
        } catch {
            return LedgerRateImportResult(imported: 0, rejectedLines: [], failure: String(describing: error))
        }
    }

    public func removeRateEntry(_ id: UUID) async -> Bool {
        (try? rateLibrarySeam?.remove(id)) != nil
    }

    public func applyRateEntry(_ id: UUID, to markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        await rateLibrarySeam?.apply(id, markupIDs) ?? .failure("no document")
    }

    public func pendingRateUpdates() async -> [LedgerRateUpdate] {
        await rateLibrarySeam?.pending() ?? []
    }

    public func applyRateUpdates(_ markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        await rateLibrarySeam?.update(markupIDs) ?? .failure("no document")
    }
}

/// The rate library operations the presenter reaches, installed by the environment.
public struct LedgerRateLibrarySeam: Sendable {
    public let entries: @MainActor @Sendable () -> [RateLibraryEntry]
    public let importList: @MainActor @Sendable (String) throws -> (imported: Int, rejected: [RateLibraryCSV.Rejection])
    public let remove: @MainActor @Sendable (UUID) throws -> Void
    public let apply: @MainActor @Sendable (UUID, Set<UUID>) async -> LedgerBulkEditReceipt
    public let pending: @MainActor @Sendable () async -> [LedgerRateUpdate]
    public let update: @MainActor @Sendable (Set<UUID>) async -> LedgerBulkEditReceipt
}
