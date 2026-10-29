import Foundation

/// The Zenit interchange document — the in-memory shape of a `.zpdfjson` file.
///
/// # Why this exists rather than `Codable` on the projection
///
/// A file format is a promise. `Codable` synthesised from an internal type turns every rename,
/// every reordered property and every new case into a silent format change. This type is written
/// out by hand, in a declared key order, with a schema version, so changing the file format
/// requires editing the file format.
///
/// # The rules the format keeps
///
/// - **Versioned.** ``schemaVersion`` is the first thing a reader checks.
/// - **Stable key order.** Objects are emitted in the order declared in ``ZenitJSONExporter``,
///   not alphabetically and not by hash. Two exports of the same projection are byte-identical
///   (QUALITY_BAR A34).
/// - **ISO-8601 dates**, UTC, second resolution, always.
/// - **Decimals as strings.** Every quantity, raw or displayed, is a JSON string. A JSON number
///   is parsed into a binary `double` by almost every consumer on earth, which silently destroys
///   the exactness the whole ledger is built to preserve. Integers — counts, versions, indices —
///   are JSON numbers, because they are exact in a double and because making them strings would
///   be theatre.
public struct ZenitInterchangeDocument: Hashable, Sendable {

    public static let formatIdentifier = "zenit.ledger.export"
    public static let currentSchemaVersion = 1
    public static let fileExtension = "zpdfjson"

    public struct Producer: Hashable, Sendable {
        public let application: String
        public let package: String
        public let ledgerContractVersion: Int
        public let formulaGrammarVersion: Int
    }

    public struct DocumentInfo: Hashable, Sendable {
        public let projectName: String?
        public let documentName: String?
        public let revision: String?
        public let scaleDescription: String?
        public let unitsDescription: String?
        public let preparedBy: String?
        public let notes: String?
    }

    public struct LedgerInfo: Hashable, Sendable {
        public let title: String
        public let grouping: [String]
        public let sort: [String]
        public let filter: String
        public let rowCount: Int
        public let rowCountBeforeFilter: Int
        /// ``ExportMetadata/staleScaleNotice``: written as `"staleScaleNotice"` only when some row
        /// was kept under an older scale (K-04), so every other document is byte for byte the
        /// file this format has always been.
        public let staleScaleNotice: String?

        init(title: String, grouping: [String], sort: [String], filter: String, rowCount: Int,
             rowCountBeforeFilter: Int, staleScaleNotice: String? = nil) {
            self.title = title
            self.grouping = grouping
            self.sort = sort
            self.filter = filter
            self.rowCount = rowCount
            self.rowCountBeforeFilter = rowCountBeforeFilter
            self.staleScaleNotice = staleScaleNotice
        }
    }

    public struct NumberLocaleInfo: Hashable, Sendable {
        public let identifier: String
        public let decimalSeparator: String
        public let groupingSeparator: String?
    }

    public struct Column: Hashable, Sendable {
        public let key: String
        public let title: String
        public let kind: String
        public let unit: String
        public let decimalPlaces: Int?
        public let numberFormat: String?
        public let aggregationSemantics: String?
        public let formula: String?
    }

    public struct Number: Hashable, Sendable {
        /// The exact stored value in SI base units, as an invariant decimal string.
        public let raw: String
        /// The single-rounded value in the display unit, rendered in the export's number locale.
        /// Present so a reader can reproduce what the user saw without re-deriving it; a reader
        /// reconstructing values uses ``raw`` (QUALITY_BAR A32 keeps raw authoritative).
        public let display: String
        public let unit: String
    }

    public enum Cell: Hashable, Sendable {
        case blank
        case text(String)
        case number(Number)
        case date(String)
        case boolean(Bool)
        case refusal(String)
    }

    /// Row provenance (feature 16). Written as a `"trace"` object **after** `"cells"`, and only
    /// on rows that have one, so a document exported from an untraced projection is byte for
    /// byte the document this writer has always produced.
    ///
    /// ``scale`` is already resolved: it is the scale the measurement was taken under, or the
    /// literal `"unknown"`. It is never the scale in force at export time.
    public struct Trace: Hashable, Sendable {
        public let sheet: String
        public let scale: String
        public let scaleRegion: String?
        /// ISO-8601, UTC, second resolution — the same spelling as every other date in the file.
        public let created: String?
        public let measured: String?
        public let author: String
        /// How the geometry was captured, in words (ADR-0031). Written as `"capture"` after
        /// `"author"` only when known, so a file without it is byte for byte what it was.
        public var capture: String? = nil
    }

    public struct Row: Hashable, Sendable {
        public let markupID: String
        public let index: Int
        public let groupPath: [String]
        public let cells: [Cell]
        /// What kind of claim this row's quantity makes (ADR-0012 rule 4): `"measured"`,
        /// `"derived"` or `"read"`. Written as a `"provenance"` key after `"cells"`, on every
        /// row of a document whose ledger carries a derived or read row — the measured rows
        /// included, so a mixed file has no unlabelled row for a reader to guess at. Absent
        /// from a pure-measured document, which therefore stays byte for byte the file this
        /// format has always been, and absent reads back as the measured claim, exactly as an
        /// absent key in stored project JSON does.
        public let provenance: String?
        public let trace: Trace?
        /// ``ExportRow/keptUnderOlderScale``: `"keptUnderOlderScale": true` after the provenance,
        /// on such rows only (K-04).
        public let keptUnderOlderScale: Bool

        /// Declared (rather than memberwise) so `provenance` can default for construction
        /// sites that predate ADR-0012.
        init(
            markupID: String,
            index: Int,
            groupPath: [String],
            cells: [Cell],
            provenance: String? = nil,
            trace: Trace? = nil,
            keptUnderOlderScale: Bool = false
        ) {
            self.markupID = markupID
            self.index = index
            self.groupPath = groupPath
            self.cells = cells
            self.provenance = provenance
            self.trace = trace
            self.keptUnderOlderScale = keptUnderOlderScale
        }
    }

    public struct TotalRow: Hashable, Sendable {
        public let function: String
        public let cells: [Cell]
    }

    public struct Group: Hashable, Sendable {
        public let token: String
        public let label: String
        public let depth: Int
        public let rowCount: Int
        public let path: [String]
        public let subtotals: [TotalRow]
        public let rows: [Row]
        public let groups: [Group]
    }

    public let schemaVersion: Int
    public let generatedAt: String
    public let producer: Producer
    public let document: DocumentInfo
    public let ledger: LedgerInfo
    public let numberLocale: NumberLocaleInfo
    public let columns: [Column]
    public let groups: [Group]
    public let rows: [Row]
    public let grandTotals: [TotalRow]
}
