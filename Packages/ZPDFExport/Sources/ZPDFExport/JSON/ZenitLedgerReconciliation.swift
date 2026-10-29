import Foundation
import ZPDFContracts

/// Holds an imported `.zpdfjson` against a ledger this build produced, cell by cell.
///
/// This is what makes the reader worth having. A `.zpdfjson` carries no geometry, so it cannot
/// rebuild a takeoff (see ``ZenitInterchangeImport``) — but it carries every quantity, exactly,
/// as an invariant decimal string, and that is enough to answer the question an estimator
/// actually asks of a delivered ledger: *does this agree with mine, and where does it not?*
///
/// It is also the round-trip proof, run against the shipping export path rather than against a
/// fixture: export the open project, import the bytes back, reconcile, and every row must be
/// ``Verdict/identical`` down to the last digit.
///
/// # How rows are matched
///
/// By `markupID`, which is the row's stable identity in both documents — never by index, which
/// changes with sorting, grouping and filtering, and never by name, which is not unique. Rows
/// are flattened out of their groups first, because two exports of the same takeoff grouped
/// differently hold the same rows in different places and must still reconcile.
///
/// # What counts as a difference
///
/// A number cell differs when its `raw` differs — the exact stored value in SI base units.
/// `display` is deliberately *not* compared: it is a rendering in the export's number locale, so
/// a Swedish export and an English one of the same takeoff carry `"0,44"` and `"0.44"` for one
/// identical quantity. Comparing the rendering would report a difference that is not there.
public struct ZenitLedgerReconciliation: Hashable, Sendable {

    /// What happened to one row.
    public enum Verdict: String, Hashable, Sendable {
        /// Present in both, and every cell agrees.
        case identical
        /// Present in both, and at least one cell differs.
        case differs
        /// In the imported file and not in the ledger it was held against.
        case onlyInFile
        /// In the ledger and not in the imported file.
        case onlyInLedger
    }

    /// One disagreeing cell, named so a person can go and look at it.
    public struct Difference: Hashable, Sendable {
        public let markupID: String
        public let columnKey: String
        public let columnTitle: String
        /// The value in the imported file, rendered for display.
        public let inFile: String
        /// The value in the ledger it was held against, rendered for display.
        public let inLedger: String
    }

    public let rowsIdentical: Int
    public let rowsDiffering: Int
    public let rowsOnlyInFile: [String]
    public let rowsOnlyInLedger: [String]
    public let differences: [Difference]
    /// Set when the two documents do not even describe the same table, in which case the row
    /// comparison is not attempted: comparing cells across mismatched columns would produce
    /// differences that mean nothing.
    public let columnMismatch: String?

    /// Whether the two ledgers agree completely.
    public var isExactMatch: Bool {
        columnMismatch == nil
            && rowsDiffering == 0
            && rowsOnlyInFile.isEmpty
            && rowsOnlyInLedger.isEmpty
    }

    /// The most differences reported individually. Beyond this the counts still tell the truth
    /// and the list stops growing, because a sheet listing forty thousand cells helps nobody.
    public static let maximumReportedDifferences = 200

