import Foundation
import ZPDFContracts

/// Writes a ``ZenitOverlayDocument`` as `.zpdfoverlay`.
///
/// Key order is the order of the `append` calls, exactly as in ``ZenitJSONExporter``, and the row
/// and cell encodings *are* that exporter's — called, not copied.
public struct ZenitOverlayExporter: Sendable {

    public init() {}

    /// Builds an overlay from a projection and the geometry of the markups in it.
    ///
    /// - Parameter geometry: page-space geometry by markup UUID string. A markup with no entry
    ///   still exports its row; only its drawing is missing.
    public func document(
        from projection: ExportProjection,
        source: ZenitOverlayDocument.Source,
        geometry: [String: MeasurementGeometry] = [:],
        placements: [String: ZenitOverlayDocument.Placement] = [:]
    ) -> ZenitOverlayDocument {
        let table = projection.table
        return ZenitOverlayDocument(
            schemaVersion: ZenitOverlayDocument.currentSchemaVersion,
            generatedAt: table.metadata.generatedAt.iso8601,
            producer: .init(
                application: "Zenit PDF",
                package: "ZPDFExport",
                ledgerContractVersion: table.metadata.ledgerContractVersion,
                formulaGrammarVersion: table.metadata.formulaGrammarVersion
            ),
            source: source,
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
            numberLocale: .init(
                identifier: projection.numberLocale.identifier,
                decimalSeparator: projection.numberLocale.decimalSeparator,
                groupingSeparator: projection.numberLocale.groupingSeparator
            ),
            // `allRows()` rather than `rows`: a grouped view has its rows in the group tree, and
            // an overlay exported from a grouped ledger must carry all of them.
            measurements: table.allRows().map { row in
                .init(
                    row: ZenitJSONExporter.convert(
                        row, labelProvenance: table.carriesProvenanceLabels
                    ),
                    geometry: geometry[row.markupID],
                    placement: placements[row.markupID]
                )
            }
        )
    }

    public func export(
        _ projection: ExportProjection,
        source: ZenitOverlayDocument.Source,
        geometry: [String: MeasurementGeometry] = [:],
        placements: [String: ZenitOverlayDocument.Placement] = [:]
    ) -> Data {
        encode(document(from: projection, source: source, geometry: geometry, placements: placements))
    }

    public func encode(_ document: ZenitOverlayDocument) -> Data {
        JSONWriter.data(json(document))
    }

    func json(_ document: ZenitOverlayDocument) -> JSONValue {
        .object([
            ("format", .string(ZenitOverlayDocument.formatIdentifier)),
            ("schemaVersion", .integer(document.schemaVersion)),
            ("generatedAt", .string(document.generatedAt)),
            ("producer", .object([
                ("application", .string(document.producer.application)),
                ("package", .string(document.producer.package)),
                ("ledgerContractVersion", .integer(document.producer.ledgerContractVersion)),
                ("formulaGrammarVersion", .integer(document.producer.formulaGrammarVersion))
            ])),
            ("source", .object([
                ("fileName", .string(document.source.fileName)),
                ("pageCount", .integer(document.source.pageCount)),
                ("digest", .object([
                    ("algorithm", .string("SHA-256")),
                    ("sha256", .string(document.source.digestSHA256)),
                    ("byteCount", .integer(document.source.digestByteCount))
                ]))
            ])),
            ("numberLocale", .object([
                ("identifier", .string(document.numberLocale.identifier)),
                ("decimalSeparator", .string(document.numberLocale.decimalSeparator)),
                ("groupingSeparator", document.numberLocale.groupingSeparator
                    .map(JSONValue.string) ?? .null)
            ])),
            ("columns", .array(document.columns.map { ZenitJSONExporter.json($0) })),
            ("measurements", .array(document.measurements.map(Self.json)))
        ])
    }

    private static func json(_ measurement: ZenitOverlayDocument.Measurement) -> JSONValue {
        // The row object is `ZenitJSONExporter`'s, verbatim, nested under "row" so the overlay
        // can add geometry beside it without changing what a row is.
        var members: [(key: String, value: JSONValue)] = [
            ("row", ZenitJSONExporter.json(measurement.row)),
            ("geometry", measurement.geometry.map(OverlayGeometryCodec.json) ?? .null)
        ]
        // Only when present, so a document built without placements is byte for byte the file
        // this writer has always produced.
        if let placement = measurement.placement {
            var placementMembers: [(key: String, value: JSONValue)] = [
                ("pageIndex", .integer(placement.pageIndex)),
                ("tool", placement.tool.map(JSONValue.string) ?? .null),
                ("parameters", placement.parametersJSON.map(JSONValue.string) ?? .null)
            ]
            // L-47: only when present, so a placement without a style is the bytes it always was.
            if let style = placement.styleJSON { placementMembers.append(("style", .string(style))) }
            members.append(("placement", .object(placementMembers)))
        }
        return .object(members)
    }
}
