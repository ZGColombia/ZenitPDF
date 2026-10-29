import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// The 1 000-page envelope.
///
/// A construction set of a thousand sheets is a normal Tuesday, not a stress case. Every
/// number here is printed, because a threshold nobody can read is a threshold nobody can
/// check (QUALITY_BAR section 5).
@Suite("Large documents", .serialized)
struct LargeDocumentTests {

    /// Wall-clock budget for opening a 1 000-page document and reporting its page count.
    /// Deliberately generous: the assertion is that the operation is lazy, not that the
    /// machine is fast.
    static let openBudgetSeconds = 2.0
    /// Budget for reading every page's boxes, labels and rotation.
    static let fullScanBudgetSeconds = 5.0

    @Test("A 1 000-page document opens and reports its page count inside the stated budget")
    func opensThousandPages() async throws {
        let url = Corpus.url(.oneThousandPages)
        let manifest = try Corpus.manifest(.oneThousandPages)
        let byteCount = try FileDigestReader.fileByteCount(at: url)

        let provider = PDFKitDocumentProvider()
        let start = ContinuousClock.now
        let opened = try await provider.open(fileAt: url)
        let openDuration = ContinuousClock.now - start

        #expect(opened.descriptor.pageCount == 1000)
        #expect(opened.descriptor.pageCount == manifest.pageCount)

        let openSeconds = Double(openDuration.components.attoseconds) / 1e18
            + Double(openDuration.components.seconds)
        print(
            """
            [ZPDFPDFKitBridge] 1000-page open
              file:            \(url.lastPathComponent)
              bytes:           \(byteCount)
              pages reported:  \(opened.descriptor.pageCount)
              open + pageCount + SHA-256: \(String(format: "%.4f", openSeconds)) s \
            (budget \(String(format: "%.1f", Self.openBudgetSeconds)) s)
            """
        )
        #expect(openSeconds < Self.openBudgetSeconds)
    }

    @Test("Reading every page's geometry on a 1 000-page document stays inside its budget")
    func scansEveryPage() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.oneThousandPages))

        let start = ContinuousClock.now
        let pages = try await provider.pageDescriptors(of: opened.handle)
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.attoseconds) / 1e18
            + Double(duration.components.seconds)

        #expect(pages.count == 1000)
        #expect(pages.first?.index == 0)
        #expect(pages.last?.index == 999)
        #expect(pages.last?.label == "1000")
        #expect(pages.allSatisfy { $0.boxes.media.width == 612 })

        print(
            """
            [ZPDFPDFKitBridge] 1000-page full geometry scan
              pages:           \(pages.count)
              boxes + labels + rotation: \(String(format: "%.4f", seconds)) s \
            (budget \(String(format: "%.1f", Self.fullScanBudgetSeconds)) s)
              per page:        \(String(format: "%.4f", seconds / Double(pages.count) * 1000)) ms
            """
        )
        #expect(seconds < Self.fullScanBudgetSeconds)
    }

    @Test("The last page of a 300-page document renders without touching the first 299")
    func rendersLastPageOfLargeDocument() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.threeHundredPages))
        #expect(opened.descriptor.pageCount == 300)

        let start = ContinuousClock.now
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 299, scale: 0.5)
        )
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.attoseconds) / 1e18
            + Double(duration.components.seconds)
        #expect(rendered.pixelWidth == 306)
        print(
            "[ZPDFPDFKitBridge] page 300 of 300 rendered at 0.5x in "
                + String(format: "%.4f", seconds) + " s"
        )
        #expect(seconds < 2.0)
    }

    @Test("A page range keeps a partial scan cheap")
    func partialScan() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.oneThousandPages))
        let pages = try await provider.pageDescriptors(of: opened.handle, range: 990..<1000)
        #expect(pages.map(\.index) == Array(990..<1000))
        #expect(pages.map(\.label) == (991...1000).map(String.init))
    }

    @Test("A ten-thousand-segment page renders and extracts text without hanging")
    func denseVectorPage() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.tenThousandSegments))
        let start = ContinuousClock.now
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, scale: 1)
        )
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.attoseconds) / 1e18
            + Double(duration.components.seconds)
        #expect(rendered.pixelWidth > 0)
        print(
            "[ZPDFPDFKitBridge] 10 000-segment page rendered at 1x in "
                + String(format: "%.4f", seconds) + " s"
        )
        #expect(seconds < 5.0)
    }
}