    /// Reconciles an imported document against one this build produced.
    public static func compare(
        imported: ZenitInterchangeDocument,
        against ledger: ZenitInterchangeDocument
    ) -> ZenitLedgerReconciliation {
        let importedKeys = imported.columns.map(\.key)
        let ledgerKeys = ledger.columns.map(\.key)
        guard importedKeys == ledgerKeys else {
            return ZenitLedgerReconciliation(
                rowsIdentical: 0,
                rowsDiffering: 0,
                rowsOnlyInFile: [],
                rowsOnlyInLedger: [],
                differences: [],
                columnMismatch: String(
                    format: NSLocalizedString(
                        "The file's columns are %1$@; this ledger's are %2$@.",
                        comment: "Reconciliation refusal when two ledgers have different columns"
                    ),
                    importedKeys.joined(separator: ", "),
                    ledgerKeys.joined(separator: ", ")
                )
            )
        }

        let titles = ledger.columns.map(\.title)
        let ordered = orderedRows(imported)
        let left = Dictionary(ordered, uniquingKeysWith: { first, _ in first })
        let right = flatten(ledger)
        var identical = 0
        var differing = 0
        var differences: [Difference] = []

        // In the imported file's own row order, so the same file reviewed twice lists the same
        // differences in the same order and the 200-item cut keeps the same ones. The rows used
        // to come out of a dictionary, whose order changes with every process (BH-513).
        for (markupID, fileRow) in ordered {
            guard let ledgerRow = right[markupID] else { continue }
            var rowDiffers = false
            // A row narrower or wider than its counterpart is a difference in the cells one side
            // lacks, not an index out of range: `compare` is public, and a document read without
            // ``ZenitInterchangeImport``'s width check used to trap the process here (BH-514).
            let width = max(fileRow.cells.count, ledgerRow.cells.count)
            for index in 0..<width {
                let cell = index < fileRow.cells.count ? fileRow.cells[index] : nil
                let other = index < ledgerRow.cells.count ? ledgerRow.cells[index] : nil
                if let cell, let other, agree(cell, other) { continue }
                if let cell, let other, index < ledgerKeys.count,
                   agreeAcrossSpellings(cell, other, columnKey: ledgerKeys[index]) { continue }
                rowDiffers = true
                if differences.count < maximumReportedDifferences {
                    differences.append(Difference(
                        markupID: markupID,
                        columnKey: index < ledgerKeys.count ? ledgerKeys[index] : "#\(index + 1)",
                        columnTitle: index < titles.count ? titles[index] : "#\(index + 1)",
                        inFile: cell.map(describe) ?? missingCellText,
                        inLedger: other.map(describe) ?? missingCellText
                    ))
                }
            }
            if rowDiffers { differing += 1 } else { identical += 1 }
        }

        return ZenitLedgerReconciliation(
            rowsIdentical: identical,
            rowsDiffering: differing,
            rowsOnlyInFile: left.keys.filter { right[$0] == nil }.sorted(),
            rowsOnlyInLedger: right.keys.filter { left[$0] == nil }.sorted(),
            differences: differences,
            columnMismatch: nil
        )
    }

    // MARK: - Members

    /// Every row in the document, grouped or not, keyed by markup identity.
    ///
    /// A duplicate identity keeps the first occurrence: two rows claiming one markup is a
    /// malformed export, and ``ZenitInterchangeImport`` has no rule that rejects it today —
    /// silently overwriting would make the comparison depend on traversal order.
    /// Public because the application's round-trip gate compares the two documents cell by cell
    /// itself, rather than trusting the verdict this type computed.
    public static func flatten(
        _ document: ZenitInterchangeDocument
    ) -> [String: ZenitInterchangeDocument.Row] {
        Dictionary(orderedRows(document), uniquingKeysWith: { first, _ in first })
    }

    /// Every row in document order — flat rows, then each group's rows depth first — with a
    /// duplicate identity keeping its first occurrence, as ``flatten(_:)`` does.
    static func orderedRows(
        _ document: ZenitInterchangeDocument
    ) -> [(String, ZenitInterchangeDocument.Row)] {
        var seen = Set<String>()
        var rows: [(String, ZenitInterchangeDocument.Row)] = []
        func take(_ row: ZenitInterchangeDocument.Row) {
            if seen.insert(row.markupID).inserted { rows.append((row.markupID, row)) }
        }
        func walk(_ groups: [ZenitInterchangeDocument.Group]) {
            for group in groups {
                group.rows.forEach(take)
                walk(group.groups)
            }
        }
        document.rows.forEach(take)
        walk(document.groups)
        return rows
    }

    /// What the difference list says for a cell one of the two rows does not have.
    static var missingCellText: String {
        NSLocalizedString(
            "(no cell)",
            comment: "Reconciliation: a row in one ledger has fewer cells than the same row in the other"
        )
    }

