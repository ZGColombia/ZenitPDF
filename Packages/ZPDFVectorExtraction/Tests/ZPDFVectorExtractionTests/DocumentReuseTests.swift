import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// IM-159: one `CGPDFDocument` per file per extractor, not one per page.
struct DocumentReuseTests {

    @Test("Ten pages of one document open it once; a different file opens once more; the output is unchanged")
    func documentIsOpenedOncePerFile() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let set = try ZPDFFixtures.make(.threeHundredPages, in: directory)
        let other = try ZPDFFixtures.make(.rectangle, in: directory)

        let extractor = VectorExtractor()
        var pages: [VectorPageExtraction] = []
        for index in 0..<10 {
            pages.append(try await extractor.extract(documentAt: set.url, pageIndex: index))
        }
        // Old output: 10 — `CGPDFDocument(url)` on every call.
        #expect(await extractor.documentOpenCount == 1)

        _ = try await extractor.pageCount(documentAt: set.url)
        for index in 0..<3 {
            _ = try await extractor.extract(documentAt: set.url, pageIndex: index)
        }
        // Old output: 1 + 3 more opens = 14 by now.
        #expect(await extractor.documentOpenCount == 1)

        _ = try await extractor.extract(documentAt: other.url, pageIndex: 0)
        #expect(await extractor.documentOpenCount == 2)
        // Only the last document is held: going back re-opens.
        _ = try await extractor.extract(documentAt: set.url, pageIndex: 0)
        #expect(await extractor.documentOpenCount == 3)

        // Byte-identical to a fresh extractor's reading of the same page.
        let fresh = try await VectorExtractor().extract(documentAt: set.url, pageIndex: 7)
        #expect(VectorExtractionCodec.encode(fresh) == VectorExtractionCodec.encode(pages[7]))
    }
}
