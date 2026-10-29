import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Golden scenes for **the canvas's own** stamp path.
///
/// # Why these exist
///
/// The renderer has had scenes and goldens for imported artwork since artwork import first shipped, and a
/// stamp placed on the canvas still drew as a box with text in it. That is
/// exactly what a golden on the renderer path cannot catch: the renderer was right, the canvas
/// never asked it anything, and every test in the repository agreed with both. So the pixels
/// asserted here come out of `CanvasPageView.draw(_:)` — the shipping view, the one the
/// estimator looks at — and not out of `ZPDFRenderer`.
///
/// The scenes are the three claims the feature makes: **artwork is drawn**, **a vector stamp
/// gains detail with magnification while its raster twin does not**, and **a rotated stamp's
/// artwork turns with its frame**.
@MainActor
@Suite(.appTierSerialised)
struct CanvasStampArtworkTests {

    private let pageBox = PDFRectValue(x: 0, y: 0, width: 200, height: 200)

    private func transform(zoom: CGFloat) -> PageDisplayTransform {
        PageDisplayTransform(pageBox: pageBox, rotation: 0, zoom: zoom, origin: .zero)
    }

    /// One rendered canvas, plus the pixels-per-point the rep was cached at.
    ///
    /// `bitmapImageRepForCachingDisplay` allocates at the display's backing scale, so on a
    /// Retina machine the rep is twice the view's size in points. Every assertion below is
    /// written in *view* coordinates and goes through this, because sampling the rep directly
    /// reads a point a quarter of the way into the image and passes for the wrong reason.
    private struct Rendered {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        func colour(atViewX x: CGFloat, y: CGFloat) -> NSColor {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
        }

        /// Whether the pixel at a view point carries the stamp's red ink.
        func isInked(atViewX x: CGFloat, y: CGFloat) -> Bool {
            let colour = colour(atViewX: x, y: y)
            return colour.redComponent > 0.5 && colour.blueComponent < 0.5
        }