    /// Two cells agree when they carry the same value. For a number that is the exact `raw`
    /// decimal and the *dimension* its unit names; the localized `display` and the display unit
    /// are renderings, not values.
    ///
    /// `raw` is in SI base units whatever the column was shown in, so one takeoff exported once
    /// in millimetres and once in metres carries the same `raw` under `mm` and `m`. Comparing
    /// the symbols reported every such cell as differing (BH-133). The dimension still counts:
    /// `2` metres and `2` square metres are not the same quantity, and neither are 100 SEK and
    /// 100 EUR.
    static func agree(
        _ left: ZenitInterchangeDocument.Cell,
        _ right: ZenitInterchangeDocument.Cell
    ) -> Bool {
        switch (left, right) {
        case (.number(let a), .number(let b)):
            return sameValue(a.raw, b.raw) && baseUnit(of: a.unit) == baseUnit(of: b.unit)
        default:
            return left == right
        }
    }

    /// Two presentation cells that say the same thing in an older export's spelling (L-46).
    ///
    /// Since L-46 every export writes the Type cell as the ledger shows it — "Rectangle Area",
    /// "ƒ Area" — and the Unit cell filled. A file written before that says `rectangleArea` and
    /// leaves Unit blank, and holding it against today's ledger reported every row as differing
    /// in two columns nobody changed. A Type agrees when its letters agree, case aside; a Unit
    /// agrees when either side is blank. Every other column is compared as it always was.
    static func agreeAcrossSpellings(
        _ left: ZenitInterchangeDocument.Cell,
        _ right: ZenitInterchangeDocument.Cell,
        columnKey: String
    ) -> Bool {
        switch columnKey {
        case StandardLedgerColumn.icon.rawValue:
            guard case .text(let a) = left, case .text(let b) = right else { return false }
            func letters(_ text: String) -> String {
                String(text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init)).lowercased()
            }
            return !letters(a).isEmpty && letters(a) == letters(b)
        case StandardLedgerColumn.displayUnit.rawValue:
            return left == .blank || right == .blank
        default:
            return false
        }
    }

    /// Equal as decimals — `0.50` and `0.5` are one value — falling back to the strings when
    /// either is not a decimal at all.
    static func sameValue(_ left: String, _ right: String) -> Bool {
        guard let a = Decimal(string: left, locale: Locale(identifier: "en_US_POSIX")),
              let b = Decimal(string: right, locale: Locale(identifier: "en_US_POSIX"))
        else { return left == right }
        return a == b
    }

    /// The SI base unit a display symbol belongs to: `m` for `mm`, `ft` and `in`; `m^2` for
    /// `m²` and `ft²`; `rad` for `°`. A symbol that is not a display unit — a base symbol, a
    /// currency code — is its own base; the empty symbol of a count is the dimensionless `1`.
    static func baseUnit(of symbol: String) -> String {
        if symbol.isEmpty { return QuantityDimension.count.baseUnitSymbol }
        return baseUnitsBySymbol[symbol] ?? symbol
    }

    private static let baseUnitsBySymbol: [String: String] = {
        var table: [String: String] = [:]
        func add<Unit: DisplayUnit>(_ family: Unit.Type) {
            for unit in Unit.allCases where table[unit.symbol] == nil {
                table[unit.symbol] = Unit.dimension.baseUnitSymbol
            }
        }
        add(LengthUnit.self)
        add(AreaUnit.self)
        add(VolumeUnit.self)
        add(AngleUnit.self)
        return table
    }()

    static func describe(_ cell: ZenitInterchangeDocument.Cell) -> String {
        switch cell {
        case .blank: return ""
        case .text(let text): return text
        case .boolean(let flag): return flag ? "true" : "false"
        case .date(let iso): return iso
        case .refusal(let token): return token
        case .number(let number):
            // The exact stored value in the unit it is stored in, then what the person saw — the
            // display value in the display unit. `raw` is SI base: labelling it with the display
            // symbol printed a 12.5 mm length as "0.0125 mm" (BH-134). The stored value leads
            // because two cells can differ below the display precision and read alike.
            let shown = number.unit.isEmpty ? number.display : number.display + " " + number.unit
            let base = baseUnit(of: number.unit)
            let stored = base == QuantityDimension.count.baseUnitSymbol
                ? number.raw
                : number.raw + " " + base
            return shown == stored || shown.isEmpty ? stored : "\(stored) (\(shown))"
        }
    }
}
