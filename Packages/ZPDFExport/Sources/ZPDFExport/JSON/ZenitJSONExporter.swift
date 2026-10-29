import Foundation

/// Writes a ``ZenitInterchangeDocument`` as `.zpdfjson`.
///
/// The key order of every object in the file is the order of the `append` calls below. That is
/// the whole mechanism: there is no dictionary anywhere between the projection and the bytes.
public struct ZenitJSONExporter: Sendable {

    public init() {}

    public func export(_ projection: ExportProjection) -> Data {
        encode(document(from: projection))
    }

    public func encode(_ document: ZenitInterchangeDocument) -> Data {
        JSONWriter.data(json(document))
    }

    // MARK: - Projection to document

    public func document(from projection: ExportProjection) -> ZenitInterchangeDocument {
        let table = projection.table
        let metadata = table.metadata
        return ZenitInterchangeDocument(
            schemaVersion: ZenitInterchangeDocument.currentSchemaVersion,
            generatedAt: metadata.generatedAt.iso8601,
            producer: .init(
                application: "Zenit PDF",
                package: "ZPDFExport",
                ledgerContractVersion: metadata.ledgerContractVersion,
                formulaGrammarVersion: metadata.formulaGrammarVersion
            ),
            document: .init(
                projectName: metadata.document.projectName,
                documentName: metadata.document.documentName,
                revision: metadata.document.revision,
                scaleDescription: metadata.document.scaleDescription,
                unitsDescription: metadata.document.unitsDescription,
                preparedBy: metadata.document.preparedBy,
                notes: metadata.document.notes
            ),
            ledger: .init(
                title: metadata.title,
                grouping: metadata.groupingColumnKeys,
                sort: metadata.sortDescription,
                filter: metadata.filterDescription,
                rowCount: metadata.rowCount,
                rowCountBeforeFilter: metadata.totalRowCountBeforeFilter,
                staleScaleNotice: metadata.staleScaleNotice
            ),
            numberLocale: .init(
                identifier: projection.numberLocale.identifier,
                decimalSeparator: projection.numberLocale.decimalSeparator,
                groupingSeparator: projection.numberLocale.groupingSeparator
            ),
            columns: table.columns.map {
                .init(
                    key: $0.key,
                    title: $0.title,
                    kind: $0.kind.rawValue,
                    unit: $0.unitSymbol,
                    decimalPlaces: $0.decimalPlaces,
                    numberFormat: $0.numberFormatCode,
                    aggregationSemantics: $0.aggregationSemantics,
                    formula: $0.formulaCanonicalText
                )
            },
            groups: table.groups.map {
                Self.convert($0, labelProvenance: table.carriesProvenanceLabels)
            },
            rows: table.rows.map {
                Self.convert($0, labelProvenance: table.carriesProvenanceLabels)
            },
            grandTotals: table.grandTotals.map(Self.convert)
        )
    }

    private static func convert(
        _ group: ExportGroup,
        labelProvenance: Bool
    ) -> ZenitInterchangeDocument.Group {
        .init(
            token: group.token,
            label: group.label,
            depth: group.depth,
            rowCount: group.rowCount,
            path: group.path,
            subtotals: group.subtotals.map(convert),
            rows: group.rows.map { convert($0, labelProvenance: labelProvenance) },
            groups: group.subgroups.map { convert($0, labelProvenance: labelProvenance) }
        )
    }

    /// Internal rather than private because the `.zpdfoverlay` writer reuses this exact row
    /// encoding (feature 6). There is one record codec in this package and this is it.
    ///
    /// `labelProvenance` is ``ExportTable/carriesProvenanceLabels``: when the table carries a
    /// derived or read row, **every** row of the file states its claim — the measured ones too,
    /// so a mixed file has no unlabelled row (ADR-0012 rule 4). When it does not, the key is
    /// omitted everywhere and the document is byte for byte what this writer always produced.
    static func convert(_ row: ExportRow, labelProvenance: Bool) -> ZenitInterchangeDocument.Row {
        .init(
            markupID: row.markupID,
            index: row.storeIndex,
            groupPath: row.groupPath,
            cells: row.cells.map(convert),
            provenance: labelProvenance ? row.provenance : nil,
            trace: row.trace.map(convert),
            keptUnderOlderScale: row.keptUnderOlderScale
        )
    }

    static func convert(_ trace: ExportRowTrace) -> ZenitInterchangeDocument.Trace {
        .init(
            sheet: trace.sheetLabel,
            // `scaleText`, not `scaleAtMeasureTime`: the file carries the resolved answer, and
            // the resolved answer for "not recoverable" is the word, not a null a reader would
            // be tempted to replace with the current scale.
            scale: trace.scaleText,
            scaleRegion: trace.scaleRegionLabel,
            created: trace.createdAt?.iso8601,
            measured: trace.measuredAt?.iso8601,
            author: trace.author,
            capture: trace.capture
        )
    }

    private static func convert(_ total: ExportTotalRow) -> ZenitInterchangeDocument.TotalRow {
        .init(function: total.function, cells: total.cells.map(convert))
    }

    static func convert(_ cell: ExportCell) -> ZenitInterchangeDocument.Cell {
        switch cell {
        case .blank: .blank
        case .text(let text): .text(text)
        case .boolean(let flag): .boolean(flag)
        case .date(let value): .date(value.iso8601)
        case .refusal(let token): .refusal(token)
        case .number(let number):
            .number(.init(
                raw: number.invariantRawText,
                display: number.text,
                unit: number.unitSymbol
            ))
        }
    }

    // MARK: - Document to JSON

