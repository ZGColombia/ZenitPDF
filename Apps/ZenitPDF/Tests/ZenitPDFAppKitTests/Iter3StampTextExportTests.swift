import AppKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 3, render-extract-search (T-065): a turned stamp's text is turned in the
/// snippet, flattened and annotated exports — all of which compose through
/// `SnippetSceneBuilder` — as the canvas turns it.
@MainActor
@Suite("Turned stamp text on paper (iter3 T-065)", .appTierSerialised)
struct Iter3StampTextExportTests {

    /// A 200 × 40 pt stamp at (150, 150) turned 90°, with no artwork: the builder's own
    /// border-and-text branch.
    private static func stamp(rotation: Double) -> CanvasMarkupShape {
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 150, y: 150),
            widthPoints: 200,
            heightPoints: 40,
            rotationDegrees: rotation,
            artwork: nil,
            artworkKind: .vector,
            lines: ["APPROVED ESTIMATE"]
        )
        return CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [CanvasStroke(points: placement.corners, closed: true, filled: false)],
            counts: [], stamp: placement, bounds: placement.boundingBox, hidden: false, caption: nil, kind: .stamp
        )
    }

    private static func textLabels(_ markups: [RenderableMarkup]) -> [RenderTextLabel] {
        markups.compactMap { markup in
            if case let .textLabel(label) = markup.shape { return label }
            return nil
        }
    }

    /// The ink box of the stamp's text alone, rendered at zoom 1 on a 300 pt page (pixel y is
    /// 300 − page y).
    private static func textInkBox(rotation: Double) throws -> (width: Int, height: Int)? {
        let markups = SnippetSceneBuilder.renderables(from: [stamp(rotation: rotation)], for: .paper)
            .filter { if case .textLabel = $0.shape { return true } else { return false } }
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 300, height: 300),
                             crop: PDFRect(x: 0, y: 0, width: 300, height: 300))
        )
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil,
                        viewport: RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1))
        let image = try renderer.renderOffscreen()
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixel(x: x, y: y).3 > 32 {
                box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        return box.map { ($0.maxX - $0.minX, $0.maxY - $0.minY) }
    }

    @Test("T-065: a 90° stamp without artwork prints its text up the stamp, not across it")
    func turnedStampTextIsTurnedOnPaper() throws {
        let labels = Self.textLabels(SnippetSceneBuilder.renderables(from: [Self.stamp(rotation: 90)], for: .paper))
        // Old output: rotationDegrees nil — the text was laid out screen-upright.
        #expect(!labels.isEmpty && labels.allSatisfy { $0.rotationDegrees == 90 }, "\(labels)")
        let upright = try #require(try Self.textInkBox(rotation: 0))
        let turned = try #require(try Self.textInkBox(rotation: 90))
        #expect(upright.width > 3 * upright.height, "\(upright)")
        // Old output: the same wide, short box as the upright stamp.
        #expect(turned.height > 3 * turned.width, "\(turned)")
    }
}
