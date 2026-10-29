import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// Iteration 3 re-fix (T-065): a stamp's field text turns with the
/// seal, so the snippet crop — `SnippetRegionResolver`, which the snippet export and the review
/// report's snapshots both use — must measure the turned text, not a screen-upright box at the
/// turned anchor. Every ink pixel the renderer paints for the text must fall inside the crop.
@Suite("Turned stamp text inside its crop (iter3 re-fix T-065)", .sharedHeap, .serialized)
struct Iter3RStampCropTests {

    static let baseID = MarkupID(UUID(uuidString: "C3B0A000-0000-4000-8000-000000000065") ?? UUID())
    static let center = PDFPoint(x: 300, y: 400)
    /// The built-in review stamp's box.
    static let size = PDFSize(width: 190, height: 64)
    static let padding = 2.0

    static func page(rotation: PageRotation) -> PageDescriptor {
        let box = PDFRect(x: 0, y: 0, width: 600, height: 800)
        return PageDescriptor(
            id: PageID(ExportFixture.uuid(-2)),
            documentID: DocumentID(ExportFixture.uuid(-1)),
            index: 0,
            label: "S-1",
            boxes: PageBoxes(media: box, crop: box),
            rotation: rotation
        )
    }

    /// Square artwork, so the 190 × 64 box letterboxes it to 64 × 64 while the fields keep the
    /// whole box.
    static let artwork = ArtworkGeometry(
        kind: .vector,
        strokes: [ArtworkContour(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1), PDFPoint(x: 0, y: 1)],
            isClosed: true
        )],
        sourceAspectRatio: 1
    )

    /// Three frozen lines laid out as the app's `SnippetSceneBuilder.stampLabels` lays them out:
    /// equal-height full-width frames, centred text at 0.62 of the frame's height. The first line
    /// is wider than the box.
    static let labels: [StampSceneLabel] = {
        let lines = ["APPROVED FOR CONSTRUCTION", "A. BERG", "2026-09-27"]
        let height = 1 / Double(lines.count)
        return lines.enumerated().map { line, text in
            StampSceneLabel(
                text: text,
                normalizedFrame: PDFRect(x: 0, y: 1 - Double(line + 1) * height, width: 1, height: height),
                fontSizeFraction: 0.62 * height,
                anchor: .center
            )
        }
    }()

    static func stamp(rotation: Double) -> [RenderableMarkup] {
        StampArtworkScene.markups(
            artwork: artwork,
            labels: labels,
            center: center,
            size: size,
            rotationDegrees: rotation,
            style: .default,
            baseID: baseID
        )
    }

    /// The page-space box of every pixel the renderer paints for the stamp's text, at zoom 2.
    static func textInk(_ markups: [RenderableMarkup], page: PageDescriptor) throws -> PDFRect? {
        let text = markups.filter { if case .textLabel = $0.shape { return true } else { return false } }
        let viewport = RenderViewport.fittingWholePage(page, zoom: 2, backingScale: 1)
        let transform = try RenderTransform(page: page, viewport: viewport)
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: page, markups: text, selection: .empty, snapFeedback: nil, viewport: viewport)
        let image = try renderer.renderOffscreen()
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixel(x: x, y: y).3 > 0 {
                // Both far corners of the pixel, so the box covers the whole painted square.
                for (px, py) in [(Double(x), Double(y)), (Double(x + 1), Double(y + 1))] {
                    let point = transform.pixelToPage.apply(px, py)
                    minX = min(minX, point.0); maxX = max(maxX, point.0)
                    minY = min(minY, point.1); maxY = max(maxY, point.1)
                }
            }
        }
        guard minX.isFinite else { return nil }
        return PDFRect(corner: PDFPoint(x: minX, y: minY), opposite: PDFPoint(x: maxX, y: maxY))
    }

    static func describe(_ rect: PDFRect) -> String {
        String(format: "x %.1f…%.1f y %.1f…%.1f", rect.minX, rect.maxX, rect.minY, rect.maxY)
    }

    @Test(
        "T-065: every text ink pixel of a turned stamp with letterboxed artwork lies inside the resolved crop",
        arguments: [
            (90.0, PageRotation.degrees0),
            (0.0, PageRotation.degrees0),
            (-90.0, PageRotation.degrees0),
            (30.0, PageRotation.degrees0),
            (90.0, PageRotation.degrees90),
            (0.0, PageRotation.degrees90),
            (0.0, PageRotation.degrees270),
        ]
    )
    func turnedTextInsideCrop(rotation: Double, pageRotation: PageRotation) throws {
        let page = Self.page(rotation: pageRotation)
        let markups = Self.stamp(rotation: rotation)
        let crop = try SnippetRegionResolver.boundingBox(
            of: [Self.baseID], in: markups, padding: Self.padding, rotation: page.rotation
        )
        let ink = try #require(try Self.textInk(markups, page: page))
        // Half a page point of slack for antialiasing at the glyphs' edges; the crop's own padding
        // is only 2 pt, so the text's box, not the padding, has to reach the ink.
        let slack = 0.5
        let context = "stamp \(rotation)° on /Rotate \(pageRotation): ink \(Self.describe(ink)), crop \(Self.describe(crop))"
        // Old output (text measured as a screen-upright box at the turned anchor), 90° on an
        // upright page: ink x 272.5…326.0 y 293.5…504.5 against crop x 169.0…388.3 y 366.0…434.0,
        // about 71 pt of the first line cut off at each end; −90° and 30° cut off likewise, and a
        // 0° stamp on a /Rotate 90 or 270 page (ink x 193.5…404.5, crop x 266.0…334.0) lost both
        // ends because the page-anchored text was measured as if it were drawn sideways.
        #expect(ink.minX >= crop.minX - slack && ink.maxX <= crop.maxX + slack, "\(context)")
        #expect(ink.minY >= crop.minY - slack && ink.maxY <= crop.maxY + slack, "\(context)")
    }

    @Test("T-065: the turned stamp's crop is the turned text box, not an upright or square estimate")
    func turnedCropIsTight() throws {
        let page = Self.page(rotation: .degrees0)
        let markups = Self.stamp(rotation: 90)
        let crop = try SnippetRegionResolver.boundingBox(of: [Self.baseID], in: markups, padding: Self.padding)
        let ink = try #require(try Self.textInk(markups, page: page))
        // Up the page the crop is the long line's length plus the padding, a few points of line
        // spacing at most — not the upright measure's 64 pt box, nor a square as wide as the text.
        // Old output: crop height 68.0 against ink height 211.0, crop width 219.3.
        #expect(crop.height >= ink.height, "crop \(Self.describe(crop)), ink \(Self.describe(ink))")
        #expect(crop.height <= ink.height + 2 * Self.padding + 6, "crop \(Self.describe(crop)), ink \(Self.describe(ink))")
        // Across the page it is the three lines' stack (the full 64 pt box) plus the padding, not
        // the long line's width.
        #expect(crop.width <= Self.size.height + 2 * Self.padding + 6, "crop \(Self.describe(crop))")

        // A label without an angle keeps the screen-upright measure, /Rotate and all.
        let upright = RenderableMarkup(
            id: Self.baseID, zIndex: 0,
            shape: .textLabel(RenderTextLabel(anchorPoint: Self.center, text: "APPROVED", fontSize: 12, anchor: .center)),
            style: .default
        )
        let flat = try #require(SnippetRegionResolver.extent(of: upright, rotation: .degrees0, scaleFactor: 1))
        let sideways = try #require(SnippetRegionResolver.extent(of: upright, rotation: .degrees90, scaleFactor: 1))
        #expect(flat.width > flat.height && sideways.height > sideways.width, "\(flat) \(sideways)")
        #expect(abs(flat.width - sideways.height) < 1e-9 && abs(flat.height - sideways.width) < 1e-9)
    }
}
