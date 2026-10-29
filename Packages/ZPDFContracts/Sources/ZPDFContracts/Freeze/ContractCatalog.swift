import Foundation

/// Builds the frozen contract documents from the Swift source in this package.
///
/// The catalogue is not a hand-written mirror of the types. Struct fields come from `Mirror`,
/// enum cases come from `allCases`, and unit factors come from the live `conversionFactors`
/// dictionaries. A property added to a contract struct without an annotation fails the freeze;
/// an annotation left behind by a removed property fails it too. The JSON therefore cannot drift
/// away from the code that the rest of the product compiles against.
public enum ContractCatalog: Sendable {

    /// What is written into every document's `generator` field.
    public static let generatorName = "zpdf-contract-freeze (ZPDFContracts v\(ContractVersion.architecture))"

    /// The seven contract file stems, in the order they are written.
    public static let documentNames = [
        "ARCHITECTURE_FREEZE",
        "MEASUREMENT_CONTRACT",
        "SCALE_CONTRACT",
        "SNAP_CONTRACT",
        "MARKUP_CONTRACT",
        "LEDGER_CONTRACT",
        "FORMULA_CONTRACT"
    ]

    /// Builds every contract document.
    ///
    /// - Parameter frozenAt: ISO 8601 timestamp, supplied by the caller. Nothing in here reads
    ///   the wall clock, so two runs at the same `frozenAt` produce byte-identical output.
    public static func allDocuments(frozenAt: String) throws -> [ContractDocument] {
        [
            try architectureFreeze(frozenAt: frozenAt),
            try measurementContract(frozenAt: frozenAt),
            try scaleContract(frozenAt: frozenAt),
            try snapContract(frozenAt: frozenAt),
            try markupContract(frozenAt: frozenAt),
            try ledgerContract(frozenAt: frozenAt),
            try formulaContract(frozenAt: frozenAt)
        ]
    }

    /// The encoder used for the freeze: sorted keys and pretty printing, so a diff between two
    /// freezes shows what actually changed.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Serialises one document.
    public static func encode(_ document: ContractDocument) throws -> Data {
        var data = try makeEncoder().encode(document)
        data.append(0x0A)
        return data
    }

    /// Writes every contract document into `directory`, creating it if needed.
    ///
    /// - Returns: the URLs written, in ``documentNames`` order.
    @discardableResult
    public static func write(
        to directory: URL,
        frozenAt: String,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for document in try allDocuments(frozenAt: frozenAt) {
            let url = directory.appendingPathComponent("\(document.contract).json")
            try encode(document).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    /// Formats a `Date` as the ISO 8601 timestamp used in `frozenAt`.
    ///
    /// The clock is the caller's, which is why this takes a `Date` rather than reading one.
    public static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
