import Foundation
import ZPDFContracts

/// The door a `.zpdfjson` file coming from outside this process comes through.
///
/// # Why this exists beside ``ZenitJSONImporter``
///
/// ``ZenitJSONImporter`` is a *parser*: it turns bytes into a ``ZenitInterchangeDocument`` and
/// refuses anything it cannot read. That is necessary and it is not sufficient. A file can parse
/// perfectly and still be a lie — a row with four cells against six columns, a `rowCount` of 12
/// over 4 000 rows, a `raw` of `"NaN"`, a group nested ten thousand deep. Every one of those
/// parses. Every one of those would be believed by whatever read the parsed document next.
///
/// So this type is the boundary: **bytes in, a checked document and a review out, and nothing
/// partially validated in between.** The caller cannot obtain the document without the checks
/// having run, because the checks are inside the only function that returns one.
///
/// # What "untrusted" means here, concretely
///
/// A `.zpdfjson` arrives by e-mail from an estimator at another firm. It is data, never a
/// program, and this package has no code path that executes anything it contains. The remaining
/// risks are the boring ones that actually happen:
///
/// - **Resource exhaustion.** A 3 GB file, or a hundred thousand groups nested inside each
///   other, must be refused before it is parsed, not after. ``maximumByteCount`` and
///   ``maximumNestingDepth`` do that.
/// - **Silent misreading.** A quantity that is not a decimal, a count that disagrees with the
///   rows it counts, a row whose cells do not line up with the columns. Believing any of those
///   produces a wrong number in a bid, which is this product's worst possible failure.
/// - **Version drift.** A file written by a future build is refused by name and number
///   (``ExportError/unsupportedSchemaVersion(found:supported:)``), never guessed at.
///
/// # What an import does *not* do
///
/// It does not merge anything into the open project, and it could not: a `.zpdfjson` is a
/// *ledger* — rows, cells and totals — and carries no geometry, no page, no scale and no vertex.
/// The markups that produced those numbers are not in the file. Reconstructing a takeoff from it
/// is not a feature that was skipped; it is arithmetic that does not exist. What the format is
/// good for is reading a delivered ledger back and holding it against your own, which is what
/// ``ZenitLedgerReconciliation`` does.
public enum ZenitInterchangeImport: Sendable {

    /// The largest file this build will parse. A ledger of a million rows encodes to roughly
    /// 300 MB, so 512 MiB is generous for anything real and still bounded.
    public static let maximumByteCount = 512 * 1024 * 1024

    /// The deepest group nesting accepted. Real ledgers group by three or four keys; anything
    /// past this is either corruption or an attempt to recurse a reader into the ground.
    public static let maximumNestingDepth = 64

    /// The most rows accepted, counting rows inside groups.
    public static let maximumRowCount = 2_000_000

    /// Reads, validates and reviews one `.zpdfjson` payload.
    ///
    /// - Parameters:
    ///   - data: the file's bytes, exactly as read from disk.
    ///   - fileName: the file's display name, carried into the review so the sheet can name it.
    /// - Returns: the checked document and a summary of what is in it.
    /// - Throws: ``ExportError`` — every rejection names the path or the rule that was broken,
    ///   because "the file is invalid" is not something a person can act on.
    public static func read(
        _ data: Data,
        fileName: String
    ) throws -> (document: ZenitInterchangeDocument, review: ZenitImportReview) {
        guard !data.isEmpty else {
            throw ExportError.malformedInterchange("the file is empty")
        }
        guard data.count <= maximumByteCount else {
            throw ExportError.interchangeTooLarge(bytes: data.count, limit: maximumByteCount)
        }
        // The parser checks the format identifier and the schema version before anything else,
        // and throws `unsupportedSchemaVersion` by name for a version this build cannot read.
        let document = try ZenitJSONImporter().document(from: data)
        try validate(document)
        return (document, ZenitImportReview(document, fileName: fileName, byteCount: data.count))
    }

