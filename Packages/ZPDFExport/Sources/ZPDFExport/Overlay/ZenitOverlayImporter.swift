import Foundation
import ZPDFContracts

/// Reads a `.zpdfoverlay` file, and decides whether it may be dropped onto a given drawing.
///
/// # The decision, in one place
///
/// ``check(_:against:)`` is the whole safety rule and it is a pure function, so it can be tested
/// without a file, a document or a window. Everything else here is parsing.
///
/// - **Same bytes, same name** — import.
/// - **Same bytes, different name** — import, and say it was renamed. A drawing does not become a
///   different drawing when somebody tidies a folder.
/// - **Different bytes, or a different page count** — refuse, naming both files and stating the
///   difference. Measurements are page-space coordinates; placing them on a drawing they were not
///   measured on produces confident numbers about the wrong building.
public struct ZenitOverlayImporter: Sendable {

    public init() {}

    // MARK: - The decision

    /// - Returns: how `overlay` compares with `target`.
    /// - Throws: ``ExportError/overlaySourceMismatch(_:)`` when the two are not the same drawing.
    ///   The message names both files, both digests and what differs.
    public func check(
        _ overlay: ZenitOverlayDocument.Source,
        against target: ZenitOverlayDocument.Source
    ) throws -> OverlaySourceMatch {
        var differences: [String] = []
        if overlay.digestSHA256 != target.digestSHA256 {
            differences.append("their contents differ")
        }
        if overlay.digestByteCount != target.digestByteCount {
            differences.append(
                "they are \(overlay.digestByteCount) and \(target.digestByteCount) bytes"
            )
        }
        if overlay.pageCount != target.pageCount {
            differences.append(
                "they have \(overlay.pageCount) and \(target.pageCount) pages"
            )
        }
        guard differences.isEmpty else {
            throw ExportError.overlaySourceMismatch(Self.message(
                overlay: overlay,
                target: target,
                differences: differences
            ))
        }
        return overlay.fileName == target.fileName
            ? .identical
            : .renamed(from: overlay.fileName, to: target.fileName)
    }

