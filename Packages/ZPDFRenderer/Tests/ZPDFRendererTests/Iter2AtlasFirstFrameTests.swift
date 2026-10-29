import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
import ZPDFRendererScenario

/// Iteration 2 (S-100): a first frame with more distinct glyph
/// buckets than the atlas cache holds. `ScenePreparer.rebuildAll` compiled every markup before it
/// pinned any, so creating the seventeenth `(font, bucket)` evicted the first, still unpinned,
/// and the backend drew that label from a fresh, empty atlas.
@Suite("Iter2 glyph atlases on a first frame", .serialized)
struct Iter2AtlasFirstFrameTests {

    /// Font sizes 6…25 pt at 1 px per point: buckets 6…23 (half-integer steps below 24 px), then
    /// 24 and 26 — twenty distinct keys against the default capacity of sixteen.
    private static let sizes: [Double] = (6...25).map(Double.init)

    private static func label(_ index: Int) -> RenderableMarkup {
        RenderableMarkup(
            id: MarkupID(UUID(uuid: (0x17, 0x2A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index)))),
            zIndex: index,
            shape: .textLabel(RenderTextLabel(
                anchorPoint: PDFPoint(x: 40, y: 770 - Double(index) * 38),
                text: "WALL",
                fontSize: sizes[index],
                anchor: .center
            )),
            style: RenderStyle(stroke: .opaqueBlack)
        )
    }

    /// Opaque pixels in the band of rows around a label's anchor.
    private static func ink(_ image: RasterImage, row: Int) -> Int {
        var count = 0
        for y in Swift.max(0, row - 16)..<Swift.min(image.height, row + 16) {
            for x in 0..<160 where image.pixel(x: x, y: y).3 > 128 { count += 1 }
        }
        return count
    }

    @Test("S-100: twenty labels at twenty bucket sizes in one update on a fresh renderer all have ink")
    func everyLabelHasInkOnTheFirstFrame() throws {
        #expect(Set(Self.sizes.map { GlyphAtlas.bucket(forDeviceSize: $0) }).count == 20,
                "the scene must exceed the cache's sixteen atlases to exercise the eviction")
        let page = SceneIdentity.page()
        let markups = Self.sizes.indices.map(Self.label)
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(
            page: page, markups: markups, selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 1)
        )
        let image = try renderer.renderOffscreen()
        #expect(image.height == 792)
        for index in markups.indices {
            // Page y → raster row: the raster's first row is the top of the page.
            let row = 792 - (770 - index * 38)
            // Old output: 0 for the first four labels (6, 7, 8 and 9 pt) — their atlases were
            // evicted by labels 17…20 before the pinning loop ran.
            #expect(Self.ink(image, row: row) > 10, "label \(index) at \(Self.sizes[index]) pt is blank")
        }
    }
}