    func json(_ document: ZenitInterchangeDocument) -> JSONValue {
        .object([
            ("format", .string(ZenitInterchangeDocument.formatIdentifier)),
            ("schemaVersion", .integer(document.schemaVersion)),
            ("generatedAt", .string(document.generatedAt)),
            ("producer", .object([
                ("application", .string(document.producer.application)),
                ("package", .string(document.producer.package)),
                ("ledgerContractVersion", .integer(document.producer.ledgerContractVersion)),
                ("formulaGrammarVersion", .integer(document.producer.formulaGrammarVersion))
            ])),
            ("document", .object([
                ("projectName", optional(document.document.projectName)),
                ("documentName", optional(document.document.documentName)),
                ("revision", optional(document.document.revision)),
                ("scaleDescription", optional(document.document.scaleDescription)),
                ("unitsDescription", optional(document.document.unitsDescription)),
                ("preparedBy", optional(document.document.preparedBy)),
                ("notes", optional(document.document.notes))
            ])),
            ("ledger", .object(Self.ledgerPairs(document.ledger))),
            ("numberLocale", .object([
                ("identifier", .string(document.numberLocale.identifier)),
                ("decimalSeparator", .string(document.numberLocale.decimalSeparator)),
                ("groupingSeparator", optional(document.numberLocale.groupingSeparator))
            ])),
            ("columns", .array(document.columns.map(Self.json))),
            ("groups", .array(document.groups.map(Self.json))),
            ("rows", .array(document.rows.map(Self.json))),
            ("grandTotals", .array(document.grandTotals.map(Self.json)))
        ])
    }

    /// The ledger object's members; the stale-scale notice is its conditional tail (K-04).
    private static func ledgerPairs(_ ledger: ZenitInterchangeDocument.LedgerInfo) -> [(key: String, value: JSONValue)] {
        var pairs: [(key: String, value: JSONValue)] = [
            ("title", .string(ledger.title)),
            ("grouping", .array(ledger.grouping.map(JSONValue.string))),
            ("sort", .array(ledger.sort.map(JSONValue.string))),
            ("filter", .string(ledger.filter)),
            ("rowCount", .integer(ledger.rowCount)),
            ("rowCountBeforeFilter", .integer(ledger.rowCountBeforeFilter))
        ]
        if let notice = ledger.staleScaleNotice { pairs.append(("staleScaleNotice", .string(notice))) }
        return pairs
    }

    private func optional(_ text: String?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }

    static func json(_ column: ZenitInterchangeDocument.Column) -> JSONValue {
        .object([
            ("key", .string(column.key)),
            ("title", .string(column.title)),
            ("kind", .string(column.kind)),
            ("unit", .string(column.unit)),
            ("decimalPlaces", column.decimalPlaces.map(JSONValue.integer) ?? .null),
            ("numberFormat", column.numberFormat.map(JSONValue.string) ?? .null),
            ("aggregationSemantics", column.aggregationSemantics.map(JSONValue.string) ?? .null),
            ("formula", column.formula.map(JSONValue.string) ?? .null)
        ])
    }

    private static func json(_ group: ZenitInterchangeDocument.Group) -> JSONValue {
        .object([
            ("token", .string(group.token)),
            ("label", .string(group.label)),
            ("depth", .integer(group.depth)),
            ("rowCount", .integer(group.rowCount)),
            ("path", .array(group.path.map(JSONValue.string))),
            ("subtotals", .array(group.subtotals.map(json))),
            ("rows", .array(group.rows.map(json))),
            ("groups", .array(group.groups.map(json)))
        ])
    }

    static func json(_ row: ZenitInterchangeDocument.Row) -> JSONValue {
        var pairs: [(key: String, value: JSONValue)] = [
            ("markupID", .string(row.markupID)),
            ("index", .integer(row.index)),
            ("groupPath", .array(row.groupPath.map(JSONValue.string))),
            ("cells", .array(row.cells.map(json)))
        ]
        // Provenance before the trace, so the trace stays the row object's conditional tail —
        // the same order the CSV columns keep.
        if let provenance = row.provenance { pairs.append(("provenance", .string(provenance))) }
        if row.keptUnderOlderScale { pairs.append(("keptUnderOlderScale", .boolean(true))) }
        if let trace = row.trace { pairs.append(("trace", json(trace))) }
        return .object(pairs)
    }

    static func json(_ trace: ZenitInterchangeDocument.Trace) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [
            ("sheet", .string(trace.sheet)),
            ("scale", .string(trace.scale)),
            ("scaleRegion", trace.scaleRegion.map(JSONValue.string) ?? .null),
            ("created", trace.created.map(JSONValue.string) ?? .null),
            ("measured", trace.measured.map(JSONValue.string) ?? .null),
            ("author", .string(trace.author))
        ]
        // ADR-0031: only when known, so an older file re-exports byte for byte.
        if let capture = trace.capture { members.append(("capture", .string(capture))) }
        return .object(members)
    }

    private static func json(_ total: ZenitInterchangeDocument.TotalRow) -> JSONValue {
        .object([
            ("function", .string(total.function)),
            ("cells", .array(total.cells.map(json)))
        ])
    }

    static func json(_ cell: ZenitInterchangeDocument.Cell) -> JSONValue {
        switch cell {
        case .blank:
            .object([("type", .string("blank"))])
        case .text(let text):
            .object([("type", .string("text")), ("value", .string(text))])
        case .boolean(let flag):
            .object([("type", .string("boolean")), ("value", .boolean(flag))])
        case .date(let iso):
            .object([("type", .string("date")), ("value", .string(iso))])
        case .refusal(let token):
            .object([("type", .string("refusal")), ("token", .string(token))])
        case .number(let number):
            .object([
                ("type", .string("number")),
                ("raw", .string(number.raw)),
                ("display", .string(number.display)),
                ("unit", .string(number.unit))
            ])
        }
    }
}
