import AppKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 4, render-extract-search, U-077: an area's value caption in an export of a
/// `/Rotate 90` sheet is placed across the picture and its fallback leader hangs down the
/// picture, as the canvas draws it — not along the page's own axes.
@MainActor
@Suite("Iter4 captions on rotated sheets", .appTierSerialised)
struct Iter4RotatedCaptionTests {

    private static func area(_ ring: [PDFPointValue], holes: [[PDFPointValue]] = [], caption: String) -> CanvasMarkupShape {
        let xs = ring.map(\.x), ys = ring.map(\.y)
        return CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1),
            strokes: [CanvasStroke(points: ring, closed: true, filled: true)]
                + holes.map { CanvasStroke(points: $0, closed: true, filled: false) },
            fill: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1), counts: [], symbol: nil, artwork: nil, stamp: nil,
            bounds: PDFRectValue(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                                 height: (ys.max() ?? 0) - (ys.min() ?? 0)),
            hidden: false, printable: true,
            caption: caption, kind: .measurement, text: nil, textBox: nil, leaderTarget: nil,
            lineWidth: 1, opacity: 1, fontSize: 12, lineStyle: .solid, vertices: []
        )
    }

    private static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [PDFPointValue] {
        [PDFPointValue(x: x, y: y), PDFPointValue(x: x + width, y: y),
         PDFPointValue(x: x + width, y: y + height), PDFPointValue(x: x, y: y + height)]
    }

    private static let caption = "Area A: 8.00 m²"

    private static func pill(_ markups: [RenderableMarkup]) -> RenderLabelPill? {
        markups.compactMap { markup -> RenderLabelPill? in
            if case let .labelPill(pill) = markup.shape, pill.text == caption { return pill }
            return nil
        }.first
    }

    private static func leaders(_ markups: [RenderableMarkup]) -> [[PDFPoint]] {
        markups.compactMap { markup -> [PDFPoint]? in
            if case let .polyline(line) = markup.shape, !line.isClosed, line.points.count == 2 { return line.points }
            return nil
        }
    }

    @Test("U-077: a strip 40 pt wide and 200 pt tall on the page is 200 × 40 on a /Rotate 90 sheet, and its pill sits inside")
    func extentsFollowTheSheet() throws {
        let strip = Self.area(Self.rect(0, 0, 40, 200), caption: Self.caption)
        // The pill is estimated at 15 × 0.55 × 10 + 12 = 94.5 by 15: it cannot sit across a 40 pt
        // strip, and it can along a 200 pt one.
        let upright = SnippetSceneBuilder.renderables(from: [strip], for: .paper)
        #expect(Self.leaders(upright).count == 1, "upright, the strip is too narrow for the pill")
        let turned = SnippetSceneBuilder.renderables(from: [strip], for: .paper, rotation: .degrees90)
        // Old output: the same leader as upright — the page-axis box never fits a strip that
        // reads 200 pt wide on the exported sheet.
        #expect(Self.leaders(turned).isEmpty)
        #expect(Self.pill(turned)?.anchorPoint == PDFPoint(x: 20, y: 100), "centred on the strip's centroid")
    }

    @Test("U-077: the fallback leader of a courtyard hangs down the /Rotate 90 and 270 pictures")
    func leaderHangsDownThePicture() throws {
        let courtyard = Self.area(Self.rect(0, 0, 300, 300), holes: [Self.rect(100, 100, 100, 100)], caption: Self.caption)
        // /Rotate 90: page +x is down the picture and page +y across it to the right. The lowest
        // vertex on the picture, ties to the left, is page (300, 0); the 18 pt leader runs to
        // (318, 0) and the pill hangs 2 + 7.5 pt beyond: (327.5, 0).
        // Old output: leader (0, 0)–(0, −18) and pill (0, −27.5) — page −y, which on this sheet
        // points left, off the picture's left edge.
        let ninety = SnippetSceneBuilder.renderables(from: [courtyard], for: .paper, rotation: .degrees90)
        #expect(Self.leaders(ninety) == [[PDFPoint(x: 300, y: 0), PDFPoint(x: 318, y: 0)]])
        #expect(Self.pill(ninety)?.anchorPoint == PDFPoint(x: 327.5, y: 0))
        // /Rotate 270: page −x is down the picture; the lowest vertex, ties to the left, is (0, 300).
        let twoSeventy = SnippetSceneBuilder.renderables(from: [courtyard], for: .paper, rotation: .degrees270)
        #expect(Self.leaders(twoSeventy) == [[PDFPoint(x: 0, y: 300), PDFPoint(x: -18, y: 300)]])
        #expect(Self.pill(twoSeventy)?.anchorPoint == PDFPoint(x: -27.5, y: 300))
        // Upright, unchanged: (0, 0) down to (0, −18), pill at (0, −27.5).
        let upright = SnippetSceneBuilder.renderables(from: [courtyard], for: .paper)
        #expect(Self.leaders(upright) == [[PDFPoint(x: 0, y: 0), PDFPoint(x: 0, y: -18)]])
        #expect(Self.pill(upright)?.anchorPoint == PDFPoint(x: 0, y: -27.5))
    }

    @Test("U-077: the display frame turns clockwise by the sheet's /Rotate and back")
    func displayFrameRoundTrips() {
        let point = PDFPoint(x: 3, y: 5)
        for rotation in ZPDFContracts.PageRotation.allCases {
            let frame = SnippetSceneBuilder.DisplayFrame(rotation: rotation)
            #expect(frame.toPage(frame.toDisplay(point)) == point, "\(rotation)")
        }
        // A quarter turn clockwise takes page +x (right) to display −y (down).
        #expect(SnippetSceneBuilder.DisplayFrame(rotation: .degrees90).toDisplay(PDFPoint(x: 1, y: 0)) == PDFPoint(x: 0, y: -1))
    }
}
