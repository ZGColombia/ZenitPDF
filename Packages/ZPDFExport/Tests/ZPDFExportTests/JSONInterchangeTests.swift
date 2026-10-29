import Foundation
import Testing
import ZPDFQuantityLedger
@testable import ZPDFExport

@Suite("Zenit JSON interchange", .sharedHeap)
struct JSONInterchangeTests {

    @Test("The document declares its format and schema version first")
    func headerKeys() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "{")
        #expect(lines[1] == "  \"format\": \"zenit.ledger.export\",")
        #expect(lines[2] == "  \"schemaVersion\": 1,")
        #expect(lines[3].hasPrefix("  \"generatedAt\": \"2026-"))
    }

    @Test("Key order is the declared order, not alphabetical and not hashed")
    func keyOrder() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        let expected = [
            "\"format\"", "\"schemaVersion\"", "\"generatedAt\"", "\"producer\"",
            "\"document\"", "\"ledger\"", "\"numberLocale\"", "\"columns\"",
            "\"groups\"", "\"rows\"", "\"grandTotals\""
        ]
        var cursor = text.startIndex
        for key in expected {
            let found = try #require(text.range(of: key, range: cursor..<text.endIndex))
            cursor = found.upperBound
        }
    }

    @Test("Every decimal is a JSON string; no quantity is a JSON number")
    func decimalsAreStrings() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        #expect(text.contains("\"raw\": \"0.4449\""))
        #expect(text.contains("\"display\": \"0.44\""))
        #expect(!text.contains("\"raw\": 0.4449"))
        // The only bare JSON numbers in the file are integers.
        let numberPattern = try Regex(#": (-?\d+(\.\d+)?)(,|\n)"#)
        for match in text.matches(of: numberPattern) {
            let literal = String(text[match.range]).dropFirst(2).dropLast()
            #expect(!literal.contains("."), "found a non-integer JSON number: \(literal)")
        }
    }

    @Test("Dates are ISO-8601 UTC strings")
    func dates() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        #expect(text.contains("\"value\": \"2026-05-28T20:26:40Z\""))
    }

    @Test("The refusal token travels into JSON as a typed cell, never as null")
    func refusalCell() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        #expect(text.contains("\"type\": \"refusal\""))
        #expect(text.contains(LedgerReport.mixedDimensionsToken))
    }

    @Test("A hostile string survives JSON escaping")
    func escaping() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let data = ZenitJSONExporter().export(projection)
        let document = try ZenitJSONImporter().document(from: data)
        let comments = document.rows.compactMap { row -> String? in
            for cell in row.cells {
                if case .text(let value) = cell, ExportFixture.hostileComments.contains(value) {
                    return value
                }
            }
            return nil
        }
        #expect(Set(comments) == Set(ExportFixture.hostileComments.filter { !$0.isEmpty }))
    }

    @Test("A document with the wrong format identifier is refused")
    func wrongFormat() throws {
        let data = Data(#"{"format":"something.else","schemaVersion":1}"#.utf8)
        #expect(throws: ExportError.self) { try ZenitJSONImporter().document(from: data) }
    }

    @Test("An unsupported schema version is refused rather than guessed at")
    func wrongVersion() throws {
        let data = Data(#"{"format":"zenit.ledger.export","schemaVersion":99}"#.utf8)
        #expect(throws: ExportError.self) { try ZenitJSONImporter().document(from: data) }
    }

    @Test("A number cell missing its raw value is a malformed file, not a zero")
    func missingRaw() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        var text = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"raw\": \"0.4449\",", with: "")
        #expect(throws: ExportError.self) {
            try ZenitJSONImporter().document(from: Data(text.utf8))
        }
    }

    @Test("Round trip on the golden ledger, grouped")
    func roundTripGolden() throws {
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(grouped: true))
        let exporter = ZenitJSONExporter()
        let original = exporter.document(from: projection)
        let bytes = exporter.encode(original)
        let imported = try ZenitJSONImporter().document(from: bytes)
        #expect(imported == original)
        #expect(exporter.encode(imported) == bytes)
    }

    /// The requirement in full: export a 10 000-row projection, read it back, and prove both the
    /// model and the bytes came back unchanged.
    @Test("Round trip on a 10 000-row projection")
    func roundTripVolume() throws {
        let projection = try ExportFixture.projection(
            try ExportFixture.syntheticReport(rowCount: 10_000)
        )
        #expect(projection.table.metadata.rowCount == 10_000)

        let exporter = ZenitJSONExporter()
        let original = exporter.document(from: projection)
        let bytes = exporter.encode(original)
        let imported = try ZenitJSONImporter().document(from: bytes)

        #expect(imported == original)
        #expect(exporter.encode(imported) == bytes)

        let rows = imported.groups.reduce(0) { $0 + $1.rows.count } + imported.rows.count
        #expect(rows == 10_000)

        // Not just structurally equal: every exported digit is the digit that came back.
        var checked = 0
        for (a, b) in zip(original.groups, imported.groups) {
            for (rowA, rowB) in zip(a.rows, b.rows) {
                for (cellA, cellB) in zip(rowA.cells, rowB.cells) {
                    if case .number(let left) = cellA, case .number(let right) = cellB {
                        #expect(left.raw == right.raw)
                        #expect(left.display == right.display)
                        checked += 1
                    }
                }
            }
        }
        #expect(checked >= 30_000)
    }
}
