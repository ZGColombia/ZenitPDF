import Foundation
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// NL-DOCS-08 Export Arranged Set, NL-DOCS-05/06 sheet numbers and bookmarks on export: a new
/// PDF from pages of two drawings, in set order, turned as shown, labelled with sheet numbers.
@Suite("Next level documents — composing an arranged set")
struct NextLevelDocumentsComposeTests {

    @Test("Two drawings, set order, a turned sheet, sheet-number labels and sheet-name bookmarks; sources untouched")
    func composesArrangedSet() async throws {
        let scratch = try Corpus.scratchDirectory("nl-docs-compose")
        let setURL = scratch.appendingPathComponent("set-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: Corpus.url(.set30SheetsTitleBlocks), to: setURL)
        let plain = try HandBuiltPDF.onePage(content: "0 0 0 rg 0 80 20 20 re f", mediaBox: "[0 0 200 100]", label: "compose-plain")
        let before = try [setURL, plain].map { try FileDigestProbe.hex(of: $0) }

        let provider = PDFKitDocumentProvider()
        let set = try await provider.open(fileAt: setURL)
        let other = try await provider.open(fileAt: plain)
        let destination = DocumentDestination(url: scratch.appendingPathComponent("arranged-\(UUID().uuidString).pdf"))
        let receipt = try await provider.composeDocument(
            [
                ComposedPage(document: set.handle, pageIndex: 10),                                   // S-201
                ComposedPage(document: other.handle, pageIndex: 0, viewRotation: 90, label: "X-001"),
                ComposedPage(document: set.handle, pageIndex: 0, label: "A-101")
            ],
            bookmarks: [
                ComposedBookmark(title: "S", resultPageIndex: nil, children: [
                    ComposedBookmark(title: "S-201 · FOUNDATION PLAN", resultPageIndex: 0)
                ]),
                ComposedBookmark(title: "X", resultPageIndex: nil, children: [
                    ComposedBookmark(title: "X-001", resultPageIndex: 1)
                ])
            ],
            to: destination
        )
        #expect(receipt.pageCount == 3)
        #expect(try [setURL, plain].map { try FileDigestProbe.hex(of: $0) } == before, "no source was written")

        let reader = PDFKitDocumentProvider()
        let result = try await reader.open(fileAt: destination.url)
        #expect(try await reader.pageLabels(of: result.handle).allLabels() == ["S-201", "X-001", "A-101"],
                "the carried label where none is given, the sheet number where it is")
        let outline = try await reader.outline(of: result.handle)
        #expect(outline.roots.map(\.label) == ["S", "X"])
        #expect(outline.roots[1].children.first?.destination?.pageIndex == 1)
        let pdf = try #require(PDFDocument(url: destination.url))
        #expect(pdf.page(at: 1)?.rotation == 90, "turned as shown")
        #expect(pdf.page(at: 0)?.rotation == 0)
    }

    @Test("An empty composition is refused before anything is written")
    func emptyIsRefused() async throws {
        let scratch = try Corpus.scratchDirectory("nl-docs-compose-empty")
        let url = scratch.appendingPathComponent("never-\(UUID().uuidString).pdf")
        await #expect(throws: PDFBridgeError.self) {
            _ = try await PDFKitDocumentProvider().composeDocument([], to: DocumentDestination(url: url))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
