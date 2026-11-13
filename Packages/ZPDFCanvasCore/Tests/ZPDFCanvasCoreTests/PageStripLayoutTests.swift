import CoreGraphics
import Foundation
import Testing
import ZPDFCanvasCore
import ZPDFUIPresentation

/// Continuous scrolling's geometry (`PageStripLayout`): slots, the follow rule and the window.
/// Values hand-derived.
@Suite("Page strip layout")
struct PageStripLayoutTests {

    /// An A1 sheet in landscape, page points.
    static let a1 = CGSize(width: 2384, height: 1684)
    static let margin = CGSize(width: 900, height: 600)

    @Test("Slots stack top to bottom with a 24 pt gap that scales with the zoom")
    func slotsStackWithProportionalGap() {
        let layout = PageStripLayout(
            pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 600, height: 400), CGSize(width: 600, height: 500)],
            zoom: 0.5, panMargin: Self.margin
        )
        #expect(layout.slotMinY(of: 0) == 600)
        // 600 + 0.5 × (800 + 24) = 1012; then + 0.5 × (400 + 24) = 1224.
        #expect(layout.slotMinY(of: 1) == 1012)
        #expect(layout.slotMinY(of: 2) == 1224)
        #expect(layout.slotMinY(of: 1) - layout.slotMaxY(of: 0) == 12, "the gap is 24 pt × 0.5")
        // 600 + 0.5 × (1700 of sheets + 2 gaps of 24) + 600.
        #expect(layout.documentSize == CGSize(width: 300 + 1800, height: 600 + 874 + 600))
    }

    @Test("The strip is a similarity under zoom: every slot origin scales about the pan margin")
    func stripIsASimilarityUnderZoom() {
        let sizes = [CGSize(width: 600, height: 800), CGSize(width: 400, height: 300), CGSize(width: 900, height: 500)]
        let one = PageStripLayout(pageSizes: sizes, zoom: 1, panMargin: .zero)
        for zoom in [0.25, 1.7, 8.0] as [CGFloat] {
            let scaled = PageStripLayout(pageSizes: sizes, zoom: zoom, panMargin: .zero)
            for index in sizes.indices {
                let a = one.slotFrame(of: index), b = scaled.slotFrame(of: index)
                #expect(abs(b.minX - a.minX * zoom) < 1e-9 && abs(b.minY - a.minY * zoom) < 1e-9)
                #expect(abs(b.width - a.width * zoom) < 1e-9 && abs(b.height - a.height * zoom) < 1e-9)
            }
        }
    }

    @Test("Pages of different widths share one centre line")
    func pagesShareACentreLine() {
        let layout = PageStripLayout(
            pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 200, height: 300), CGSize(width: 1000, height: 500)],
            zoom: 2, panMargin: Self.margin
        )
        let centre = layout.slotFrame(of: 2).midX
        #expect(layout.slotFrame(of: 0).midX == centre)
        #expect(layout.slotFrame(of: 1).midX == centre)
        #expect(layout.slotFrame(of: 2).minX == Self.margin.width, "the widest page starts at the margin")
    }

    @Test("A turned page takes its display size, and a crop its cropped size")
    func rotatedAndCroppedUseDisplaySize() {
        let box = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        #expect(PageStripLayout.displaySize(of: box, rotation: 90) == CGSize(width: 1684, height: 2384))
        #expect(PageStripLayout.displaySize(of: box, rotation: 180) == CGSize(width: 2384, height: 1684))
        let crop = PDFRectValue(x: 100, y: 50, width: 400, height: 300)
        #expect(PageStripLayout.displaySize(of: crop, rotation: 0) == CGSize(width: 400, height: 300))
        let layout = PageStripLayout(
            pageSizes: [PageStripLayout.displaySize(of: box, rotation: 90), PageStripLayout.displaySize(of: crop, rotation: 0)],
            zoom: 1, panMargin: .zero
        )
        #expect(layout.slotFrame(of: 0).height == 2384)
        #expect(layout.slotMinY(of: 1) == CGFloat(2408), "2384 of turned sheet and the 24 pt gap")
    }

    @Test("A point resolves to its slot, and a gap, a margin or the side of a narrow sheet to none")
    func pageAtPointResolvesGaps() {
        let layout = PageStripLayout(
            pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 200, height: 300)],
            zoom: 1, panMargin: Self.margin
        )
        #expect(layout.page(at: CGPoint(x: 1000, y: 700)) == 0)
        #expect(layout.page(at: CGPoint(x: 1000, y: 1410)) == nil, "the gap between 1400 and 1424")
        #expect(layout.page(at: CGPoint(x: 1200, y: 1500)) == 1)
        #expect(layout.page(at: CGPoint(x: 950, y: 1500)) == nil, "beside the narrower second sheet")
        #expect(layout.page(at: CGPoint(x: 1000, y: 100)) == nil, "the top margin")
        #expect(layout.page(at: CGPoint(x: 1000, y: 5000)) == nil, "below the strip")
        #expect(layout.nearestPage(toY: 1405) == 0 && layout.nearestPage(toY: 1420) == 1)
    }

    @Test("The visible range of a 323-page strip is exactly the slots the rect meets")
    func visibleRangeIsExact() {
        let sizes = Array(repeating: Self.a1, count: 323)
        let layout = PageStripLayout(pageSizes: sizes, zoom: 0.25, panMargin: Self.margin)
        #expect(layout.window == 0..<323, "a strip this short is not windowed")
        for top in stride(from: CGFloat(0), to: layout.documentSize.height, by: 977) {
            let rect = CGRect(x: 0, y: top, width: 1600, height: 1000)
            let brute = (0..<323).filter { layout.slotFrame(of: $0).intersects(rect) }
            let range = layout.visibleRange(rect)
            #expect(Array(range) == brute, "rect at \(top)")
        }
    }

    @Test("One page lays out exactly as the single-page canvas: the sheet at the pan margin")
    func onePageEqualsSingleLayout() {
        let layout = PageStripLayout(pageSizes: [Self.a1], zoom: 3, panMargin: Self.margin)
        #expect(layout.slotOrigin(of: 0) == CGPoint(x: Self.margin.width, y: Self.margin.height))
        #expect(layout.documentSize == CGSize(width: Self.a1.width * 3 + 1800, height: Self.a1.height * 3 + 1200))
        #expect(!layout.isWindowed)
    }

    @Test("The page with the largest visible area is followed")
    func followLargestArea() {
        let layout = PageStripLayout(pageSizes: Array(repeating: CGSize(width: 1000, height: 1000), count: 3),
                                     zoom: 1, panMargin: .zero)
        // Slots at 0, 1024 and 2048. A viewport from 700 to 1700 shows 300 of page 0, 676 of page 1.
        let view = CGRect(x: 0, y: 700, width: 1000, height: 1000)
        #expect(layout.pageToFollow(visible: view, current: 0) == 1)
        // From 200: 800 of page 0 against 176 of page 1, so page 0 stays and page 1 hands back.
        #expect(layout.pageToFollow(visible: view.offsetBy(dx: 0, dy: -500), current: 1) == 0)
    }

    @Test("A challenger needs 20 % more area than the current page")
    func followHysteresisHolds() {
        let layout = PageStripLayout(pageSizes: Array(repeating: CGSize(width: 1000, height: 1000), count: 2),
                                     zoom: 1, panMargin: .zero)
        // Slots at 0 and 1024; a viewport 500 tall from 775 shows 225 of page 0 and 251 of page 1.
        func view(_ top: CGFloat) -> CGRect { CGRect(x: 0, y: top, width: 1000, height: 500) }
        #expect(layout.pageToFollow(visible: view(775), current: 0) == 0, "251 against 225: not enough")
        // At 850: 150 against 326, more than 1.2 × — hands over.
        #expect(layout.pageToFollow(visible: view(850), current: 0) == 1)
    }

    @Test("Scrolling back and forth over the boundary does not flip the page on every step")
    func followNoFlipFlop() {
        let layout = PageStripLayout(pageSizes: Array(repeating: CGSize(width: 1000, height: 1000), count: 2),
                                     zoom: 1, panMargin: .zero)
        var current = 0
        var changes = 0
        // A 500-pt viewport wobbling ±20 pt around where the two areas are equal (top = 762); a hand-over
        // needs top > 783.6 one way and top < 740.4 the other.
        for step in 0..<40 {
            let top: CGFloat = 762 + (step.isMultiple(of: 2) ? 20 : -20)
            let next = layout.pageToFollow(visible: CGRect(x: 0, y: top, width: 1000, height: 500), current: current)
            if next != current { changes += 1; current = next }
        }
        #expect(changes == 0, "\(changes) hand-overs while wobbling")
    }

    @Test("Many small sheets in view: the one under the centre line is followed")
    func followManySmallPagesTracksCentre() {
        let layout = PageStripLayout(pageSizes: Array(repeating: CGSize(width: 400, height: 300), count: 40),
                                     zoom: 0.25, panMargin: .zero)
        // Each slot is 75 tall with a 6 pt gap: slot k at 81k. A 1000-tall viewport holds ~12.
        var current = 0
        for top in stride(from: CGFloat(0), through: 2000, by: 20) {
            let view = CGRect(x: 0, y: top, width: 1600, height: 1000)
            current = layout.pageToFollow(visible: view, current: current)
            let centreY = view.midY
            let frame = layout.slotFrame(of: current)
            // The followed page is the one under the centre, or the last one under it across a gap.
            #expect(frame.minY - 6 <= centreY && centreY <= frame.maxY + 6, "top \(top): page \(current)")
        }
    }

    @Test("323 A1 sheets at 6400 % lay out a bounded window, re-based in whole points")
    func longDocumentAtHighZoomIsWindowed() {
        let sizes = Array(repeating: Self.a1, count: 323)
        let layout = PageStripLayout(pageSizes: sizes, zoom: 64, panMargin: Self.margin, windowAnchor: 200)
        #expect(layout.isWindowed)
        #expect(layout.window.contains(200))
        #expect(layout.documentSize.height <= PageStripLayout.maximumDocumentHeight)
        #expect(layout.windowShift == layout.windowShift.rounded(), "a re-base moves by whole points")
        // A neighbouring window moves every common page by the same whole number of points.
        let moved = PageStripLayout(pageSizes: sizes, zoom: 64, panMargin: Self.margin, windowAnchor: 202)
        let delta = moved.slotMinY(of: 201) - layout.slotMinY(of: 201)
        #expect(delta == delta.rounded())
        #expect(abs((moved.slotMinY(of: 200) - layout.slotMinY(of: 200)) - delta) < 1e-6)
        // Near the window's edge the strip asks to be re-based; in its middle it does not.
        let middle = layout.slotFrame(of: 200)
        #expect(!layout.needsRebase(visible: CGRect(x: middle.minX, y: middle.midY, width: 1600, height: 1000)))
        let top = layout.slotFrame(of: layout.window.lowerBound)
        #expect(layout.needsRebase(visible: CGRect(x: top.minX, y: top.minY, width: 1600, height: 1000)))
    }

    @Test("A page taller than the bound is still laid out, alone")
    func oversizedPageIsItsOwnWindow() {
        let sizes = [CGSize(width: 1000, height: 14_400), CGSize(width: 1000, height: 14_400)]
        let layout = PageStripLayout(pageSizes: sizes, zoom: 64, panMargin: .zero, windowAnchor: 1)
        #expect(layout.window == 1..<2)
        #expect(layout.slotMinY(of: 1) == 0)
    }

    @Test("Resting a page: its top under the viewport's top edge, or centred when it fits")
    func restingOrigin() {
        let layout = PageStripLayout(pageSizes: [CGSize(width: 1000, height: 3000), CGSize(width: 500, height: 400)],
                                     zoom: 1, panMargin: CGSize(width: 900, height: 900))
        let viewport = CGSize(width: 1000, height: 1000)
        let tall = layout.restingOrigin(for: 0, viewport: viewport, currentX: 950)
        #expect(tall.y == 900 - PageStripLayout.restingGap)
        #expect(tall.x == 900, "a sheet as wide as the viewport is centred on it")
        let short = layout.restingOrigin(for: 1, viewport: viewport, currentX: 0)
        #expect(short.y == layout.slotFrame(of: 1).midY - 500)
        #expect(short.x == layout.slotFrame(of: 1).midX - 500)
    }
}