    /// English, and specific. A refusal that says only "the drawing does not match" leaves the
    /// user with no way to find out which of their files is the one the overlay was made on.
    static func message(
        overlay: ZenitOverlayDocument.Source,
        target: ZenitOverlayDocument.Source,
        differences: [String]
    ) -> String {
        """
        This overlay was measured on "\(overlay.fileName)" \
        (SHA-256 \(overlay.shortDigest)…, \(overlay.pageCount) \
        \(overlay.pageCount == 1 ? "page" : "pages")), and the drawing it is being imported onto \
        is "\(target.fileName)" (SHA-256 \(target.shortDigest)…, \(target.pageCount) \
        \(target.pageCount == 1 ? "page" : "pages")). \
        They are not the same drawing: \(Self.list(differences)). \
        The measurements were not imported — their coordinates belong to the drawing they were \
        measured on.
        """
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "they differ" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Reading

    /// Parses, then checks. Nothing is imported unless the drawing matches.
    public func `import`(
        _ data: Data,
        onto target: ZenitOverlayDocument.Source
    ) throws -> OverlayImport {
        let document = try self.document(from: data)
        let match = try check(document.source, against: target)
        return OverlayImport(document: document, match: match)
    }

    public func document(from data: Data) throws -> ZenitOverlayDocument {
        // Every refusal names the overlay format. The JSON reader and the row reader are shared
        // with the `.zpdfjson` importer and throw that format's errors, which would tell the
        // user a file they never opened is broken.
        guard data.count <= ZenitOverlayDocument.maximumByteCount else {
            throw ExportError.malformedOverlay(
                "the document is \(data.count) bytes; this build reads at most "
                    + "\(ZenitOverlayDocument.maximumByteCount)"
            )
        }
        do {
            return try parseDocument(data)
        } catch let ExportError.malformedInterchange(detail) {
            throw ExportError.malformedOverlay(detail)
        }
    }

    private func parseDocument(_ data: Data) throws -> ZenitOverlayDocument {
        let root = try JSONReader.value(from: data)
        guard let format = root["format"]?.stringValue else {
            throw ExportError.malformedOverlay("missing \"format\"")
        }
        guard format == ZenitOverlayDocument.formatIdentifier else {
            throw ExportError.malformedOverlay("\"format\" is \"\(format)\"")
        }
        guard let version = root["schemaVersion"]?.integerValue else {
            throw ExportError.malformedOverlay("missing \"schemaVersion\"")
        }
        guard version == ZenitOverlayDocument.currentSchemaVersion else {
            throw ExportError.unsupportedSchemaVersion(
                found: version,
                supported: ZenitOverlayDocument.currentSchemaVersion
            )
        }

        let rows = ZenitJSONImporter()
        let producer = try require(root["producer"], "producer")
        let source = try require(root["source"], "source")
        let digest = try require(source["digest"], "source.digest")
        let locale = try require(root["numberLocale"], "numberLocale")

        return ZenitOverlayDocument(
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
            source: .init(
                fileName: try string(source["fileName"], "source.fileName"),
                pageCount: try integer(source["pageCount"], "source.pageCount"),
                digestSHA256: try string(digest["sha256"], "source.digest.sha256"),
                digestByteCount: try integer(digest["byteCount"], "source.digest.byteCount")
            ),
            columns: try array(root["columns"], "columns").map(rows.column),
            numberLocale: .init(
                identifier: try string(locale["identifier"], "numberLocale.identifier"),
                decimalSeparator: try string(
                    locale["decimalSeparator"], "numberLocale.decimalSeparator"
                ),
                groupingSeparator: rows.optionalString(locale["groupingSeparator"])
            ),
            measurements: try array(root["measurements"], "measurements")
                .enumerated()
                .map { try measurement($0.element, "measurements[\($0.offset)]", rows: rows) }
        )
    }

    private func measurement(
        _ value: JSONValue,
        _ path: String,
        rows: ZenitJSONImporter
    ) throws -> ZenitOverlayDocument.Measurement {
        let row = try rows.row(try require(value["row"], "\(path).row"))
        // Absent or `null` is a row without drawn geometry; anything else that is not an object
        // is a corrupted drawing and is refused, like every malformed scalar inside one.
        let geometry: MeasurementGeometry?
        switch value["geometry"] {
        case .none, .some(.null):
            geometry = nil
        case let .some(encoded):
            guard case .object = encoded else {
                throw ExportError.malformedOverlay("\"\(path).geometry\" is not an object")
            }
            geometry = try OverlayGeometryCodec.geometry(encoded, "\(path).geometry")
        }
        return .init(row: row, geometry: geometry, placement: try placement(value["placement"], "\(path).placement"))
    }

    /// The optional redraw hints. Absent or `null` is an older file; anything else must be well
    /// formed, and a negative page index is refused like any corrupted scalar.
    private func placement(_ value: JSONValue?, _ path: String) throws -> ZenitOverlayDocument.Placement? {
        switch value {
        case .none, .some(.null):
            return nil
        case let .some(encoded):
            guard case .object = encoded else {
                throw ExportError.malformedOverlay("\"\(path)\" is not an object")
            }
            let pageIndex = try integer(encoded["pageIndex"], "\(path).pageIndex")
            guard pageIndex >= 0 else {
                throw ExportError.malformedOverlay("\"\(path).pageIndex\" is negative")
            }
            func optionalString(_ key: String) throws -> String? {
                switch encoded[key] {
                case .none, .some(.null): return nil
                case let .some(item):
                    guard let text = item.stringValue else {
                        throw ExportError.malformedOverlay("\"\(path).\(key)\" is not a string")
                    }
                    return text
                }
            }
            return .init(
                pageIndex: pageIndex, tool: try optionalString("tool"), parametersJSON: try optionalString("parameters"),
                styleJSON: try optionalString("style")
            )
        }
    }

    // MARK: - Accessors

    private func require(_ value: JSONValue?, _ path: String) throws -> JSONValue {
        guard let value else { throw ExportError.malformedOverlay("missing \"\(path)\"") }
        return value
    }

    private func string(_ value: JSONValue?, _ path: String) throws -> String {
        guard let text = value?.stringValue else {
            throw ExportError.malformedOverlay("\"\(path)\" is not a string")
        }
        return text
    }

    private func integer(_ value: JSONValue?, _ path: String) throws -> Int {
        guard let number = value?.integerValue else {
            throw ExportError.malformedOverlay("\"\(path)\" is not an integer")
        }
        return number
    }

    private func array(_ value: JSONValue?, _ path: String) throws -> [JSONValue] {
        guard let values = value?.arrayValue else {
            throw ExportError.malformedOverlay("\"\(path)\" is not an array")
        }
        return values
    }
}
