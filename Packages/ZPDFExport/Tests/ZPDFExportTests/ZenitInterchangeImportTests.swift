import Foundation
import Testing
import ZPDFQuantityLedger
@testable import ZPDFExport

/// The reader as a boundary rather than as a parser.
///
/// `JSONInterchangeTests` already proves the parser round-trips. These tests are about the file
/// that parses and is still a lie, and about the reconciliation that makes reading one back
/// worth doing.
@Suite("Zenit JSON import boundary", .sharedHeap)
struct ZenitInterchangeImportTests {

    private static func goldenBytes(grouped: Bool = true) throws -> Data {
        let projection = try ExportFixture.projection(
            try ExportFixture.goldenReport(grouped: grouped)
        )
        return ZenitJSONExporter().export(projection)
    }

    // MARK: - What a real export does

    @Test("The shipping export passes the boundary and reviews as itself")
    func acceptsOwnExport() throws {
        let bytes = try Self.goldenBytes()
        let (document, review) = try ZenitInterchangeImport.read(bytes, fileName: "Takeoff.zpdfjson")
        #expect(review.fileName == "Takeoff.zpdfjson")
        #expect(review.byteCount == bytes.count)
        #expect(review.schemaVersion == ZenitInterchangeDocument.currentSchemaVersion)
        #expect(review.producerApplication == "Zenit PDF")
        #expect(review.rowCount == document.ledger.rowCount)
        #expect(review.columnTitles.count == document.columns.count)
        #expect(review.fields.contains { $0.label == "File" && $0.value == "Takeoff.zpdfjson" })
    }

    @Test("An ungrouped export passes too")
    func acceptsUngrouped() throws {
        let bytes = try Self.goldenBytes(grouped: false)
        _ = try ZenitInterchangeImport.read(bytes, fileName: "Flat.zpdfjson")
    }

    // MARK: - Files that parse and are still refused

