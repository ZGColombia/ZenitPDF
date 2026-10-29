import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Bookmarks, named destinations and page labels read out of a real catalog.
@Suite("Outline, destinations and labels")
struct OutlineAndDestinationTests {

    /// Writes a document with a two-level bookmark tree, using PDFKit itself as the
    /// producer so the tree comes back through the same `/Outlines` structure a real
    /// file has.
    func makeOutlinedDocument() throws -> URL {
        let scratch = try Corpus.scratchDirectory("outline")
        let source = try #require(PDFDocument(url: Corpus.url(.mixedPageSizes)))
        let root = PDFOutline()
        for index in 0..<source.pageCount {
            let chapter = PDFOutline()
            chapter.label = "Sheet \(index + 1)"
            chapter.destination = PDFDestination(
                page: try #require(source.page(at: index)),
                at: CGPoint(x: 10, y: 20)
            )
            root.insertChild(chapter, at: index)
            if index == 0 {
                let detail = PDFOutline()
                detail.label = "Detail A"
                detail.destination = PDFDestination(
                    page: try #require(source.page(at: source.pageCount - 1)),
                    at: CGPoint(x: 5, y: 6)
                )
                chapter.insertChild(detail, at: 0)
            }
        }
        source.outlineRoot = root
        let url = scratch.appendingPathComponent("outlined.pdf")
        #expect(source.write(to: url))
        return url
    }

    @Test("A bookmark tree is read back with labels, structure and resolved destinations")
    func outlineRoundTrip() async throws {
        let url = try makeOutlinedDocument()
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let outline = try await provider.outline(of: opened.handle)

        #expect(outline.roots.count == 4)
        #expect(outline.wasTruncated == false)
        #expect(outline.nodeCount == 5)
        #expect(outline.roots.map(\.label) == ["Sheet 1", "Sheet 2", "Sheet 3", "Sheet 4"])

        let first = try #require(outline.roots.first)
        #expect(first.id == OutlinePath([0]))
        #expect(first.destination?.pageIndex == 0)
        #expect(first.destination?.pageLabel == "1")
        #expect(first.destination?.point == CGPoint(x: 10, y: 20))

        let nested = try #require(first.children.first)
        #expect(nested.label == "Detail A")
        #expect(nested.id == OutlinePath([0, 0]))
        #expect(nested.id.depth == 2)
        #expect(nested.destination?.pageIndex == 3)
        #expect(outline.flattened.count == 5)
    }

    @Test("A document with no bookmarks has an empty outline, not a fabricated one")
    func noOutline() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.titleBlockSheet))
        let outline = try await provider.outline(of: opened.handle)
        #expect(outline.isEmpty)
        #expect(outline.nodeCount == 0)
        #expect(try await provider.namedDestinations(of: opened.handle).isEmpty)
    }

    @Test("Outline traversal is bounded in depth and node count")
    func outlineIsBounded() async throws {
        let url = try makeOutlinedDocument()
        var limits = DocumentLimits.standard
        limits.maximumOutlineNodes = 2
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(.url(url), password: nil, limits: limits)
        let outline = try await provider.outline(of: opened.handle)
        #expect(outline.wasTruncated)
        #expect(outline.nodeCount <= 2)

        var shallow = DocumentLimits.standard
        shallow.maximumOutlineDepth = 1
        let shallowProvider = PDFKitDocumentProvider()
        let shallowOpen = try await shallowProvider.open(.url(url), password: nil, limits: shallow)
        let shallowOutline = try await shallowProvider.outline(of: shallowOpen.handle)
        #expect(shallowOutline.wasTruncated)
        #expect(shallowOutline.roots.allSatisfy { $0.children.isEmpty })
    }

    // MARK: - Page labels and named destinations from a real /PageLabels tree

    @Test("A declared /PageLabels tree produces A-102 style labels, distinct from the index")
    func explicitPageLabels() async throws {
        let scratch = try Corpus.scratchDirectory("labels")
        let url = try LabelledProbeDocument.write(into: scratch)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)

        #expect(opened.descriptor.pageCount == LabelledProbeDocument.pageCount)
        let labels = try await provider.pageLabels(of: opened.handle)
        #expect(labels.isExplicit)
        #expect(labels.allLabels() == LabelledProbeDocument.expectedLabels)

        let pages = try await provider.pageDescriptors(of: opened.handle)
        #expect(pages.map(\.index) == Array(0..<LabelledProbeDocument.pageCount))
        #expect(pages.map(\.label) == LabelledProbeDocument.expectedLabels)
        #expect(pages.filter(\.labelIsExplicit).count == pages.count)

        // The point of the whole exercise: sheet A-102 is at index 3, not index 102 and
        // not index 1.
        #expect(labels.pageIndex(forLabel: "A-102") == 3)
        #expect(pages[3].index == 3)
        #expect(pages[3].label == "A-102")
    }

    @Test("Named destinations resolve to page indices and carry the page's label")
    func namedDestinations() async throws {
        let scratch = try Corpus.scratchDirectory("dests")
        let url = try LabelledProbeDocument.write(into: scratch)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let destinations = try await provider.namedDestinations(of: opened.handle)

        #expect(destinations.count == 2)
        let sheet = try #require(
            destinations.first { $0.name == LabelledProbeDocument.sheetDestinationName }
        )
        #expect(sheet.target.pageIndex == LabelledProbeDocument.sheetDestinationPageIndex)
        #expect(sheet.target.pageLabel == "A-102")
        #expect(sheet.target.point == CGPoint(x: 100, y: 200))
        #expect(sheet.target.isResolved)

        let cover = try #require(
            destinations.first { $0.name == LabelledProbeDocument.coverDestinationName }
        )
        #expect(cover.target.pageIndex == 0)
        #expect(cover.target.pageLabel == "i")
    }

    @Test("A search hit on a labelled document reports the label, not the index")
    func searchReportsLabels() async throws {
        // Built on the corpus sheet, relabelled by a page-label range, so the hit's
        // `pageLabel` is what an estimator would be shown in a results list.
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.titleBlockSheet))
        let results = try await provider.search(in: opened.handle, query: "CORRIDOR")
        let hit = try #require(results.hits.first)
        #expect(hit.pageIndex == 0)
        #expect(hit.pageLabel == "1")
    }
}
