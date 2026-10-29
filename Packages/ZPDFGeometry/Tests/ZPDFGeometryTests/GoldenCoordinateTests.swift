import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFGeometry

/// The golden coordinate cases enumerated in spec 9.3.
@Suite("Golden coordinates (spec 9.3)")
struct GoldenCoordinateTests {

    private func converter(
        _ page: PageDescriptor,
        zoom: Double = 1,
        anchor: CGPoint = .zero,
        backingScale: Double = 1,
        flipped: Bool = false
    ) throws -> PageCoordinateConverter {
        try PageCoordinateConverter(
            page: page,
            layout: PageViewLayout(
                anchor: anchor,
                zoom: zoom,
                backingScale: backingScale,
                isViewFlipped: flipped
            )
        )
    }

    private func expectClose(
        _ actual: CGPoint,
        _ expected: CGPoint,
        tolerance: Double = 1e-9,
        _ comment: Comment? = nil
    ) {
        #expect(abs(Double(actual.x - expected.x)) <= tolerance, comment)
        #expect(abs(Double(actual.y - expected.y)) <= tolerance, comment)
    }

    private func expectClose(
        _ actual: PDFPoint,
        _ expected: PDFPoint,
        tolerance: Double = 1e-9,
        _ comment: Comment? = nil
    ) {
        #expect(abs(actual.x - expected.x) <= tolerance, comment)
        #expect(abs(actual.y - expected.y) <= tolerance, comment)
    }

    // MARK: - Rotation

