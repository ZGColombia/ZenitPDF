import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

/// The overlay's optional `placement`: page index, tool and parameters,
/// which the geometry alone cannot carry to another copy of the drawing (page IDs are minted per
/// session). Additive: a document without placements is unchanged, and an older file still reads.
@Suite("Overlay placement", .sharedHeap)
struct OverlayPlacementTests {

    private static let source = ZenitOverlayDocument.Source(
        fileName: "A-101.pdf", pageCount: 3, digestSHA256: String(repeating: "ab", count: 32), digestByteCount: 1234)

    private static func document(placement: ZenitOverlayDocument.Placement?) throws -> Data {
        let json = """
        {"format":"zenit.measurement.overlay","schemaVersion":1,"generatedAt":"2026-09-23T12:00:00Z",
         "producer":{"application":"Zenit PDF","package":"ZPDFExport","ledgerContractVersion":1,"formulaGrammarVersion":1},
         "source":{"fileName":"A-101.pdf","pageCount":3,"digest":{"algorithm":"SHA-256","sha256":"\(source.digestSHA256)","byteCount":1234}},
         "numberLocale":{"identifier":"en_US_POSIX","decimalSeparator":".","groupingSeparator":null},
         "columns":[],
         "measurements":[{"row":{"markupID":"M1","index":0,"groupPath":[],"cells":[]},"geometry":null\(placementJSON(placement))}]}
        """
        return Data(json.utf8)
    }

    private static func placementJSON(_ placement: ZenitOverlayDocument.Placement?) -> String {
        guard let placement else { return "" }
        let tool = placement.tool.map { "\"\($0)\"" } ?? "null"
        let parameters = placement.parametersJSON.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null"
        return ",\"placement\":{\"pageIndex\":\(placement.pageIndex),\"tool\":\(tool),\"parameters\":\(parameters)}"
    }

    @Test("A placement round-trips through the reader")
    func placementReads() throws {
        let placement = ZenitOverlayDocument.Placement(pageIndex: 2, tool: "volume", parametersJSON: #"{"depth":{"value":"0.15"}}"#)
        let read = try ZenitOverlayImporter().document(from: try Self.document(placement: placement))
        #expect(read.measurements.first?.placement == placement)
    }

    @Test("An older file without placement still reads, with placement nil")
    func olderFileReads() throws {
        let read = try ZenitOverlayImporter().document(from: try Self.document(placement: nil))
        #expect(read.measurements.count == 1)
        #expect(read.measurements.first?.placement == nil)
    }

    @Test("A negative page index is refused as a malformed overlay")
    func negativePageRefused() throws {
        let bad = ZenitOverlayDocument.Placement(pageIndex: -1, tool: nil, parametersJSON: nil)
        #expect(throws: ExportError.self) { try ZenitOverlayImporter().document(from: try Self.document(placement: bad)) }
    }

    @Test("The writer emits placement only when present, after geometry")
    func writerIsAdditive() throws {
        let row = try #require(try ZenitOverlayImporter().document(from: try Self.document(placement: nil)).measurements.first?.row)
        func encoded(_ placement: ZenitOverlayDocument.Placement?) -> String {
            let document = ZenitOverlayDocument(
                schemaVersion: 1, generatedAt: "2026-09-23T12:00:00Z",
                producer: .init(application: "Zenit PDF", package: "ZPDFExport", ledgerContractVersion: 1, formulaGrammarVersion: 1),
                source: Self.source, columns: [],
                numberLocale: .init(identifier: "en_US_POSIX", decimalSeparator: ".", groupingSeparator: nil),
                measurements: [.init(row: row, geometry: nil, placement: placement)])
            return String(decoding: ZenitOverlayExporter().encode(document), as: UTF8.self)
        }
        #expect(!encoded(nil).contains("placement"))
        let with = encoded(.init(pageIndex: 1, tool: "area", parametersJSON: nil))
        #expect(with.contains("\"placement\""))
        let reread = try ZenitOverlayImporter().document(from: Data(with.utf8))
        #expect(reread.measurements.first?.placement == .init(pageIndex: 1, tool: "area", parametersJSON: nil))
    }
}