        /// How many pixels of the rep are the stamp's own red — so "is the artwork there" is a
        /// count rather than a judgement.
        var redPixels: Int {
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if colour.redComponent > 0.6, colour.greenComponent < 0.35, colour.blueComponent < 0.35 {
                        count += 1
                    }
                }
            }
            return count
        }

        /// How many times the image changes between ink and no ink along one view row.
        ///
        /// The same measurement `ImportedArtworkZoomTests` makes on the renderer path, and it
        /// is the one that distinguishes the two artwork kinds: a vector picture drawn as
        /// geometry gains transitions as it is magnified, because more of its contours
        /// separate; a mosaic has a fixed cell count and cannot.
        func inkTransitions(atViewY y: CGFloat) -> Int {
            var transitions = 0
            var previous = false
            let row = Int(y * scale)
            for x in 0..<rep.pixelsWide {
                let colour = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB)
                let inked = (colour?.redComponent ?? 0) > 0.5 && (colour?.blueComponent ?? 1) < 0.5
                if inked != previous { transitions += 1 }
                previous = inked
            }
            return transitions
        }
    }

    private func render(_ view: CanvasPageView, size: CGSize) -> Rendered {
        view.frame = CGRect(origin: .zero, size: size)
        view.backingScaleOverride = 1
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return Rendered(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width)
    }

    /// A comb of `bars` vertical strokes across unit space: a resolution target, and the
    /// simplest artwork whose detail is countable.
    private func comb(bars: Int, kind: ZPDFContracts.StampArtworkKind) -> ArtworkGeometry {
        var regions: [ArtworkRegion] = []
        let pitch = 1.0 / Double(bars)
        for bar in 0..<bars {
            let x0 = Double(bar) * pitch
            let x1 = x0 + pitch * 0.4
            regions.append(ArtworkRegion(outer: [
                PDFPoint(x: x0, y: 0.05),
                PDFPoint(x: x1, y: 0.05),
                PDFPoint(x: x1, y: 0.95),
                PDFPoint(x: x0, y: 0.95)
            ]))
        }
        return ArtworkGeometry(kind: kind, regions: regions, sourceAspectRatio: 1)
    }

    private func stampShape(
        placement: CanvasStampPlacement,
        id: UUID = UUID()
    ) -> CanvasMarkupShape {
        CanvasMarkupShape(
            id: id,
            pageID: UUID(),
            color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [CanvasStroke(points: placement.corners, closed: true, filled: false)],
            counts: [],
            stamp: placement,
            bounds: placement.boundingBox,
            hidden: false,
            caption: nil,
            kind: .stamp
        )
    }

    // MARK: - The artwork is on the canvas at all

    @Test("A stamp with artwork draws the artwork, not an empty box")
    func drawsTheArtwork() {
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 80,
            heightPoints: 80,
            rotationDegrees: 0,
            artwork: comb(bars: 4, kind: .vector),
            artworkKind: .vector
        )
        let view = CanvasPageView()
        view.transform = transform(zoom: 1)
        view.shapes = [stampShape(placement: placement)]
        let withArtwork = render(view, size: CGSize(width: 200, height: 200)).redPixels

        // The same stamp with its artwork missing — the state every stamp in the product was
        // in before this fix: a border, and nothing inside it.
        var bare = placement
        bare.artwork = nil
        let bareView = CanvasPageView()
        bareView.transform = transform(zoom: 1)
        bareView.shapes = [stampShape(placement: bare)]
        let withoutArtwork = render(bareView, size: CGSize(width: 200, height: 200)).redPixels

        #expect(withoutArtwork > 0, "the border is drawn either way")
        #expect(
            withArtwork > withoutArtwork * 3,
            "artwork must add ink to the box: \(withArtwork) vs \(withoutArtwork)"
        )
    }

    @Test("A stamp whose artwork the project no longer has still draws its frame and its text")
    func missingArtworkIsVisible() {
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 100,
            heightPoints: 40,
            rotationDegrees: 0,
            artwork: nil,
            artworkKind: .vector,
            lines: ["APPROVED"]
        )
        let view = CanvasPageView()
        view.transform = transform(zoom: 1)
        view.shapes = [stampShape(placement: placement)]
        #expect(
            render(view, size: CGSize(width: 200, height: 200)).redPixels > 0,
            "a stamp with no artwork must not become invisible"
        )
    }

    // MARK: - Vector stays vector, on the canvas path

    @Test("Magnifying a vector stamp reveals more of its geometry; its raster twin does not")
    func vectorGainsDetailAndRasterDoesNot() {
        // Sixty-four bars in a 40-point box: at 1× the comb is finer than the pixel grid and
        // most of it merges, at 6× it separates. A mosaic of eight cells is fully resolved at
        // 1× already and cannot separate further however far it is magnified, which is the
        // whole difference between the two kinds and the reason the claim is measurable.
        func transitions(artwork: ArtworkGeometry, zoom: CGFloat) -> Int {
            // A 40-point box, so the whole comb is inside the view at **both** zooms. A comb
            // that runs off the edge at 6× loses transitions to the clip and the measurement
            // stops being about resolution.
            let placement = CanvasStampPlacement(
                anchor: PDFPointValue(x: 100, y: 100),
                widthPoints: 40,
                heightPoints: 40,
                rotationDegrees: 0,
                artwork: artwork,
                artworkKind: artwork.kind
            )
            let view = CanvasPageView()
            view.transform = PageDisplayTransform(
                pageBox: pageBox,
                rotation: 0,
                zoom: zoom,
                // Keep the stamp's centre at the same view point at both zooms, so the row
                // sampled is the same row through the picture.
                origin: CGPoint(x: 200 - 100 * zoom, y: 200 - 100 * zoom)
            )
            view.shapes = [stampShape(placement: placement)]
            return render(view, size: CGSize(width: 400, height: 400))
                .inkTransitions(atViewY: 200)
        }

        let vectorNear = transitions(artwork: comb(bars: 64, kind: .vector), zoom: 1)
        let vectorFar = transitions(artwork: comb(bars: 64, kind: .vector), zoom: 6)
        let rasterNear = transitions(artwork: comb(bars: 8, kind: .raster), zoom: 1)
        let rasterFar = transitions(artwork: comb(bars: 8, kind: .raster), zoom: 6)

        #expect(
            vectorFar > vectorNear,
            "vector artwork must resolve more detail when magnified: \(vectorNear) → \(vectorFar)"
        )
        #expect(
            rasterFar == rasterNear,
            "a mosaic's cell count is fixed at import: \(rasterNear) → \(rasterFar)"
        )
    }

    @Test("A raster mosaic cell keeps its own colour; vector artwork takes the stamp's")
    func mosaicCellsKeepTheirColour() {
        let blue = ArtworkGeometry(
            kind: .raster,
            regions: [ArtworkRegion(
                outer: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0),
                    PDFPoint(x: 1, y: 1), PDFPoint(x: 0, y: 1)
                ],
                color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
            )],
            sourceAspectRatio: 1
        )
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 60,
            heightPoints: 60,
            rotationDegrees: 0,
            artwork: blue,
            artworkKind: .raster
        )
        let view = CanvasPageView()
        view.transform = transform(zoom: 1)
        view.shapes = [stampShape(placement: placement)]
        let centre = render(view, size: CGSize(width: 200, height: 200))
            .colour(atViewX: 100, y: 100)
        #expect(centre.blueComponent > 0.8, "the cell's own colour, not the stamp's red")
        #expect(centre.redComponent < 0.3)
    }

    // MARK: - Rotation

    @Test("A rotated stamp's artwork turns with its frame")
    func rotationTurnsTheArtwork() {
        // A single bar down the left third of unit space. Unrotated it lands left of centre;
        // turned a quarter, it lands below centre — and the frame goes with it.
        let bar = ArtworkGeometry(
            kind: .vector,
            regions: [ArtworkRegion(outer: [
                PDFPoint(x: 0.0, y: 0.0), PDFPoint(x: 0.25, y: 0.0),
                PDFPoint(x: 0.25, y: 1.0), PDFPoint(x: 0.0, y: 1.0)
            ])],
            sourceAspectRatio: 1
        )
        func inkedPoint(rotation: Double, at point: CGPoint) -> Bool {
            let placement = CanvasStampPlacement(
                anchor: PDFPointValue(x: 100, y: 100),
                widthPoints: 80,
                heightPoints: 80,
                rotationDegrees: rotation,
                artwork: bar,
                artworkKind: .vector
            )
            let view = CanvasPageView()
            view.transform = transform(zoom: 1)
            view.shapes = [stampShape(placement: placement)]
            return render(view, size: CGSize(width: 200, height: 200))
                .isInked(atViewX: point.x, y: point.y)
        }

        // The view is flipped: page y = 100 is view y = 100 on a 200-point page, and page
        // x = 70 (left of the anchor) is view x = 70.
        #expect(inkedPoint(rotation: 0, at: CGPoint(x: 70, y: 100)), "the bar is on the left")
        #expect(!inkedPoint(rotation: 0, at: CGPoint(x: 100, y: 130)), "and not below")

        // Ninety degrees counter-clockwise in page space puts the bar at the bottom of the
        // page, which in the flipped view is the larger y.
        #expect(inkedPoint(rotation: 90, at: CGPoint(x: 100, y: 130)), "turned, it is below")
        #expect(!inkedPoint(rotation: 90, at: CGPoint(x: 70, y: 100)), "and no longer on the left")
    }

    @Test("A rotated stamp's frame, artwork and bounding box are one rotation")
    func rotationIsAppliedOnce() {
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 100,
            heightPoints: 20,
            rotationDegrees: 90,
            artwork: nil,
            artworkKind: .none
        )
        // A 100 × 20 box turned a quarter is 20 wide and 100 tall.
        let box = placement.boundingBox
        #expect(abs(box.size.width - 20) < 1e-6, "got \(box.size.width)")
        #expect(abs(box.size.height - 100) < 1e-6, "got \(box.size.height)")
        // The artwork's unit centre is the anchor at every rotation, which is what keeps the
        // seal concentric with its frame.
        let centre = placement.pagePoint(unit: PDFPoint(x: 0.5, y: 0.5))
        #expect(abs(centre.x - 100) < 1e-9 && abs(centre.y - 100) < 1e-9)
    }

    // MARK: - The rotation handle

    @Test("Dragging the knob to a bearing sets that bearing, and Shift snaps it")
    func theKnobMeasuresAnAngle() {
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 40,
            heightPoints: 40,
            rotationDegrees: 0
        )
        // The knob rests straight up, so dragging it straight up is no rotation at all.
        #expect(abs(placement.rotation(draggingHandleTo: PDFPointValue(x: 100, y: 160))) < 1e-9)
        // Dragging it to the left of the anchor is a quarter turn counter-clockwise.
        let quarter = placement.rotation(draggingHandleTo: PDFPointValue(x: 40, y: 100))
        #expect(abs(quarter - 90) < 1e-6, "got \(quarter)")
        // Straight down is a half turn.
        let half = placement.rotation(draggingHandleTo: PDFPointValue(x: 100, y: 40))
        #expect(abs(half - 180) < 1e-6, "got \(half)")
        // A drag onto the anchor itself has no bearing and must not spin the stamp.
        #expect(placement.rotation(draggingHandleTo: PDFPointValue(x: 100, y: 100)) == 0)

        #expect(CanvasStampPlacement.snapped(97, increment: 15) == 90)
        #expect(CanvasStampPlacement.snapped(-5, increment: 15) == 0)
        #expect(CanvasStampPlacement.normalised(-90) == 270)
        #expect(CanvasStampPlacement.normalised(450) == 90)
    }

    @Test("The knob sits above the box's top edge and turns with it")
    func theKnobTurnsWithTheStamp() {
        let upright = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 40,
            heightPoints: 40,
            rotationDegrees: 0
        )
        let knob = upright.rotationHandlePoint(gapPoints: 10)
        #expect(abs(knob.x - 100) < 1e-9)
        #expect(abs(knob.y - 130) < 1e-9, "20 half-height plus a 10-point gap")

        var turned = upright
        turned.rotationDegrees = 90
        let turnedKnob = turned.rotationHandlePoint(gapPoints: 10)
        #expect(abs(turnedKnob.x - 70) < 1e-6, "got \(turnedKnob.x)")
        #expect(abs(turnedKnob.y - 100) < 1e-6, "got \(turnedKnob.y)")
    }

    @Test("A selected stamp draws a rotation knob; an unselected one does not")
    func theKnobIsDrawnForASelectedStamp() {
        let placement = CanvasStampPlacement(
            anchor: PDFPointValue(x: 100, y: 100),
            widthPoints: 40,
            heightPoints: 40,
            rotationDegrees: 0
        )
        let id = UUID()
        func rendered(selected: Bool) -> Rendered {
            let view = CanvasPageView()
            view.transform = transform(zoom: 1)
            view.shapes = [stampShape(placement: placement, id: id)]
            view.selection = selected ? [id] : []
            return render(view, size: CGSize(width: 200, height: 200))
        }
        // The box's top edge is page y = 120, which in this flipped 200-point view is y = 80.
        // The knob sits 22 view points above it, so the stem runs through view y = 70 on the
        // stamp's centre line — a point that is bare canvas when nothing is selected.
        let withKnob = rendered(selected: true).colour(atViewX: 100, y: 70)
        let without = rendered(selected: false).colour(atViewX: 100, y: 70)
        let difference = abs(withKnob.redComponent - without.redComponent)
            + abs(withKnob.greenComponent - without.greenComponent)
            + abs(withKnob.blueComponent - without.blueComponent)
        #expect(
            difference > 0.1,
            "the stem of the rotation knob is the difference; got \(withKnob) vs \(without)"
        )
    }
}