    @Test("An empty file is refused by name")
    func emptyFile() {
        #expect(throws: ExportError.malformedInterchange("the file is empty")) {
            try ZenitInterchangeImport.read(Data(), fileName: "empty.zpdfjson")
        }
    }

    @Test("A future schema version is refused, and the reason names both versions")
    func futureVersion() throws {
        let data = Data(#"{"format":"zenit.ledger.export","schemaVersion":2}"#.utf8)
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(data, fileName: "future.zpdfjson")
        }
        #expect(
            error
                == .unsupportedSchemaVersion(
                    found: 2,
                    supported: ZenitInterchangeDocument.currentSchemaVersion
                )
        )
        #expect(error?.description.contains("supports 1") == true)
    }

    @Test("A row with fewer cells than the ledger has columns is refused")
    func shortRow() throws {
        var text = String(decoding: try Self.goldenBytes(), as: UTF8.self)
        // Remove one whole cell object from the first row: valid JSON, wrong arity.
        let cell = "        {\n          \"type\": \"blank\"\n        },\n"
        #expect(text.contains(cell))
        text = text.replacingOccurrences(of: cell, with: "", options: [], range: text.range(of: cell))
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(Data(text.utf8), fileName: "short.zpdfjson")
        }
        #expect(error?.description.contains("cells against") == true)
    }

    @Test("A declared row count that disagrees with the rows delivered is refused")
    func lyingRowCount() throws {
        let text = String(decoding: try Self.goldenBytes(), as: UTF8.self)
            .replacingOccurrences(of: "\"rowCount\": 6,", with: "\"rowCount\": 5,")
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(Data(text.utf8), fileName: "miscount.zpdfjson")
        }
        #expect(error?.description.contains("row(s)") == true || error?.description.contains("carries") == true)
    }

    @Test("A quantity that is not an invariant decimal never becomes a number")
    func hostileRaw() throws {
        for hostile in ["NaN", "1e400", "12,5", "", " 1", "0x10", "1.2.3", "+1"] {
            #expect(
                !ZenitInterchangeImport.isInvariantDecimal(hostile),
                "\"\(hostile)\" must not read as a quantity"
            )
        }
        for good in ["0", "-0.004", "1234567890.0987654321", "-12"] {
            #expect(ZenitInterchangeImport.isInvariantDecimal(good))
        }

        let text = String(decoding: try Self.goldenBytes(), as: UTF8.self)
            .replacingOccurrences(of: "\"raw\": \"0.4449\"", with: "\"raw\": \"NaN\"")
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(Data(text.utf8), fileName: "nan.zpdfjson")
        }
        #expect(error?.description.contains("invariant decimal") == true)
    }

    @Test("A non-integer JSON number is refused rather than truncated")
    func nonIntegerNumber() {
        let data = Data(#"{"format":"zenit.ledger.export","schemaVersion":1.9}"#.utf8)
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(data, fileName: "float.zpdfjson")
        }
        #expect(error?.description.contains("not an integer") == true)
    }

    @Test("Nesting deeper than the reader's limit is refused, not recursed")
    func deepNesting() {
        let depth = JSONReader.maximumDepth + 40
        let payload = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(Data(payload.utf8), fileName: "deep.zpdfjson")
        }
        #expect(error?.description.contains("nested deeper") == true)
    }

    @Test("A file above the byte ceiling is refused before it is parsed")
    func oversizeFile() {
        let error = ExportError.interchangeTooLarge(
            bytes: ZenitInterchangeImport.maximumByteCount + 1,
            limit: ZenitInterchangeImport.maximumByteCount
        )
        #expect(error.description.contains("this build reads at most"))
        // The ceiling itself is asserted rather than allocated: making a 512 MiB Data in a unit
        // test to prove a `>` is a slow way to test an operator.
        #expect(ZenitInterchangeImport.maximumByteCount == 512 * 1024 * 1024)
    }

    @Test("A timestamp that is not an ISO-8601 UTC instant is refused")
    func badTimestamp() throws {
        let text = String(decoding: try Self.goldenBytes(), as: UTF8.self)
            .replacingOccurrences(of: "\"generatedAt\": \"2026-", with: "\"generatedAt\": \"26-")
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(Data(text.utf8), fileName: "date.zpdfjson")
        }
        #expect(error?.description.contains("ISO-8601") == true)
    }

    @Test("A filtered count below the unfiltered count is fine; the reverse is refused")
    func filterArithmetic() throws {
        let text = String(decoding: try Self.goldenBytes(), as: UTF8.self)
            .replacingOccurrences(of: "\"rowCountBeforeFilter\": 6", with: "\"rowCountBeforeFilter\": 2")
        let error = #expect(throws: ExportError.self) {
            try ZenitInterchangeImport.read(Data(text.utf8), fileName: "filter.zpdfjson")
        }
        #expect(error?.description.contains("a filter removes rows") == true)
    }

    // MARK: - Reconciliation

    @Test("A file reconciled against the ledger it came from is identical, digit for digit")
    func reconcileWithItself() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let exporter = ZenitJSONExporter()
        let ledger = exporter.document(from: projection)
        let (imported, _) = try ZenitInterchangeImport.read(
            exporter.encode(ledger), fileName: "self.zpdfjson"
        )
        let result = ZenitLedgerReconciliation.compare(imported: imported, against: ledger)
        #expect(result.isExactMatch)
        #expect(result.rowsIdentical == ledger.ledger.rowCount)
        #expect(result.rowsDiffering == 0)
        #expect(result.differences.isEmpty)
        #expect(result.columnMismatch == nil)
    }

    @Test("Grouping does not change the reconciliation; rows are matched by identity")
    func reconcileAcrossGrouping() throws {
        let exporter = ZenitJSONExporter()
        let grouped = exporter.document(
            from: try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        )
        let flat = exporter.document(
            from: try ExportFixture.projection(try ExportFixture.goldenReport(grouped: false))
        )
        let result = ZenitLedgerReconciliation.compare(imported: grouped, against: flat)
        #expect(result.rowsOnlyInFile.isEmpty)
        #expect(result.rowsOnlyInLedger.isEmpty)
        #expect(result.rowsIdentical + result.rowsDiffering == flat.ledger.rowCount)
    }

    @Test("One changed digit is found, named, and reported once")
    func reconcileOneChangedDigit() throws {
        let exporter = ZenitJSONExporter()
        let ledger = exporter.document(
            from: try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        )
        let text = String(decoding: exporter.encode(ledger), as: UTF8.self)
            .replacingOccurrences(of: "\"raw\": \"0.4449\"", with: "\"raw\": \"0.4448\"")
        let (imported, _) = try ZenitInterchangeImport.read(
            Data(text.utf8), fileName: "changed.zpdfjson"
        )
        let result = ZenitLedgerReconciliation.compare(imported: imported, against: ledger)
        #expect(!result.isExactMatch)
        #expect(result.rowsDiffering == 1)
        #expect(result.differences.count == 1)
        let difference = try #require(result.differences.first)
        #expect(difference.inFile.hasPrefix("0.4448"))
        #expect(difference.inLedger.hasPrefix("0.4449"))
    }

    @Test("Two ledgers with different columns are refused rather than compared")
    func reconcileColumnMismatch() throws {
        let exporter = ZenitJSONExporter()
        let ledger = exporter.document(
            from: try ExportFixture.projection(try ExportFixture.goldenReport(grouped: false))
        )
        let narrowed = ZenitInterchangeDocument(
            schemaVersion: ledger.schemaVersion,
            generatedAt: ledger.generatedAt,
            producer: ledger.producer,
            document: ledger.document,
            ledger: ledger.ledger,
            numberLocale: ledger.numberLocale,
            columns: Array(ledger.columns.dropLast()),
            groups: ledger.groups,
            rows: ledger.rows,
            grandTotals: ledger.grandTotals
        )
        let result = ZenitLedgerReconciliation.compare(imported: narrowed, against: ledger)
        #expect(result.columnMismatch != nil)
        #expect(result.rowsIdentical == 0)
        #expect(!result.isExactMatch)
    }
}