    /// Everything that has to be true of a parsed document before anything is allowed to believe
    /// it. Public so a test can aim one rule at a time.
    public static func validate(_ document: ZenitInterchangeDocument) throws {
        guard document.schemaVersion == ZenitInterchangeDocument.currentSchemaVersion else {
            throw ExportError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                supported: ZenitInterchangeDocument.currentSchemaVersion
            )
        }
        guard !document.columns.isEmpty else {
            throw ExportError.malformedInterchange("\"columns\" is empty; a ledger has columns")
        }
        var seenKeys = Set<String>()
        for column in document.columns {
            guard !column.key.isEmpty else {
                throw ExportError.malformedInterchange("a column has an empty \"key\"")
            }
            guard seenKeys.insert(column.key).inserted else {
                throw ExportError.malformedInterchange("two columns share the key \"\(column.key)\"")
            }
            if let places = column.decimalPlaces, places < 0 || places > 15 {
                throw ExportError.malformedInterchange(
                    "column \"\(column.key)\" declares \(places) decimal places"
                )
            }
        }
        let width = document.columns.count

        guard document.ledger.rowCount >= 0, document.ledger.rowCountBeforeFilter >= 0 else {
            throw ExportError.malformedInterchange("\"ledger\" declares a negative row count")
        }
        guard document.ledger.rowCountBeforeFilter >= document.ledger.rowCount else {
            throw ExportError.malformedInterchange(
                "\"ledger.rowCountBeforeFilter\" (\(document.ledger.rowCountBeforeFilter)) is "
                    + "below \"ledger.rowCount\" (\(document.ledger.rowCount)); a filter removes "
                    + "rows, it does not add them"
            )
        }
        guard isISO8601(document.generatedAt) else {
            throw ExportError.malformedInterchange(
                "\"generatedAt\" is not an ISO-8601 UTC instant: \"\(document.generatedAt)\""
            )
        }

