import Foundation

/// Reads a `.zpdfjson` file back into a ``ZenitInterchangeDocument``.
///
/// An interchange format with no reader is a hope, not a format. This one exists so the writer
/// can be held to a round trip: export, import, re-export, and the bytes must be identical, on a
/// 10 000-row projection with groups, subtotals, refusal tokens and every cell kind in it.
///
/// Every failure is a typed ``ExportError/malformedInterchange(_:)`` naming the path that was
/// wrong. Nothing is defaulted: a missing `raw` on a number cell is a corrupt file, and reading
/// it as zero would be the single worst thing this package could do.
public struct ZenitJSONImporter: Sendable {

    public init() {}

    public func document(from data: Data) throws -> ZenitInterchangeDocument {
        let root = try JSONReader.value(from: data)
        guard let format = root["format"]?.stringValue else {
            throw ExportError.malformedInterchange("missing \"format\"")
        }
        guard format == ZenitInterchangeDocument.formatIdentifier else {
            throw ExportError.malformedInterchange("\"format\" is \"\(format)\"")
        }
        guard let version = root["schemaVersion"]?.integerValue else {
            throw ExportError.malformedInterchange("missing \"schemaVersion\"")
        }
        guard version == ZenitInterchangeDocument.currentSchemaVersion else {
            throw ExportError.unsupportedSchemaVersion(
                found: version,
                supported: ZenitInterchangeDocument.currentSchemaVersion
            )
        }

        let producer = try require(root["producer"], "producer")
        let documentInfo = try require(root["document"], "document")
        let ledger = try require(root["ledger"], "ledger")
        let locale = try require(root["numberLocale"], "numberLocale")

        return ZenitInterchangeDocument(
            schemaVersion: version,
            generatedAt: try string(root["generatedAt"], "generatedAt"),
            producer: .init(
                application: try string(producer["application"], "producer.application"),
                package: try string(producer["package"], "producer.package"),
                ledgerContractVersion: try integer(
                    producer["ledgerContractVersion"], "producer.ledgerContractVersion"
                ),
                formulaGrammarVersion: try integer(
                    producer["formulaGrammarVersion"], "producer.formulaGrammarVersion"
                )
            ),
            document: .init(
                projectName: try strictOptionalString(documentInfo["projectName"], "projectName"),
                documentName: try strictOptionalString(documentInfo["documentName"], "documentName"),
                revision: try strictOptionalString(documentInfo["revision"], "revision"),
                scaleDescription: try strictOptionalString(documentInfo["scaleDescription"], "scaleDescription"),
                unitsDescription: try strictOptionalString(documentInfo["unitsDescription"], "unitsDescription"),
                preparedBy: try strictOptionalString(documentInfo["preparedBy"], "preparedBy"),
                notes: try strictOptionalString(documentInfo["notes"], "notes")
            ),
            ledger: .init(
                title: try string(ledger["title"], "ledger.title"),
                grouping: try strings(ledger["grouping"], "ledger.grouping"),
                sort: try strings(ledger["sort"], "ledger.sort"),
                filter: try string(ledger["filter"], "ledger.filter"),
                rowCount: try integer(ledger["rowCount"], "ledger.rowCount"),
                rowCountBeforeFilter: try integer(
                    ledger["rowCountBeforeFilter"], "ledger.rowCountBeforeFilter"
                ),
                staleScaleNotice: try strictOptionalString(ledger["staleScaleNotice"], "ledger.staleScaleNotice")
            ),
            numberLocale: .init(
                identifier: try string(locale["identifier"], "numberLocale.identifier"),
                decimalSeparator: try string(
                    locale["decimalSeparator"], "numberLocale.decimalSeparator"
                ),
                groupingSeparator: try strictOptionalString(locale["groupingSeparator"], "groupingSeparator")
            ),
            columns: try array(root["columns"], "columns").map(column),
            groups: try array(root["groups"], "groups").map(group),
            rows: try array(root["rows"], "rows").map(row),
            grandTotals: try array(root["grandTotals"], "grandTotals").map(total)
        )
    }

    // MARK: - Members

    func column(_ value: JSONValue) throws -> ZenitInterchangeDocument.Column {
        .init(
            key: try string(value["key"], "column.key"),
            title: try string(value["title"], "column.title"),
            kind: try string(value["kind"], "column.kind"),
            unit: try string(value["unit"], "column.unit"),
            decimalPlaces: try strictOptionalInteger(value["decimalPlaces"], "column.decimalPlaces"),
            numberFormat: try strictOptionalString(value["numberFormat"], "numberFormat"),
            aggregationSemantics: try strictOptionalString(value["aggregationSemantics"], "aggregationSemantics"),
            formula: try strictOptionalString(value["formula"], "formula")
        )
    }

    private func group(_ value: JSONValue) throws -> ZenitInterchangeDocument.Group {
        .init(
            token: try string(value["token"], "group.token"),
            label: try string(value["label"], "group.label"),
            depth: try integer(value["depth"], "group.depth"),
            rowCount: try integer(value["rowCount"], "group.rowCount"),
            path: try strings(value["path"], "group.path"),
            subtotals: try array(value["subtotals"], "group.subtotals").map(total),
            rows: try array(value["rows"], "group.rows").map(row),
            groups: try array(value["groups"], "group.groups").map(group)
        )
    }

