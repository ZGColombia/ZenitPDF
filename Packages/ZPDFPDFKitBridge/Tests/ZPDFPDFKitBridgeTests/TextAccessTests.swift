import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Text extraction, character boxes, selection and search.
///
/// The title-block fixture places nine strings at exactly known baseline origins, so a
/// search hit can be checked against a coordinate rather than against "something was
/// found".
@Suite("Text access")
struct TextAccessTests {

    func openTitleBlock() async throws -> (PDFKitDocumentProvider, DocumentHandle) {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.titleBlockSheet))
        return (provider, opened.handle)
    }

    @Test("Every string in the manifest is extracted from the page")
    func pageTextContainsEveryManifestString() async throws {
        let manifest = try Corpus.manifest(.titleBlockSheet)
        let (provider, handle) = try await openTitleBlock()
        let text = try await provider.pageText(of: handle, pageIndex: 0)
        #expect(text.availability == .available)
        #expect(!text.isEmpty)
        #expect(text.wasTruncated == false)
        for entry in manifest.texts {
            #expect(text.string.contains(entry.string), "missing \(entry.string)")
        }
    }

    @Test("A scanned page reports that it has no text layer, not an empty string")
    func scannedPageHasNoTextLayer() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.scannedLookPage))
        let text = try await provider.pageText(of: opened.handle, pageIndex: 0)
        #expect(text.availability == .noTextLayer)
        #expect(text.isEmpty)
        #expect(text.characterCount == 0)
        #expect(try await provider.characterBoxes(of: opened.handle, pageIndex: 0, range: nil).isEmpty)
        #expect(try await provider.selection(
            of: opened.handle, pageIndex: 0, from: .zero, to: CGPoint(x: 500, y: 500)
        ) == nil)
    }

    @Test("A search over a scanned page names the pages that had no text to search")
    func searchOverScannedPage() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.scannedLookPage))
        let results = try await provider.search(in: opened.handle, query: "ROOM")
        #expect(results.isEmpty)
        #expect(results.pagesWithoutTextLayer == [0])
        #expect(results.pagesSearched == 1)
    }

    @Test("Search finds both ROOM strings at the coordinates the manifest declares")
    func searchHitsAtKnownPositions() async throws {
        let manifest = try Corpus.manifest(.titleBlockSheet)
        let expectedOrigins = manifest.texts
            .filter { $0.string.hasPrefix("ROOM") }
            .map(\.origin)
            .sorted { $0.x < $1.x }
        #expect(expectedOrigins.count == 2)

        let (provider, handle) = try await openTitleBlock()
        let results = try await provider.search(in: handle, query: "ROOM")
        #expect(results.hits.count == 2)
        #expect(results.wasTruncated == false)
        #expect(results.pagesWithoutTextLayer.isEmpty)

        let byX = results.hits.sorted { $0.bounds.minX < $1.bounds.minX }
        for (hit, origin) in zip(byX, expectedOrigins) {
            #expect(hit.pageIndex == 0)
            #expect(hit.pageLabel == "1")
            #expect(hit.matchedText == "ROOM")
            // The glyph origin is the text baseline; the bounding box starts there in x
            // and sits on the baseline in y.
            #expect(abs(hit.bounds.minX - origin.x) < 1.0, "x was \(hit.bounds.minX), expected \(origin.x)")
            #expect(abs(hit.bounds.minY - origin.y) < 6.0, "y was \(hit.bounds.minY), expected \(origin.y)")
            #expect(hit.bounds.width > 0)
            #expect(hit.range.length == 4)
        }
    }

    @Test("A search hit carries the exact character range and an excerpt around it")
    func searchRangesAndExcerpts() async throws {
        let (provider, handle) = try await openTitleBlock()
        let text = try await provider.pageText(of: handle, pageIndex: 0)
        let results = try await provider.search(in: handle, query: "DRAWING NO ZP-0001")
        let hit = try #require(results.hits.first)
        let page = text.string as NSString
        #expect(page.substring(with: NSRange(location: hit.range.location, length: hit.range.length)) == "DRAWING NO ZP-0001")
        #expect(hit.excerpt.contains("DRAWING NO ZP-0001"))
        #expect(hit.excerpt.count >= hit.matchedText.count)
    }

    @Test("Case sensitivity and whole-word matching are honoured")
    func searchOptions() async throws {
        let (provider, handle) = try await openTitleBlock()

        let insensitive = try await provider.search(
            in: handle, query: "room", options: TextSearchOptions(isCaseInsensitive: true)
        )
        #expect(insensitive.hits.count == 2)

        let sensitive = try await provider.search(
            in: handle, query: "room", options: TextSearchOptions(isCaseInsensitive: false)
        )
        #expect(sensitive.hits.isEmpty)

        // "RID" is inside "CORRIDOR" and inside "GRID"; only whole-word rejects both.
        let substring = try await provider.search(in: handle, query: "RID")
        #expect(substring.hits.count == 2)
        let wholeWord = try await provider.search(
            in: handle, query: "RID", options: TextSearchOptions(matchesWholeWordsOnly: true)
        )
        #expect(wholeWord.hits.isEmpty)
    }

    @Test("Search hit counts are bounded and the truncation is reported")
    func searchIsBounded() async throws {
        var limits = DocumentLimits.standard
        limits.maximumSearchHits = 1
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.titleBlockSheet)), password: nil, limits: limits
        )
        let results = try await provider.search(in: opened.handle, query: "ROOM")
        #expect(results.hits.count == 1)
        #expect(results.wasTruncated)
    }

    @Test("An empty or absurd query is rejected rather than searched")
    func searchQueryValidation() async throws {
        let (provider, handle) = try await openTitleBlock()
        await #expect(throws: PDFBridgeError.emptySearchQuery) {
            _ = try await provider.search(in: handle, query: "")
        }
        let long = String(repeating: "x", count: 2000)
        await #expect(throws: PDFBridgeError.searchQueryTooLong(length: 2000, limit: 1024)) {
            _ = try await provider.search(in: handle, query: long)
        }
    }

    @Test("A search can be restricted to named pages")
    func searchPageSubset() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.mixedTextAndRaster))
        let results = try await provider.search(
            in: opened.handle, query: "ROOM", options: TextSearchOptions(pageIndices: [0])
        )
        #expect(results.pagesSearched == 1)
        #expect(results.hits.count == 1)
        await #expect(throws: PDFBridgeError.pageIndexOutOfRange(index: 4, pageCount: 1)) {
            _ = try await provider.search(
                in: opened.handle, query: "ROOM", options: TextSearchOptions(pageIndices: [4])
            )
        }
    }

    @Test("Character boxes line up with the first glyph's declared origin")
    func characterBoxes() async throws {
        let manifest = try Corpus.manifest(.titleBlockSheet)
        let (provider, handle) = try await openTitleBlock()
        let text = try await provider.pageText(of: handle, pageIndex: 0)

        let boxes = try await provider.characterBoxes(of: handle, pageIndex: 0, range: nil)
        #expect(boxes.count == text.characterCount)
        #expect(boxes.first?.characterIndex == 0)

        // The first extracted character is the first glyph of the first ROOM string.
        let room101 = try #require(manifest.texts.first { $0.id == "room-101" })
        let first = try #require(boxes.first)
        #expect(abs(first.bounds.minX - room101.origin.x) < 2.0)
        #expect(abs(first.bounds.minY - room101.origin.y) < 2.0)
        #expect(first.bounds.height > 0)

        let subset = try await provider.characterBoxes(
            of: handle, pageIndex: 0, range: CharacterRange(location: 5, length: 3)
        )
        #expect(subset.map(\.characterIndex) == [5, 6, 7])
    }

    @Test("Every character box lines up with its own character, across line breaks (CR-74)")
    func characterBoxesLineUpAcrossNewlines() async throws {
        let manifest = try Corpus.manifest(.titleBlockSheet)
        let (provider, handle) = try await openTitleBlock()
        let text = try await provider.pageText(of: handle, pageIndex: 0)
        let boxes = try await provider.characterBoxes(of: handle, pageIndex: 0, range: nil)
        #expect(boxes.count == text.characterCount)

        let page = text.string as NSString
        // Box i must belong to character i — the assertion CR-96 found missing from this file.
        // CORRIDOR is on the second line, after the first newline — exactly where PDFKit's
        // glyph-vs-string indexing diverges. Old output: its box was one glyph to the right
        // (minX ≈ 210 instead of 200) because `characterBounds(at:)` is glyph-indexed and the
        // raw string index skips no newline.
        let corridor = try #require(manifest.texts.first { $0.id == "corridor" })
        let start = page.range(of: "CORRIDOR").location
        #expect(start != NSNotFound)
        let box = try #require(boxes.first { $0.characterIndex == start })
        #expect(abs(box.bounds.minX - corridor.origin.x) < 2.0,
                "CORRIDOR box minX \(box.bounds.minX), expected \(corridor.origin.x)")
        #expect(abs(box.bounds.minY - corridor.origin.y) < 6.0)
        #expect(box.bounds.width > 0)

        // The last non-newline character must carry a real box, not the empty rect the old
        // glyph-index overrun produced for it (its glyph index ran past the glyph stream).
        var lastReal = page.length - 1
        while lastReal >= 0,
              page.character(at: lastReal) == 0x0A || page.character(at: lastReal) == 0x0D {
            lastReal -= 1
        }
        let lastBox = try #require(boxes.first { $0.characterIndex == lastReal })
        #expect(lastBox.bounds.width > 0, "the last character's box was empty")
        #expect(lastBox.bounds.height > 0)
    }

    @Test("A character range past the end of the page is refused")
    func characterRangeValidation() async throws {
        let (provider, handle) = try await openTitleBlock()
        await #expect(throws: PDFBridgeError.self) {
            _ = try await provider.characterBoxes(
                of: handle, pageIndex: 0, range: CharacterRange(location: 0, length: 100_000)
            )
        }
    }

    @Test("Character box extraction is bounded")
    func characterBoxesAreBounded() async throws {
        var limits = DocumentLimits.standard
        limits.maximumCharacterBoxes = 4
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.titleBlockSheet)), password: nil, limits: limits
        )
        let boxes = try await provider.characterBoxes(of: opened.handle, pageIndex: 0, range: nil)
        #expect(boxes.count == 4)
    }

    @Test("Dragging across the first room label selects exactly that string")
    func selectionBetweenTwoPoints() async throws {
        let manifest = try Corpus.manifest(.titleBlockSheet)
        let room101 = try #require(manifest.texts.first { $0.id == "room-101" })
        let (provider, handle) = try await openTitleBlock()

        let selection = try #require(
            try await provider.selection(
                of: handle,
                pageIndex: 0,
                from: CGPoint(x: room101.origin.x - 10, y: room101.origin.y - 5),
                to: CGPoint(x: room101.origin.x + 100, y: room101.origin.y + 15)
            )
        )
        #expect(selection.pageIndex == 0)
        #expect(selection.string.trimmingCharacters(in: .whitespacesAndNewlines) == "ROOM 101")
        #expect(selection.bounds.width > 0)
        #expect(!selection.lineRects.isEmpty)
        #expect(abs(selection.bounds.minX - room101.origin.x) < 2.0)
    }

    @Test("A page index outside the document is refused by every text API")
    func pageIndexValidation() async throws {
        let (provider, handle) = try await openTitleBlock()
        await #expect(throws: PDFBridgeError.pageIndexOutOfRange(index: 3, pageCount: 1)) {
            _ = try await provider.pageText(of: handle, pageIndex: 3)
        }
        await #expect(throws: PDFBridgeError.pageIndexOutOfRange(index: -1, pageCount: 1)) {
            _ = try await provider.characterBoxes(of: handle, pageIndex: -1, range: nil)
        }
    }

    @Test("Text extraction is bounded and says when it truncated")
    func textIsBounded() async throws {
        var limits = DocumentLimits.standard
        limits.maximumPageCharacters = 10
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.titleBlockSheet)), password: nil, limits: limits
        )
        let text = try await provider.pageText(of: opened.handle, pageIndex: 0)
        #expect(text.string.count == 10)
        #expect(text.wasTruncated)
        #expect(text.characterCount > 10)
    }

    @Test("A mixed raster-and-vector page yields exactly the three vector strings")
    func mixedPage() async throws {
        let manifest = try Corpus.manifest(.mixedTextAndRaster)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.mixedTextAndRaster))
        let text = try await provider.pageText(of: opened.handle, pageIndex: 0)
        #expect(text.availability == .available)
        for entry in manifest.texts {
            #expect(text.string.contains(entry.string))
        }
        // The raster's glyph-shaped marks are not text and must not appear.
        #expect(text.characterCount == manifest.texts.reduce(0) { $0 + $1.string.count } + 2)
    }
}
