import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// A page's text for the readers that need it — table import, the dimension check — from the
/// best source that has any (NL-AUTO-03): the drawing's own text, else the project's stored
/// recognition, else (for a command that asks, over a region) text recognised on this Mac for that
/// command only. Every line carries its confidence.
@MainActor
enum PageTextLoader {

    /// Region recognition, injectable: a test supplies lines instead of running Vision on a render.
    static var regionRecognizer: (@MainActor (ZenitPDFProjectDocument, ZPDFContracts.PageDescriptor, PDFRectValue) async -> [SourcedTextLine]) = { document, page, region in
        guard let drawing = document.loadedDrawing(forPage: page.id.rawValue) else { return [] }
        let scale = RegionTextRecognizer.fittedPixelsPerPoint(for: region)
        guard let image = try? await drawing.rasterSource.renderRegion(
            pageIndex: page.index,
            region: PDFRect(x: region.minX, y: region.minY, width: region.size.width, height: region.size.height),
            pixelsPerPoint: scale) else { return [] }
        let lines = await Task.detached(priority: .userInitiated) { (try? RegionTextRecognizer.recognize(image: image, region: region)) ?? [] }.value
        return lines.map { SourcedTextLine(text: $0.text, boundsInPageSpace: $0.boundsInPageSpace, confidence: $0.confidence, source: .regionOCR) }
    }

    /// Reads only the PDF’s embedded text; a read failure yields no lines.
    static func embeddedLines(source: PageRasterSource, pageIndex: Int) async -> [RecognisedTextLine] {
        ((try? await source.pageTextLines(pageIndex: pageIndex)) ?? []).map {
            RecognisedTextLine(
                text: $0.text,
                boundsInPageSpace: PDFRectValue(
                    x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                    width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
                )
            )
        }
    }

    static func lines(
        document: ZenitPDFProjectDocument,
        page: ZPDFContracts.PageDescriptor,
        region: PDFRectValue?,
        allowRegionOCR: Bool
    ) async -> [SourcedTextLine] {
        let drawing = document.loadedDrawing(forPage: page.id.rawValue)
        let embedded = ((try? await drawing?.rasterSource.pageTextLines(pageIndex: page.index)) ?? []).map {
            SourcedTextLine(
                text: $0.text,
                boundsInPageSpace: PDFRectValue(x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                                                width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height),
                confidence: 1, source: .embedded)
        }
        let embeddedInRegion = SourcedTextLines.within(region, embedded)
        if !embeddedInRegion.isEmpty { return embeddedInRegion }
        // The sheet's own drawing's recognised words (T-006): the primary drawing's index read
        // at an added sheet's page index was the same-index sheet of another PDF.
        let stored = SourcedTextLines.lines(fromRecognisedWords: await document.recognisedWords(onPage: page))
        if let chosen = SourcedTextLines.choose(embedded: embedded, stored: stored, region: region) { return chosen }
        guard allowRegionOCR, let region else { return [] }
        return await regionRecognizer(document, page, region)
    }
}