        var counted = 0
        for row in document.rows { try check(row, width: width, counted: &counted) }
        for total in document.grandTotals { try check(total, width: width) }
        for group in document.groups {
            try check(group, width: width, depth: 0, counted: &counted)
        }
        guard counted <= maximumRowCount else {
            throw ExportError.malformedInterchange(
                "\(counted) rows exceeds the \(maximumRowCount)-row ceiling this build reads"
            )
        }
        // The declared count and the delivered rows must agree. A file that says 12 and carries
        // 4 000 is a file whose totals cannot be trusted, and a total nobody can trust is worse
        // than no file at all.
        guard counted == document.ledger.rowCount else {
            throw ExportError.malformedInterchange(
                "\"ledger.rowCount\" is \(document.ledger.rowCount) and the file carries "
                    + "\(counted) row(s)"
            )
        }
    }

    // MARK: - Members

    private static func check(
        _ group: ZenitInterchangeDocument.Group,
        width: Int,
        depth: Int,
        counted: inout Int
    ) throws {
        guard depth < maximumNestingDepth else {
            throw ExportError.malformedInterchange(
                "groups are nested deeper than \(maximumNestingDepth)"
            )
        }
        guard group.depth >= 0 else {
            throw ExportError.malformedInterchange("group \"\(group.token)\" has a negative depth")
        }
        guard group.rowCount >= 0 else {
            throw ExportError.malformedInterchange(
                "group \"\(group.token)\" declares \(group.rowCount) rows"
            )
        }
        var inner = 0
        for row in group.rows { try check(row, width: width, counted: &inner) }
        for total in group.subtotals { try check(total, width: width) }
        for child in group.groups {
            try check(child, width: width, depth: depth + 1, counted: &inner)
        }
        guard inner == group.rowCount else {
            throw ExportError.malformedInterchange(
                "group \"\(group.token)\" declares \(group.rowCount) rows and carries \(inner)"
            )
        }
        counted += inner
    }

    private static func check(
        _ row: ZenitInterchangeDocument.Row,
        width: Int,
        counted: inout Int
    ) throws {
        guard row.cells.count == width else {
            throw ExportError.malformedInterchange(
                "row \"\(row.markupID)\" has \(row.cells.count) cells against \(width) columns"
            )
        }
        guard row.index >= 0 else {
            throw ExportError.malformedInterchange("row \"\(row.markupID)\" has index \(row.index)")
        }
        // A quantity's claim is one of exactly three things (ADR-0012). A row claiming a
        // fourth would be believed by whatever reads the document next, so it is refused by
        // name — the frozen contract's enum is the authority on what the three are.
        if let provenance = row.provenance, QuantityProvenance(rawValue: provenance) == nil {
            throw ExportError.malformedInterchange(
                "row \"\(row.markupID)\" claims the provenance \"\(provenance)\"; a quantity "
                    + "is measured, derived, or read"
            )
        }
        for cell in row.cells { try check(cell, at: row.markupID) }
        counted += 1
    }

    private static func check(_ total: ZenitInterchangeDocument.TotalRow, width: Int) throws {
        guard total.cells.count == width else {
            throw ExportError.malformedInterchange(
                "total \"\(total.function)\" has \(total.cells.count) cells against \(width) columns"
            )
        }
        for cell in total.cells { try check(cell, at: "total " + total.function) }
    }

    private static func check(_ cell: ZenitInterchangeDocument.Cell, at path: String) throws {
        switch cell {
        case .blank, .text, .boolean:
            return
        case .refusal(let token):
            guard !token.isEmpty else {
                throw ExportError.malformedInterchange("\(path): a refusal cell has no token")
            }
        case .date(let iso):
            guard isISO8601(iso) else {
                throw ExportError.malformedInterchange(
                    "\(path): \"\(iso)\" is not an ISO-8601 UTC instant"
                )
            }
        case .number(let number):
            // The whole point of the format is that `raw` is an exact decimal string. A `raw`
            // that is not one — "NaN", "1e400", "12,5", "" — must never be read as a quantity.
            guard isInvariantDecimal(number.raw) else {
                throw ExportError.malformedInterchange(
                    "\(path): \"\(number.raw)\" is not an invariant decimal"
                )
            }
        }
    }

    /// The exact grammar the exporter writes: an optional `-`, digits, optionally a `.` and more
    /// digits. No exponent, no separator, no locale, no leading `+`, no whitespace.
    ///
    /// Hand-written rather than delegated to `Decimal(string:)`, which accepts `"1e5"`, accepts a
    /// locale's separators and returns `NaN` rather than `nil` for some inputs — three ways to
    /// read a number that is not there.
    static func isInvariantDecimal(_ text: String) -> Bool {
        var scalars = Substring(text)
        if scalars.first == "-" { scalars = scalars.dropFirst() }
        guard !scalars.isEmpty else { return false }
        let parts = scalars.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return false
            }
        }
        // A ledger digit string long enough to be a denial-of-service is not a quantity.
        return text.count <= 64
    }

    /// `yyyy-MM-dd'T'HH:mm:ss'Z'`, which is what ``Date/iso8601`` writes.
    static func isISO8601(_ text: String) -> Bool {
        let pattern: [Character] = Array("0000-00-00T00:00:00Z")
        // The length first, in UTF-8 bytes, which costs nothing: `Array(text)` of a 400 MB
        // string allocated some 6 GB of `Character`s before this check ran, inside the
        // validator whose job is refusing exhaustion before it happens (BH-511).
        guard text.utf8.count == pattern.count else { return false }
        let value = Array(text)
        guard value.count == pattern.count else { return false }
        for (index, expected) in pattern.enumerated() {
            if expected == "0" {
                guard value[index].isASCII, value[index].isNumber else { return false }
            } else {
                guard value[index] == expected else { return false }
            }
        }
        return true
    }
}

/// What a `.zpdfjson` file says it is, shown to the person before anything is done with it.
///
/// An imported Tool Set follows the same rule — *show what the file contains before trusting
/// it* — and the rule is no different for a ledger. The review is a value type with no AppKit
/// in it, so the sentences it produces can be asserted in a test rather than read off the
/// screen.
public struct ZenitImportReview: Hashable, Sendable {

