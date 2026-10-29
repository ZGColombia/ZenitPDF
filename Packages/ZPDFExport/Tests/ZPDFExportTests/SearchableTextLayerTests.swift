import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// NL-PDF-13's searchable copy: recognised words written as invisible text another reader finds,
/// on the words' boxes, without changing a pixel.
@Suite(.sharedHeap)
struct SearchableTextLayerTests {

    static let corridor = CGRect(x: 60, y: 100, width: 120, height: 20)
    static let kitchen = CGRect(x: 220, y: 200, width: 48, height: 14)

    static func export(rotate: Int = 0, tokens: [SearchableTextLayerWriter.Token]? = nil) throws -> (source: Data, data: Data, outcome: SearchableTextLayerWriter.Outcome) {
        let source = LayeredSourceFixtures.plain(rotate: rotate)
        let produced = try SearchableTextLayerWriter().data(
            source: source,
            pages: [SearchableTextLayerWriter.Page(
                sourcePageIndex: 0,
                rotation: rotate,
                tokens: tokens ?? [
                    .init(text: "CORRIDOR", bounds: corridor),
                    .init(text: "KÖK", bounds: kitchen),
                    .init(text: "", bounds: kitchen),
                    .init(text: "BAD", bounds: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10))
                ]
            )]
        )
        return (source, produced.data, produced.outcome)
    }

    @Test("PDFKit finds the recognised words, on their boxes, including a word with a diacritic")
    func wordsAreFoundWhereTheyAre() throws {
        let produced = try Self.export()
        #expect(produced.outcome.wordsWritten == 2)
        #expect(produced.outcome.wordsSkipped == 2)
        #expect(produced.data.prefix(produced.source.count) == produced.source)
        let document = try #require(PDFDocument(data: produced.data))
        let page = try #require(document.page(at: 0))
        for (word, box) in [("CORRIDOR", Self.corridor), ("KÖK", Self.kitchen)] {
            let hits = document.findString(word, withOptions: [])
            #expect(hits.count == 1, "\(word): \(hits.count) hits")
            let bounds = try #require(hits.first?.bounds(for: page))
            #expect(abs(bounds.midX - box.midX) < 4 && abs(bounds.midY - box.midY) < 6, "\(word) at \(bounds), box \(box)")
            #expect(abs(bounds.width - box.width) < box.width * 0.15, "\(word) width \(bounds.width) vs \(box.width)")
        }
    }

    @Test("The page renders pixel for pixel as it did: the text is invisible")
    func renderIsUnchanged() throws {
        let produced = try Self.export()
        let before = try #require(PageRaster.render(produced.source, pageIndex: 0, scale: 2))
        let after = try #require(PageRaster.render(produced.data, pageIndex: 0, scale: 2))
        #expect(PageRaster.difference(before, after, tolerance: 0) == 0)
    }

    @Test("On a /Rotate 90 sheet the word runs the way the sheet is read and is still found on its box")
    func rotatedSheet() throws {
        // On a quarter-turned sheet a word the person reads left to right runs up the page.
        let box = CGRect(x: 150, y: 60, width: 20, height: 120)
        let produced = try Self.export(rotate: 90, tokens: [.init(text: "SECTION", bounds: box)])
        let document = try #require(PDFDocument(data: produced.data))
        let page = try #require(document.page(at: 0))
        let hit = try #require(document.findString("SECTION", withOptions: []).first)
        let bounds = hit.bounds(for: page)
        #expect(abs(bounds.midX - box.midX) < 6 && abs(bounds.midY - box.midY) < 6, "\(bounds) vs \(box)")
    }
}