    /// Internal rather than private because the `.zpdfoverlay` reader reuses this exact row
    /// decoding (feature 6).
    ///
    /// A row written before ADR-0012, or from a pure-measured ledger, has no `"provenance"`
    /// key and reads back as `nil` — the measured claim — which re-exports as no key, so the
    /// round trip stays byte-equal. Whether a present value is one of the three claims is the
    /// validator's business (`ZenitInterchangeImport`), not the parser's.
    func row(_ value: JSONValue) throws -> ZenitInterchangeDocument.Row {
        .init(
            markupID: try string(value["markupID"], "row.markupID"),
            index: try integer(value["index"], "row.index"),
            groupPath: try strings(value["groupPath"], "row.groupPath"),
            cells: try array(value["cells"], "row.cells").map(cell),
            provenance: try strictOptionalString(value["provenance"], "provenance"),
            trace: try trace(value["trace"]),
            keptUnderOlderScale: try strictOptionalBoolean(value["keptUnderOlderScale"], "row.keptUnderOlderScale") ?? false
        )
    }

    /// A row written before feature 16, or by a view with no traces, has no `"trace"` key at all
    /// and reads back as `nil` — which re-exports as no key, so the round trip stays byte-equal.
    private func trace(_ value: JSONValue?) throws -> ZenitInterchangeDocument.Trace? {
        guard let value, case .object = value else { return nil }
        return .init(
            sheet: try string(value["sheet"], "row.trace.sheet"),
            scale: try string(value["scale"], "row.trace.scale"),
            scaleRegion: try strictOptionalString(value["scaleRegion"], "scaleRegion"),
            created: try strictOptionalString(value["created"], "created"),
            measured: try strictOptionalString(value["measured"], "measured"),
            author: try string(value["author"], "row.trace.author"),
            capture: try strictOptionalString(value["capture"], "capture")
        )
    }

    private func total(_ value: JSONValue) throws -> ZenitInterchangeDocument.TotalRow {
        .init(
            function: try string(value["function"], "total.function"),
            cells: try array(value["cells"], "total.cells").map(cell)
        )
    }

    func cell(_ value: JSONValue) throws -> ZenitInterchangeDocument.Cell {
        let kind = try string(value["type"], "cell.type")
        switch kind {
        case "blank":
            return .blank
        case "text":
            return .text(try string(value["value"], "cell.value"))
        case "boolean":
            guard let flag = value["value"]?.booleanValue else {
                throw ExportError.malformedInterchange("cell.value is not a boolean")
            }
            return .boolean(flag)
        case "date":
            return .date(try string(value["value"], "cell.value"))
        case "refusal":
            return .refusal(try string(value["token"], "cell.token"))
        case "number":
            return .number(.init(
                raw: try string(value["raw"], "cell.raw"),
                display: try string(value["display"], "cell.display"),
                unit: try string(value["unit"], "cell.unit")
            ))
        default:
            throw ExportError.malformedInterchange("unknown cell type \"\(kind)\"")
        }
    }

    // MARK: - Accessors

    func require(_ value: JSONValue?, _ path: String) throws -> JSONValue {
        guard let value else { throw ExportError.malformedInterchange("missing \"\(path)\"") }
        return value
    }

    func string(_ value: JSONValue?, _ path: String) throws -> String {
        guard let text = value?.stringValue else {
            throw ExportError.malformedInterchange("\"\(path)\" is not a string")
        }
        return text
    }

    func integer(_ value: JSONValue?, _ path: String) throws -> Int {
        guard let number = value?.integerValue else {
            throw ExportError.malformedInterchange("\"\(path)\" is not an integer")
        }
        return number
    }

    func array(_ value: JSONValue?, _ path: String) throws -> [JSONValue] {
        guard let values = value?.arrayValue else {
            throw ExportError.malformedInterchange("\"\(path)\" is not an array")
        }
        return values
    }

    func strings(_ value: JSONValue?, _ path: String) throws -> [String] {
        try array(value, path).map { element in
            guard let text = element.stringValue else {
                throw ExportError.malformedInterchange("\"\(path)\" contains a non-string")
            }
            return text
        }
    }

    /// An optional string field: absent or `null` is `nil`; a string is itself; anything else —
    /// `"provenance": 2`, `"formula": true` — is refused. Reading a mistyped value as "absent"
    /// turned `"provenance": 2` into the measured claim and walked it past the validator that
    /// exists to refuse a fourth claim (BH-512). Nothing in this format is defaulted.
    func strictOptionalString(_ value: JSONValue?, _ path: String) throws -> String? {
        guard let value else { return nil }
        switch value {
        case .null: return nil
        case .string(let text): return text
        default:
            throw ExportError.malformedInterchange("\"\(path)\" is neither a string nor null")
        }
    }

    /// An optional boolean field, with the same rule: absent or `null` is `nil`, a boolean is
    /// itself, and `"keptUnderOlderScale": "yes"` is refused.
    func strictOptionalBoolean(_ value: JSONValue?, _ path: String) throws -> Bool? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let flag = value.booleanValue else {
            throw ExportError.malformedInterchange("\"\(path)\" is neither a boolean nor null")
        }
        return flag
    }

    /// An optional integer field, with the same rule: absent or `null` is `nil`, an integer is
    /// itself, and `"decimalPlaces": "2"` is refused rather than read as "no precision".
    func strictOptionalInteger(_ value: JSONValue?, _ path: String) throws -> Int? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let number = value.integerValue else {
            throw ExportError.malformedInterchange("\"\(path)\" is neither an integer nor null")
        }
        return number
    }

    /// `null` and "absent" both mean "no value" for the optional string fields, and both must
    /// round-trip back to `nil`. Lenient: a mistyped value also reads as `nil`. The
    /// `.zpdfjson` reader uses ``strictOptionalString(_:_:)``; this remains for the overlay
    /// reader's locale block.
    func optionalString(_ value: JSONValue?) -> String? {
        guard let value, case .string(let text) = value else { return nil }
        return text
    }
}
