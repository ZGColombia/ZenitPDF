import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The committed pill grammar in the shipping canvas:
/// pills read label-prefixed ("Length A: 14.72 m", "Area C: 21.34 m²"), an area's pill
/// anchors INSIDE the polygon fill at its centroid, and a concave outline the centroid
/// escapes gets the edge-anchored fallback on a short leader — the design's
/// Count-caption pattern. The maths is pure (`AreaPillLayout`, mirroring the renderer's
/// `AreaPillPlacement`) and the pixels are asserted where they are produced.
@MainActor
@Suite(.appTierSerialised)
struct AreaPillTests {

    // MARK: - Caption grammar

    private func summary(label: String, kind: MeasurementKind?, fields: [MeasurementFieldSummary]) -> MarkupSummary {
        MarkupSummary(
            id: UUID(),
            kind: .measurement,
            measurementKind: kind,
            subject: "Length",
            label: label,
            pageLabel: "P1",
            pageID: UUID(),
            pageIndex: 0,
            author: "test",
            colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1),
            measurementFields: fields,
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: .zero
        )
    }

    private func lengthField(_ text: String, unit: String) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: .planLength,
            quantity: DecimalQuantity(value: 14.72, dimension: .length),
            displayText: text,
            displayUnitSymbol: unit
        )
    }

    @Test("The pill text is the label prefix plus the value — the design grammar")
    func captionCarriesTheLabelPrefix() {
        let labelled = summary(label: "Length A", kind: .length, fields: [lengthField("14.72", unit: "m")])
        #expect(CanvasSceneBuilder.caption(for: labelled) == "Length A: 14.72 m")

        let unlabelled = summary(label: "  ", kind: .length, fields: [lengthField("14.72", unit: "m")])
        #expect(CanvasSceneBuilder.caption(for: unlabelled) == "14.72 m",
                "a markup without a label keeps the bare value")

        let unmeasured = summary(label: "Note 1", kind: nil, fields: [])
        #expect(CanvasSceneBuilder.caption(for: unmeasured) == nil,
                "a markup without a value gets no pill at all")
    }

    // MARK: - Placement maths (view space, mirroring AreaPillPlacement)

    @Test("A convex polygon takes the pill at its centroid, no leader")
    func convexPolygonAnchorsAtTheCentroid() throws {
        let square = [
            CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
            CGPoint(x: 300, y: 260), CGPoint(x: 100, y: 260)
        ]
        let placement = try #require(AreaPillLayout.placement(
            polygon: square, pillHalfWidth: 40, pillHalfHeight: 10
        ))
        #expect(placement.isInterior)
        #expect(abs(placement.center.x - 200) < 1e-9)
        #expect(abs(placement.center.y - 180) < 1e-9)
    }

    /// The renderer suite pins the identical polygon in page space
    /// (`AreaPillPlacementTests`); this is the flipped view-space twin, so the two
    /// implementations cannot drift apart in what they claim about placement.
    @Test("The concave C falls back to a leader below the bottom vertex")
    func concaveCentroidFallsBackToTheLeader() throws {
        // The renderer's C-shape flipped into view space (y down): bottom is max y.
        let concaveC = [
            CGPoint(x: 200, y: 600), CGPoint(x: 440, y: 600), CGPoint(x: 440, y: 540),
            CGPoint(x: 260, y: 540), CGPoint(x: 260, y: 320), CGPoint(x: 440, y: 320),
            CGPoint(x: 440, y: 260), CGPoint(x: 200, y: 260)
        ]
        let centroid = try #require(AreaPillLayout.centroid(of: concaveC))
        #expect(!AreaPillLayout.contains(concaveC, point: centroid),
                "the case exists because the centroid must be outside the fill")

        let placement = try #require(AreaPillLayout.placement(
            polygon: concaveC, pillHalfWidth: 50, pillHalfHeight: 9
        ))
        #expect(!placement.isInterior)
        #expect(placement.leaderStart == CGPoint(x: 200, y: 600),
                "the anchor is the bottom vertex, ties on the smaller x")
        let end = try #require(placement.leaderEnd)
        #expect(end == CGPoint(x: 200, y: 600 + AreaPillLayout.leaderLength))
        #expect(placement.center.x == 200)
        #expect(abs(placement.center.y - (end.y + AreaPillLayout.leaderClearance + 9)) < 1e-9)
    }

    @Test("A pill too big for its polygon steps out even with the centroid inside")
    func oversizedPillFallsBack() throws {
        let smallTriangle = [
            CGPoint(x: 100, y: 130), CGPoint(x: 140, y: 130), CGPoint(x: 120, y: 100)
        ]
        let placement = try #require(AreaPillLayout.placement(
            polygon: smallTriangle, pillHalfWidth: 60, pillHalfHeight: 12
        ))
        #expect(!placement.isInterior)
    }

    @Test("Degenerate input places nothing rather than NaN")
    func degenerateInputIsRefused() {
        #expect(AreaPillLayout.placement(
            polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
            pillHalfWidth: 10, pillHalfHeight: 5
        ) == nil)
        #expect(AreaPillLayout.placement(
            polygon: [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)],
            pillHalfWidth: 10, pillHalfHeight: 5
        ) == nil)
    }

    // MARK: - Pixels

    private func renderedView(
        polygon: [PDFPointValue],
        pageSize: CGSize,
        caption: String
    ) -> (view: CanvasPageView, rep: NSBitmapImageRep, transform: PageDisplayTransform) {
        let view = CanvasPageView()
        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: pageSize.width, height: pageSize.height),
            rotation: 0,
            zoom: 1.0,
            origin: CGPoint(x: 10, y: 10)
        )
        view.transform = transform
        view.shapes = [
            CanvasMarkupShape(
                id: UUID(),
                pageID: UUID(),
                color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
                strokes: [CanvasStroke(points: polygon, closed: true, filled: true)],
                counts: [],
                bounds: PDFRectValue(x: 0, y: 0, width: pageSize.width, height: pageSize.height),
                hidden: false,
                caption: caption
            )
        ]
        view.frame = CGRect(origin: .zero, size: CGSize(
            width: pageSize.width + 40, height: pageSize.height + 60
        ))
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return (view, rep, transform)
    }

    private func color(_ rep: NSBitmapImageRep, of view: NSView, atView point: CGPoint) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
            .usingColorSpace(.sRGB) ?? .clear
    }

    @Test("A convex area draws its pill inside the fill, centred on the centroid")
    func convexAreaPillIsDrawnInsideTheFill() {
        // A 200 x 150 page-point rectangle; page (150, 125) is its centroid.
        let polygon = [
            PDFPointValue(x: 50, y: 50), PDFPointValue(x: 250, y: 50),
            PDFPointValue(x: 250, y: 200), PDFPointValue(x: 50, y: 200)
        ]
        let caption = "Area A: 5.00 m²"
        let (view, rep, transform) = renderedView(
            polygon: polygon, pageSize: CGSize(width: 300, height: 300), caption: caption
        )
        let center = transform.viewPoint(from: PDFPointValue(x: 150, y: 125))
        // Sample inside the pill's left padding, where no glyph paints: the pill is filled
        // with the markup's own ink (design round d7, "Area: 620 SF"),
        // unmistakably not the white sheet and not the light area tint.
        let size = CanvasMarkupStyle.pillBoxSize(forText: NSAttributedString(
            string: caption, attributes: CanvasPillTestSupport.pillTextAttributes
        ).size())
        let sample = CGPoint(x: center.x - size.width / 2 + 2, y: center.y)
        let pill = color(rep, of: view, atView: sample)
        #expect(pill.redComponent > 0.6 && pill.greenComponent < 0.4 && pill.blueComponent < 0.4,
                "the pill's ink fill must sit on the centroid, got \(pill)")
    }

    @Test("A concave area hangs its pill below the bottom vertex on a leader")
    func concaveAreaPillFallsBackToTheLeader() throws {
        // A "C" in page points (y-up) whose centroid lands in the notch.
        let polygon = [
            PDFPointValue(x: 100, y: 130), PDFPointValue(x: 220, y: 130),
            PDFPointValue(x: 220, y: 160), PDFPointValue(x: 130, y: 160),
            PDFPointValue(x: 130, y: 270), PDFPointValue(x: 220, y: 270),
            PDFPointValue(x: 220, y: 300), PDFPointValue(x: 100, y: 300)
        ]
        let caption = "Area B: 1.23 m²"
        let (view, rep, transform) = renderedView(
            polygon: polygon, pageSize: CGSize(width: 300, height: 340), caption: caption
        )
        let viewPolygon = polygon.map { transform.viewPoint(from: $0) }
        let size = CanvasMarkupStyle.pillBoxSize(forText: NSAttributedString(
            string: caption, attributes: CanvasPillTestSupport.pillTextAttributes
        ).size())
        let placement = try #require(AreaPillLayout.placement(
            polygon: viewPolygon,
            pillHalfWidth: size.width / 2,
            pillHalfHeight: size.height / 2
        ))
        #expect(!placement.isInterior, "this polygon exists to force the fallback")

        // The leader's midpoint paints in the markup's ink.
        let start = try #require(placement.leaderStart)
        let end = try #require(placement.leaderEnd)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let leader = color(rep, of: view, atView: mid)
        #expect(leader.redComponent > 0.6 && leader.greenComponent < 0.4,
                "the leader must be drawn from the bottom vertex, got \(leader)")

        // The pill sits at the fallback centre, not at the (escaped) centroid.
        let sample = CGPoint(
            x: placement.center.x - size.width / 2 + 2, y: placement.center.y
        )
        let pill = color(rep, of: view, atView: sample)
        #expect(pill.redComponent > 0.6 && pill.greenComponent < 0.4 && pill.blueComponent < 0.4,
                "the pill must hang below the leader, got \(pill)")
        let centroid = try #require(AreaPillLayout.centroid(of: viewPolygon))
        let notch = color(rep, of: view, atView: centroid)
        #expect(notch.brightnessComponent > 0.8,
                "nothing may be drawn at the centroid the outline escaped, got \(notch)")
    }
}