    @Test("Rotation 0 maps the four page corners to the four view corners")
    func rotationZero() throws {
        let c = try converter(Fixture.letter())
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 0)), CGPoint(x: 612, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 792)), CGPoint(x: 612, y: 792))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 792)), CGPoint(x: 0, y: 792))
        #expect(c.displayedSize == CGSize(width: 612, height: 792))
    }

    @Test("Rotation 90 turns the page clockwise and swaps the displayed axes")
    func rotationNinety() throws {
        let c = try converter(Fixture.letter(rotation: .degrees90))
        #expect(c.displayedSize == CGSize(width: 792, height: 612))
        // Page bottom-left goes to display top-left under a clockwise quarter turn.
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 0, y: 612))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 0)), CGPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 792)), CGPoint(x: 792, y: 612))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 792)), CGPoint(x: 792, y: 0))
    }

    @Test("Rotation 180 mirrors both axes")
    func rotationOneEighty() throws {
        let c = try converter(Fixture.letter(rotation: .degrees180))
        #expect(c.displayedSize == CGSize(width: 612, height: 792))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 612, y: 792))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 792)), CGPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 306, y: 396)), CGPoint(x: 306, y: 396))
    }

    @Test("Rotation 270 turns the page counter-clockwise")
    func rotationTwoSeventy() throws {
        let c = try converter(Fixture.letter(rotation: .degrees270))
        #expect(c.displayedSize == CGSize(width: 792, height: 612))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 792, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 792)), CGPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 792)), CGPoint(x: 0, y: 612))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 0)), CGPoint(x: 792, y: 612))
    }

    @Test("Every rotation round-trips exactly", arguments: PageRotation.allCases)
    func rotationRoundTrip(rotation: PageRotation) throws {
        let c = try converter(Fixture.letter(rotation: rotation), zoom: 3.7)
        for point in [
            PDFPoint(x: 0, y: 0),
            PDFPoint(x: 612, y: 792),
            PDFPoint(x: 123.456, y: 654.321),
            PDFPoint(x: -40, y: 900)
        ] {
            let back = try c.viewToPage(try c.pageToView(point))
            expectClose(back, point, tolerance: 1e-9)
        }
    }

    // MARK: - Boxes

    @Test("Crop box different from media box anchors the view on the crop box")
    func cropBoxDiffersFromMediaBox() throws {
        let page = PageDescriptor(
            id: Fixture.pageID(9),
            documentID: Fixture.documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: -100, y: -50, width: 1000, height: 800),
                crop: PDFRect(x: 0, y: 0, width: 800, height: 600)
            )
        )
        let c = try converter(page)
        #expect(c.displayedSize == CGSize(width: 800, height: 600))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 800, y: 600)), CGPoint(x: 800, y: 600))
        // A media-box point outside the crop box converts to a negative view coordinate rather
        // than being clamped: clipping is the renderer's job, not the converter's.
        expectClose(try c.pageToView(PDFPoint(x: -100, y: -50)), CGPoint(x: -100, y: -50))
    }

    @Test("Negative box origins are subtracted, not ignored")
    func negativeBoxOrigins() throws {
        let c = try converter(Fixture.negativeOriginCropped())
        #expect(c.displayedSize == CGSize(width: 300, height: 200))
        expectClose(try c.pageToView(PDFPoint(x: -100, y: -50)), CGPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 200, y: 150)), CGPoint(x: 300, y: 200))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 100, y: 50))
        expectClose(try c.viewToPage(CGPoint(x: 0, y: 0)), PDFPoint(x: -100, y: -50))
    }

    @Test("Negative origins combine with rotation 90")
    func negativeOriginsRotated() throws {
        let c = try converter(Fixture.negativeOriginCropped(rotation: .degrees90))
        // Crop is 300 wide, 200 high; rotated display is 200 x 300.
        #expect(c.displayedSize == CGSize(width: 200, height: 300))
        // Crop-local (0, 0) -> rotated (0, cropWidth) = (0, 300).
        expectClose(try c.pageToView(PDFPoint(x: -100, y: -50)), CGPoint(x: 0, y: 300))
        // Crop-local (300, 200) -> rotated (200, 0).
        expectClose(try c.pageToView(PDFPoint(x: 200, y: 150)), CGPoint(x: 200, y: 0))
    }

    // MARK: - Zoom and Retina

    @Test("Zoom 5 % and 6400 % are both supported and exact")
    func zoomExtremes() throws {
        let minimum = try converter(Fixture.letter(), zoom: PageViewLayout.minimumZoom)
        expectClose(try minimum.pageToView(PDFPoint(x: 200, y: 400)), CGPoint(x: 10, y: 20))

        let maximum = try converter(Fixture.letter(), zoom: PageViewLayout.maximumZoom)
        expectClose(try maximum.pageToView(PDFPoint(x: 1, y: 1)), CGPoint(x: 64, y: 64))

        #expect(throws: GeometryError.zoomOutOfRange(0.04)) {
            _ = try self.converter(Fixture.letter(), zoom: 0.04)
        }
        #expect(throws: GeometryError.zoomOutOfRange(64.1)) {
            _ = try self.converter(Fixture.letter(), zoom: 64.1)
        }
    }

    @Test("Round trip stays sub-nanopoint across the whole zoom range")
    func zoomRoundTripPrecision() throws {
        let zooms = [0.05, 0.1, 0.25, 1.0, 2.0, 7.5, 16.0, 33.3, 64.0]
        for zoom in zooms {
            let c = try converter(
                Fixture.negativeOriginCropped(rotation: .degrees270),
                zoom: zoom,
                anchor: CGPoint(x: -37.5, y: 1234.75)
            )
            let point = PDFPoint(x: 13.37, y: -21.5)
            let back = try c.viewToPage(try c.pageToView(point))
            #expect(abs(back.x - point.x) < 1e-9, "zoom \(zoom)")
            #expect(abs(back.y - point.y) < 1e-9, "zoom \(zoom)")
        }
    }

    @Test("Retina scale 1 and 2 leave view-point conversion untouched")
    func retinaDoesNotAffectPointConversion() throws {
        let one = try converter(Fixture.letter(), zoom: 2, backingScale: 1)
        let two = try converter(Fixture.letter(), zoom: 2, backingScale: 2)
        let point = PDFPoint(x: 100, y: 200)
        #expect(try one.pageToView(point) == (try two.pageToView(point)))
    }

    @Test("Screen tolerance converts by zoom only")
    func toleranceConversion() throws {
        let wide = try converter(Fixture.letter(), zoom: 0.05, backingScale: 2)
        #expect(try wide.screenToleranceToPage(pixels: 12) == 240)

        let close = try converter(Fixture.letter(), zoom: 64, backingScale: 2)
        #expect(try close.screenToleranceToPage(pixels: 12) == 0.1875)

        // A user-facing snap radius must feel identical on Retina and non-Retina.
        let nonRetina = try converter(Fixture.letter(), zoom: 1, backingScale: 1)
        let retina = try converter(Fixture.letter(), zoom: 1, backingScale: 2)
        #expect(
            try nonRetina.screenToleranceToPage(pixels: 12)
                == (try retina.screenToleranceToPage(pixels: 12))
        )

        #expect(throws: GeometryError.invalidTolerance(-1)) {
            _ = try wide.screenToleranceToPage(pixels: -1)
        }
    }

    // MARK: - Flipped views

    @Test("A flipped view mirrors y and nothing else")
    func flippedView() throws {
        let c = try converter(Fixture.letter(), flipped: true)
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 0)), CGPoint(x: 0, y: 792))
        expectClose(try c.pageToView(PDFPoint(x: 0, y: 792)), CGPoint(x: 0, y: 0))
        expectClose(try c.viewToPage(CGPoint(x: 0, y: 792)), PDFPoint(x: 0, y: 0))
        expectClose(try c.pageToView(PDFPoint(x: 612, y: 396)), CGPoint(x: 612, y: 396))
    }

    // MARK: - Errors

    @Test("A crop box escaping the media box is rejected at construction")
    func invalidBoxesRejected() throws {
        let page = PageDescriptor(
            id: Fixture.pageID(5),
            documentID: Fixture.documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 100, height: 100),
                crop: PDFRect(x: 50, y: 50, width: 100, height: 100)
            )
        )
        #expect(throws: PageGeometryError.cropBoxOutsideMediaBox) {
            _ = try PageCoordinateConverter(page: page, layout: PageViewLayout())
        }
    }

    @Test("Rect conversion is correct under rotation, where corner arithmetic is not")
    func rectConversionUnderRotation() throws {
        let c = try converter(Fixture.letter(rotation: .degrees90), zoom: 2)
        let pageRect = PDFRect(x: 100, y: 200, width: 50, height: 80)
        let viewRect = try c.pageToView(pageRect)
        let back = try c.viewToPage(viewRect)
        #expect(abs(back.minX - pageRect.minX) < 1e-9)
        #expect(abs(back.minY - pageRect.minY) < 1e-9)
        #expect(abs(back.width - pageRect.width) < 1e-9)
        #expect(abs(back.height - pageRect.height) < 1e-9)
        // Under 90 degrees the view rect's width comes from the page rect's height.
        #expect(abs(Double(viewRect.width) - 160) < 1e-9)
        #expect(abs(Double(viewRect.height) - 100) < 1e-9)
    }
}