    public let fileName: String
    public let byteCount: Int
    public let schemaVersion: Int
    public let generatedAt: String
    public let producerApplication: String
    public let producerPackage: String
    public let ledgerContractVersion: Int
    public let formulaGrammarVersion: Int
    public let projectName: String?
    public let documentName: String?
    public let preparedBy: String?
    public let ledgerTitle: String
    public let numberLocaleIdentifier: String
    public let columnTitles: [String]
    public let rowCount: Int
    public let rowCountBeforeFilter: Int
    public let groupCount: Int
    public let grandTotalCount: Int

    init(_ document: ZenitInterchangeDocument, fileName: String, byteCount: Int) {
        self.fileName = fileName
        self.byteCount = byteCount
        self.schemaVersion = document.schemaVersion
        self.generatedAt = document.generatedAt
        self.producerApplication = document.producer.application
        self.producerPackage = document.producer.package
        self.ledgerContractVersion = document.producer.ledgerContractVersion
        self.formulaGrammarVersion = document.producer.formulaGrammarVersion
        self.projectName = document.document.projectName
        self.documentName = document.document.documentName
        self.preparedBy = document.document.preparedBy
        self.ledgerTitle = document.ledger.title
        self.numberLocaleIdentifier = document.numberLocale.identifier
        self.columnTitles = document.columns.map(\.title)
        self.rowCount = document.ledger.rowCount
        self.rowCountBeforeFilter = document.ledger.rowCountBeforeFilter
        self.groupCount = ZenitImportReview.countGroups(document.groups)
        self.grandTotalCount = document.grandTotals.count
    }

    private static func countGroups(_ groups: [ZenitInterchangeDocument.Group]) -> Int {
        groups.reduce(0) { $0 + 1 + countGroups($1.groups) }
    }

    /// The review as labelled lines, in the order a person reads them.
    ///
    /// Returned as pairs rather than as one formatted block so the caller decides the layout and
    /// a test can assert a single field without matching prose.
    public var fields: [(label: String, value: String)] {
        var rows: [(String, String)] = [
            (NSLocalizedString("File", comment: "Import review field"), fileName),
            (
                NSLocalizedString("Written by", comment: "Import review field"),
                "\(producerApplication) (\(producerPackage))"
            ),
            (NSLocalizedString("Written at", comment: "Import review field"), generatedAt),
            (
                NSLocalizedString("Schema version", comment: "Import review field"),
                String(schemaVersion)
            ),
            (NSLocalizedString("Ledger", comment: "Import review field"), ledgerTitle)
        ]
        if let projectName, !projectName.isEmpty {
            rows.append((NSLocalizedString("Project", comment: "Import review field"), projectName))
        }
        if let documentName, !documentName.isEmpty {
            rows.append((
                NSLocalizedString("Drawing", comment: "Import review field"), documentName
            ))
        }
        if let preparedBy, !preparedBy.isEmpty {
            rows.append((
                NSLocalizedString("Prepared by", comment: "Import review field"), preparedBy
            ))
        }
        rows.append((
            NSLocalizedString("Rows", comment: "Import review field"),
            rowCount == rowCountBeforeFilter
                ? String(rowCount)
                : String(
                    format: NSLocalizedString(
                        "%1$d of %2$d (the export was filtered)",
                        comment: "Import review row count with a filter"
                    ),
                    rowCount,
                    rowCountBeforeFilter
                )
        ))
        rows.append((
            NSLocalizedString("Columns", comment: "Import review field"),
            columnTitles.joined(separator: ", ")
        ))
        rows.append((
            NSLocalizedString("Groups", comment: "Import review field"), String(groupCount)
        ))
        rows.append((
            NSLocalizedString("Number locale", comment: "Import review field"),
            numberLocaleIdentifier
        ))
        return rows
    }
}
