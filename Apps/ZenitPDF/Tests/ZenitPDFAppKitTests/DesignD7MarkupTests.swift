import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Design round d7: the canvas markup appearance of the 2026-09-23 main-window design, and
/// IM-163's grouped live state. Every picture here is rendered off screen with
/// `cacheDisplay(in:to:)` on a view that is in no window.
@MainActor
@Suite(.appTierSerialised)
struct DesignD7MarkupTests {

    // MARK: - Fixtures

    private static let pageSize = CGSize(width: 300, height: 300)

    private func makeView(zoom: Double = 1) -> (CanvasPageView, PageDisplayTransform) {
        let view = CanvasPageView()
        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: Self.pageSize.width, height: Self.pageSize.height),
            rotation: 0,
            zoom: zoom,
            origin: CGPoint(x: 10, y: 10)
        )
        view.transform = transform
        view.backingScaleOverride = 2
        view.frame = CGRect(
            x: 0, y: 0,
            width: Self.pageSize.width * zoom + 40,
            height: Self.pageSize.height * zoom + 40
        )
        return (view, transform)
    }

    private func shape(
        _ strokes: [CanvasStroke],
        color: ColorRGBA = ColorRGBA(red: 0.10, green: 0.33, blue: 0.81, alpha: 1),
        caption: String? = nil,
        bounds: PDFRectValue = PDFRectValue(x: 50, y: 50, width: 150, height: 100)
    ) -> CanvasMarkupShape {
        CanvasMarkupShape(
            id: UUID(),
            pageID: UUID(),
            color: color,
            strokes: strokes,
            counts: [],
            bounds: bounds,
            hidden: false,
            caption: caption
        )
    }

    private func render(_ view: NSView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func color(_ rep: NSBitmapImageRep, _ view: NSView, _ point: CGPoint) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB) ?? .clear
    }

    private func isPaper(_ c: NSColor) -> Bool {
        c.redComponent > 0.93 && c.greenComponent > 0.93 && c.blueComponent > 0.93
    }

    private func isBlueInk(_ c: NSColor) -> Bool {
        c.blueComponent > 0.6 && c.redComponent < 0.35 && c.greenComponent < 0.55
    }

    private let rectangle = [
        PDFPointValue(x: 50, y: 50), PDFPointValue(x: 200, y: 50),
        PDFPointValue(x: 200, y: 150), PDFPointValue(x: 50, y: 150)
    ]

    // MARK: - IM-163: one live value, one guard per group, overlay-only redraw

    @Test("IM-163: identical live values change nothing; each group change is one overlay repaint")
    func liveStateIsGuardedPerGroup() {
        let (view, transform) = makeView()
        let pageInvalidations = view.pageInvalidationCount
        let changes = view.liveChangeCount

        var state = view.live
        view.live = state
        #expect(view.liveChangeCount == changes, "re-assigning the same live value repainted")

        // One assignment that touches all three groups is one change, not three.
        state.drawing.points = [PDFPointValue(x: 60, y: 60)]
        state.drawing.cursorPoint = PDFPointValue(x: 90, y: 60)
        state.pointer.snapPoint = PDFPointValue(x: 90, y: 60)
        state.calibration.points = [PDFPointValue(x: 20, y: 20)]
        view.live = state
        #expect(view.liveChangeCount == changes + 1)
        #expect(view.pageInvalidationCount == pageInvalidations, "a live change repainted the page view")

        // The forwarders are guarded by the same equality.
        view.snapPoint = PDFPointValue(x: 90, y: 60)
        view.livePoints = [PDFPointValue(x: 60, y: 60)]
        #expect(view.liveChangeCount == changes + 1, "an unchanged forwarder assignment repainted")
        view.liveCursorPoint = PDFPointValue(x: 95, y: 60)
        #expect(view.liveChangeCount == changes + 2)
        #expect(view.live.drawing.cursorPoint == PDFPointValue(x: 95, y: 60))
        _ = transform
    }

    @Test("IM-163: a pointer move repaints only the old and new snap ring, not the overlay")
    func snapMoveDirtiesOnlyItsRing() throws {
        let (view, transform) = makeView()
        view.snapPoint = PDFPointValue(x: 100, y: 100)
        view.snapPoint = PDFPointValue(x: 110, y: 100)
        let dirty = try #require(view.lastLiveDirtyRect)
        let old = transform.viewPoint(from: PDFPointValue(x: 100, y: 100))
        let new = transform.viewPoint(from: PDFPointValue(x: 110, y: 100))
        #expect(dirty.contains(CGRect(x: old.x - 7, y: old.y - 7, width: 14, height: 14)))
        #expect(dirty.contains(CGRect(x: new.x - 7, y: new.y - 7, width: 14, height: 14)))
        #expect(dirty.width * dirty.height < view.bounds.width * view.bounds.height / 20,
                "a ring move invalidated \(dirty) of \(view.bounds)")
    }

    @Test("IM-163: the dirty rect of a drawing reaches its caption pill on either side of the anchor")
    func drawingDirtyRectCoversTheCaptionPill() {
        let (view, transform) = makeView()
        var drawing = CanvasLiveState.Drawing()
        drawing.points = [PDFPointValue(x: 100, y: 100)]
        drawing.cursorPoint = PDFPointValue(x: 150, y: 100)
        drawing.caption = "Length: 12' - 6\""
        let textSize = NSAttributedString(string: drawing.caption!, attributes: CanvasPillTestSupport.pillTextAttributes).size()
        let ink = CanvasLiveState.inkBounds(of: drawing, transform: transform) { _ in textSize }
        let anchor = transform.viewPoint(from: PDFPointValue(x: 150, y: 100))
        let pill = CanvasMarkupStyle.pillBoxSize(forText: textSize)
        // Right-above (the default) and left-below (flipped at a visible edge) both fit.
        let rightAbove = CanvasPageView.anchoredPillBox(size: textSize, anchor: anchor, visible: view.bounds)
        #expect(ink.contains(rightAbove))
        let leftBelow = CGRect(x: anchor.x - CanvasMarkupStyle.pillAnchorGap - pill.width, y: anchor.y + 6,
                               width: pill.width, height: pill.height)
        #expect(ink.contains(leftBelow))
    }

    @Test("IM-163: a group that did not change contributes nothing to the dirty rect")
    func unchangedGroupsAreNotRepainted() throws {
        let (_, transform) = makeView()
        var old = CanvasLiveState()
        old.calibration.points = [PDFPointValue(x: 10, y: 10), PDFPointValue(x: 290, y: 290)]
        var new = old
        new.pointer.snapPoint = PDFPointValue(x: 150, y: 150)
        let dirty = try #require(CanvasLiveState.dirtyRect(from: old, to: new, transform: transform) { _ in .zero })
        let calibrationInk = CanvasLiveState.inkBounds(of: old.calibration, transform: transform)
        #expect(dirty.width < calibrationInk.width / 4, "the unchanged calibration was repainted")
    }

    // MARK: - Label pills

    @Test("A committed area's pill is filled with the markup's ink and set in light text")
    func areaPillIsInkFilled() {
        let (view, transform) = makeView()
        let caption = "Area: 620 SF"
        view.shapes = [shape([CanvasStroke(points: rectangle, closed: true, filled: true)], caption: caption)]
        let rep = render(view)
        let center = transform.viewPoint(from: PDFPointValue(x: 125, y: 100))
        let size = NSAttributedString(string: caption, attributes: CanvasPillTestSupport.pillTextAttributes).size()
        let box = CanvasMarkupStyle.pillBoxSize(forText: size)
        // Inside the left padding, where no glyph paints.
        let fill = color(rep, view, CGPoint(x: center.x - box.width / 2 + 3, y: center.y))
        #expect(isBlueInk(fill), "the pill must be filled with the markup's blue, got \(fill)")
        #expect(CanvasMarkupStyle.pillTone(onFill: CanvasMarkupStyle.pillFill(forInk: .init(srgbRed: 0.10, green: 0.33, blue: 0.81, alpha: 1))) == .light)
    }

    @Test("A light markup colour gets a dark pill label, a dark one a light label")
    func pillToneFollowsContrast() {
        #expect(CanvasMarkupStyle.pillTone(onFill: ZPDFColor.nsColor(.pillFill)) == .light)
        #expect(CanvasMarkupStyle.pillTone(onFill: ZPDFColor.nsColor(.inkRed)) == .light)
        #expect(CanvasMarkupStyle.pillTone(onFill: NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1)) == .dark)
        #expect(CanvasMarkupStyle.pillTone(onFill: NSColor(srgbRed: 0.6, green: 1, blue: 0.6, alpha: 1)) == .dark)
    }

    @Test("A length's pill is centred under the middle of its run, clear of the shaft")
    func lengthPillSitsUnderTheMidpoint() throws {
        let pill = CGSize(width: 60, height: 22)
        let horizontal = try #require(CanvasPageView.lengthPillCenter(
            viewPoints: [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200)], pillSize: pill, strokeWidth: 2
        ))
        #expect(abs(horizontal.x - 200) < 1e-9)
        #expect(horizontal.y - pill.height / 2 >= 200 + 1 + CanvasMarkupStyle.lengthPillGap - 1e-9,
                "the pill must clear the shaft by the gap, centre \(horizontal)")
        // Drawn right to left it is still under the line, not above it.
        let reversed = try #require(CanvasPageView.lengthPillCenter(
            viewPoints: [CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200)], pillSize: pill
        ))
        #expect(reversed.y > 200)
        // A vertical run hangs its pill to the right.
        let vertical = try #require(CanvasPageView.lengthPillCenter(
            viewPoints: [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100)], pillSize: pill
        ))
        #expect(abs(vertical.y - 50) < 1e-9 && vertical.x - pill.width / 2 >= 50 + CanvasMarkupStyle.lengthPillGap - 1e-9)
        // The midpoint is measured along the path, not between the ends.
        let elbow = try #require(CanvasPageView.lengthPillCenter(
            viewPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 300)], pillSize: pill
        ))
        #expect(elbow.y > 90 && elbow.y < 110, "an L of 100 + 300 is halved on its second leg, got \(elbow)")
        #expect(CanvasPageView.lengthPillCenter(viewPoints: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1)], pillSize: pill) == nil)
    }

    @Test("A committed length ends in round dots on its measured endpoints and hangs its pill below")
    func lengthDrawsEndpointDotsAndPillBelow() {
        let (view, transform) = makeView()
        let caption = "24' - 0\""
        var length = shape(
            [CanvasStroke(points: [PDFPointValue(x: 60, y: 200), PDFPointValue(x: 240, y: 200)],
                          closed: false, filled: false, dimensioned: true)],
            caption: caption,
            bounds: PDFRectValue(x: 60, y: 200, width: 180, height: 0)
        )
        length.lineWidth = 1
        view.shapes = [length]
        let rep = render(view)
        let start = transform.viewPoint(from: PDFPointValue(x: 60, y: 200))
        // Outward of the endpoint, where neither the shaft nor the tick reaches: the dot.
        #expect(isBlueInk(color(rep, view, CGPoint(x: start.x - 2.5, y: start.y))))
        // The pill hangs under the midpoint.
        let mid = transform.viewPoint(from: PDFPointValue(x: 150, y: 200))
        let size = NSAttributedString(string: caption, attributes: CanvasPillTestSupport.pillTextAttributes).size()
        let box = CanvasMarkupStyle.pillBoxSize(forText: size)
        let below = CGPoint(x: mid.x - box.width / 2 + 3, y: mid.y + CanvasMarkupStyle.lengthPillGap + box.height / 2)
        #expect(isBlueInk(color(rep, view, below)), "the pill must hang under the midpoint")
        // Nothing is drawn above the midpoint where the old anchored pill sat.
        #expect(isPaper(color(rep, view, CGPoint(x: mid.x, y: mid.y - box.height))))
    }

    // MARK: - Handles and selection

    @Test("A selected area shows round paper handles ringed in the selection ink and a halo")
    func selectedAreaHandles() {
        let (view, transform) = makeView()
        var area = shape([CanvasStroke(points: rectangle, closed: true, filled: true)])
        area.vertices = rectangle
        view.shapes = [area]
        view.selection = [area.id]
        let rep = render(view)
        let corner = transform.viewPoint(from: rectangle[0])
        #expect(isPaper(color(rep, view, corner)), "a handle's centre is paper")
        // Page (50, 50) is the area's bottom-left corner on screen: its edges run up and right.
        // Sampled below the corner, where only the handle's ring can paint.
        let ringSample = CGPoint(x: corner.x, y: corner.y + CanvasMarkupStyle.handleDiameter / 2)
        let ring = color(rep, view, ringSample)
        #expect(ring.blueComponent > 0.5 && ring.redComponent < 0.4, "the handle ring is the selection ink, got \(ring)")
        // Round, not square: the handle's bounding-square corner (down and left, off the shape
        // and outside the halo's round join) stays paper.
        // 3.75 pt out on both axes: inside a 7 pt square's ring (≤ 4.25), outside a 7 pt
        // circle's (4.25 pt radius; this point is 5.3 pt away).
        let d = CanvasMarkupStyle.handleDiameter / 2 + 0.25
        let handleCorner = CGPoint(x: corner.x - d, y: corner.y + d)
        #expect(isPaper(color(rep, view, handleCorner)), "an area's handle must be a circle")
        // No edge-midpoint dots: nothing inserts a vertex there.
        let midpoint = transform.viewPoint(from: PDFPointValue(x: 125, y: 150))
        let belowMid = color(rep, view, CGPoint(x: midpoint.x, y: midpoint.y + 6))
        #expect(isPaper(belowMid) || belowMid.alphaComponent < 0.5 || belowMid.blueComponent > belowMid.redComponent,
                "unexpected ink at an edge midpoint")
        // The halo reaches past the stroke on the outside of an edge.
        let edge = transform.viewPoint(from: PDFPointValue(x: 125, y: 50))
        let halo = color(rep, view, CGPoint(x: edge.x, y: edge.y + 3))
        #expect(!isPaper(halo) && halo.blueComponent > halo.redComponent, "no selection halo, got \(halo)")
    }

    @Test("A selected open path shows round handles")
    func selectedLengthHandlesAreRound() {
        let (view, transform) = makeView()
        let points = [PDFPointValue(x: 60, y: 200), PDFPointValue(x: 240, y: 200)]
        var length = shape([CanvasStroke(points: points, closed: false, filled: false)],
                           bounds: PDFRectValue(x: 60, y: 200, width: 180, height: 0))
        length.vertices = points
        view.shapes = [length]
        view.selection = [length.id]
        let rep = render(view)
        let end = transform.viewPoint(from: points[1])
        let d = CanvasMarkupStyle.handleDiameter / 2 + 0.25
        // The bounding square's corner lies outside a round knob.
        #expect(isPaper(color(rep, view, CGPoint(x: end.x + d, y: end.y - d))),
                "an open path's handle must be round")
    }

    // MARK: - Callouts and clouds

    @Test("A callout is a rounded note with a tinted paper backing")
    func calloutIsRoundedAndBacked() {
        let (view, transform) = makeView()
        let box = PDFRectValue(x: 100, y: 150, width: 120, height: 40)
        let corners = [
            PDFPointValue(x: 100, y: 150), PDFPointValue(x: 220, y: 150),
            PDFPointValue(x: 220, y: 190), PDFPointValue(x: 100, y: 190)
        ]
        var callout = shape(
            [
                CanvasStroke(points: [PDFPointValue(x: 100, y: 170), PDFPointValue(x: 50, y: 120)],
                             closed: false, filled: false, arrowAtEnd: true),
                CanvasStroke(points: corners, closed: true, filled: false)
            ],
            color: ColorRGBA(red: 0.80, green: 0.19, blue: 0.13, alpha: 1),
            bounds: box
        )
        callout.kind = .callout
        callout.textBox = box
        callout.lineWidth = 1.5
        view.shapes = [callout]
        let rep = render(view)
        let rect = transform.viewRect(from: box).standardized
        // Rounded: the exact corner is not inked, the middle of the top edge is.
        #expect(isPaper(color(rep, view, CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5))), "the corner must be rounded")
        let edge = color(rep, view, CGPoint(x: rect.midX, y: rect.minY))
        #expect(edge.redComponent > 0.6 && edge.greenComponent < 0.5, "the border is the markup's ink, got \(edge)")
        // The backing is paper faintly tinted by the red ink, not the bare sheet.
        let inside = color(rep, view, CGPoint(x: rect.midX, y: rect.midY))
        #expect(inside.redComponent > 0.95 && inside.greenComponent < 0.985 && inside.greenComponent > 0.85,
                "the backing must be a pale tint of the ink, got \(inside)")
    }

    @Test("A callout's text is padded off its frame, semibold, in a deeper shade; the frame is at least 1.5 pt")
    func calloutTextIsPaddedAndFramed() {
        let (view, transform) = makeView()
        let box = PDFRectValue(x: 60, y: 150, width: 180, height: 60)
        let corners = [
            PDFPointValue(x: 60, y: 150), PDFPointValue(x: 240, y: 150),
            PDFPointValue(x: 240, y: 210), PDFPointValue(x: 60, y: 210)
        ]
        var callout = shape(
            [CanvasStroke(points: corners, closed: true, filled: false)],
            color: ColorRGBA(red: 0.80, green: 0.19, blue: 0.13, alpha: 1),
            bounds: box
        )
        callout.kind = .callout
        callout.textBox = box
        callout.text = "WWWWWWWWWWWWWWWWWWWWWWWWWWWW"
        callout.fontSize = 13
        callout.lineWidth = 0.5
        view.shapes = [callout]
        let rep = render(view)
        let rect = transform.viewRect(from: box).standardized
        // The frame: 0.5 pt stored, drawn at least 1.5 pt — the device pixel just inside the
        // edge is solid ink (a 0.5 pt frame would only half-cover it).
        let inner = color(rep, view, CGPoint(x: rect.midX, y: rect.minY + 0.4))
        #expect(inner.redComponent > 0.6 && inner.greenComponent < 0.5, "the frame must be ≥ 1.5 pt, got \(inner)")
        // The padding: between the frame and the text, on the text's first line, only backing.
        let inset = CanvasMarkupStyle.calloutTextInset(for: rect)
        #expect(inset == ZPDFSpacing.m)
        let padding = color(rep, view, CGPoint(x: rect.minX + inset / 2 + 1, y: rect.minY + inset + 6))
        #expect(padding.greenComponent > 0.85, "the text must not touch the frame, got \(padding)")
        // The text is darker than the frame's ink.
        let deeper = CanvasMarkupStyle.rgba(CanvasMarkupStyle.calloutTextInk(forInk: NSColor(srgbRed: 0.8, green: 0.19, blue: 0.13, alpha: 1)))
        #expect(deeper.red < 0.8 && deeper.red > 0.5)
        // Small boxes keep text room.
        #expect(CanvasMarkupStyle.calloutTextInset(for: CGRect(x: 0, y: 0, width: 40, height: 14)) < 3)
    }

    @Test("A revision cloud is outward semicircular bumps meeting in cusps, never under 8 pt")
    func cloudIsOutwardBumps() {
        let ring = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 68, y: 0),
                    PDFPointValue(x: 68, y: 50), PDFPointValue(x: 0, y: 50)]
        // The QA cloud (68 × 50) used to get a 5.7 pt scallop; the floor is 8.
        let radius = CanvasSceneBuilder.cloudScallopRadius(of: ring)
        #expect(radius == 8)
        for drawn in [ring, Array(ring.reversed())] {
            let outline = ZenitMarkupGeometry.cloudOutline(drawn, radius: radius)
            // Every sample lies on or outside the ring: every bump bulges away from the area.
            let inside = outline.filter { $0.x > 1e-6 && $0.x < 68 - 1e-6 && $0.y > 1e-6 && $0.y < 50 - 1e-6 }
            #expect(inside.isEmpty, "\(inside.count) samples inside the cloud's area")
            // The bottom edge: 68 / 16 → 4 bumps of chord 17, each a semicircle of radius 8.5.
            let bottom = outline.filter { $0.y <= 1e-6 }
            let depth = -(bottom.map(\.y).min() ?? 0)
            #expect(abs(depth - 8.5) < 0.2, "a bump must be a semicircle as deep as half its chord, got \(depth)")
            // A semicircle leaves the edge at a right angle: 1/12 of a turn in, the sample is
            // far out (sin 15° · r ≈ 2.2) and barely along (r − cos 15° · r ≈ 0.29).
            let steep = outline.contains { abs($0.y + 2.2) < 0.1 && ($0.x < 0.5 || abs($0.x - 17) < 0.5 || abs($0.x - 51) < 0.5 || abs($0.x - 68) < 0.5) }
            #expect(steep, "bumps must meet in cusps, not flow into each other as a wave")
        }
    }

    // MARK: - Inks on paper

    @Test("Live feedback resolves against the paper, so it keeps contrast in the dark appearance")
    func liveInkKeepsContrastInDark() throws {
        let (view, transform) = makeView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.livePoints = [PDFPointValue(x: 60, y: 150), PDFPointValue(x: 240, y: 150)]
        let rep = render(view)
        let mid = transform.viewPoint(from: PDFPointValue(x: 150, y: 150))
        let ink = CanvasMarkupStyle.rgba(color(rep, view, mid))
        let paper = CanvasMarkupStyle.rgba(CanvasMarkupStyle.paper)
        #expect(ink.contrastRatio(against: paper) >= 3,
                "the live stroke must read on white paper in dark mode, got \(ink.hexString)")
        // The snap and selection inks borrowed from the chrome are pinned to their paper value.
        for token in [ZPDFColorToken.selection, .snapHighlight, .warning] {
            let onPaper = CanvasMarkupStyle.rgba(CanvasMarkupStyle.onPaper(token))
            #expect(onPaper.contrastRatio(against: paper) >= 3, "\(token) on paper: \(onPaper.hexString)")
        }
    }

    @Test("The canvas draw files take every colour from a token or the markup's own data")
    func noRawColourLiterals() throws {
        let canvas = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZenitPDFAppKit/Canvas")
        let forbidden = try NSRegularExpression(pattern:
            #"NSColor\.(white|black|red|green|blue|yellow|orange|gray|system\w+|labelColor|windowBackgroundColor|controlAccentColor)\b|NSColor\((white|calibratedRed|red|deviceRed):|#colorLiteral|hex:\s*0x"#)
        for file in ["CanvasPageView.swift", "CanvasMarkupStyle.swift", "CanvasLiveState.swift"] {
            let source = try String(contentsOf: canvas.appendingPathComponent(file), encoding: .utf8)
            let hits = forbidden.matches(in: source, range: NSRange(source.startIndex..., in: source))
            #expect(hits.isEmpty, "\(file) has \(hits.count) raw colour literal(s)")
        }
    }
}
