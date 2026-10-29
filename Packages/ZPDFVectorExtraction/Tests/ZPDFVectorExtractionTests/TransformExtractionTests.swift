import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// CTM composition, form nesting, `/Rotate` and `/CropBox`.
///
/// `QUALITY_BAR` S10 and S11. The expected coordinates are the manifest's, and the
/// rotation formula is written out again here independently of the implementation, so
/// the test would catch a change of convention rather than follow it.
struct TransformExtractionTests {

    // MARK: - Nested form XObjects

    @Test("Two levels of form XObjects compose their matrices in PDF order")
    func nestedFormComposition() async throws {
        let result = try await ExtractionTestSupport.extract(.nestedFormXObjects)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability == .available)
        #expect(result.extraction.statistics.formInvocationCount == 2)
        #expect(result.extraction.statistics.maximumNestingDepthReached == 2)

        let outer = try #require(result.manifest.path(id: "outer-form-rect"))
        let inner = try #require(result.manifest.path(id: "inner-form-rect"))
        ExtractionTestSupport.expectVertices(of: outer, in: result.extraction)
        ExtractionTestSupport.expectVertices(of: inner, in: result.extraction)

        // Depth is recorded per primitive, and the two rectangles sit at different depths.
        let depths = Set(result.extraction.shapePrimitives.map(\.nestingDepth))
        #expect(depths == [1, 2])

        // The composed matrix is checked directly: the manifest records both the
        // untransformed form-space points and the matrix that maps them to page space,
        // so a reversed composition order is caught by value, not by eye.
        for path in [outer, inner] {
            let source = try #require(path.sourcePoints)
            let matrix = try #require(path.transform)
            for (sourcePoint, expectedPoint) in zip(source, path.points) {
                let mapped = matrix.apply(to: sourcePoint)
                #expect(abs(mapped.x - expectedPoint.x) <= ExtractionTestSupport.coordinateTolerance)
                #expect(abs(mapped.y - expectedPoint.y) <= ExtractionTestSupport.coordinateTolerance)
            }
        }

        // A uniform scale of 1.5 and 3 must show up in the stroke width, not only in the
        // coordinates: a snap UI that highlights the source primitive draws that width.
        let outerShape = try #require(result.extraction.shapePrimitives.first { $0.nestingDepth == 1 })
        let innerShape = try #require(result.extraction.shapePrimitives.first { $0.nestingDepth == 2 })
        #expect(abs(outerShape.strokeWidth - 1.5) <= 1e-12)
        #expect(abs(innerShape.strokeWidth - 3.0) <= 1e-12)
    }

    @Test("A form nesting cap of 1 stops at the outer form and says so")
    func nestingCapIsHonoured() async throws {
        var options = VectorExtractionOptions.standard
        options.budget.maximumFormNestingDepth = 1
        let result = try await ExtractionTestSupport.extract(.nestedFormXObjects, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability == .partial(reason: .formNestingDepthExceeded(limit: 1)))
        #expect(result.extraction.statistics.maximumNestingDepthReached == 1)
        #expect(result.extraction.primitives.allSatisfy { $0.nestingDepth <= 1 })
        // The outer rectangle still snaps: degrade to fewer candidates, never to wrong ones.
        let outer = try #require(result.manifest.path(id: "outer-form-rect"))
        ExtractionTestSupport.expectVertices(of: outer, in: result.extraction)
    }

    // MARK: - Rotation

    /// The rotation formula, written independently of the implementation.
    ///
    /// `/Rotate` turns the displayed page clockwise. In crop-box-relative space with the
    /// origin at the displayed page's lower-left corner, and with `w`/`h` the crop box's
    /// width and height, that is: 90° → `(v, w − u)`, 180° → `(w − u, h − v)`,
    /// 270° → `(h − v, u)`.
    private func expectedRotated(
        _ point: FixturePoint,
        rotation: Int,
        cropBox: FixtureRect
    ) -> CGPoint {
        let u = point.x - cropBox.llx
        let v = point.y - cropBox.lly
        let w = cropBox.width
        let h = cropBox.height
        switch rotation {
        case 90: return CGPoint(x: v, y: w - u)
        case 180: return CGPoint(x: w - u, y: h - v)
        case 270: return CGPoint(x: h - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    @Test(
        "Page-space convention pdfUserSpace leaves /Rotate out of the coordinates",
        arguments: [FixtureKind.rotation0, .rotation90, .rotation180, .rotation270]
    )
    func rotationInUserSpace(kind: FixtureKind) async throws {
        let result = try await ExtractionTestSupport.extract(kind)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: "rotation-marker"))
        #expect(result.extraction.pageTransform.convention == .pdfUserSpace)
        #expect(result.extraction.pageTransform.rotation == result.manifest.pages[0].rotation)
        #expect(result.extraction.pageTransform.matrix == .identity)
        ExtractionTestSupport.expectVertices(of: path, in: result.extraction)
    }

    @Test(
        "Page-space convention cropBoxRotated applies /Rotate exactly, and inverts exactly",
        arguments: [FixtureKind.rotation0, .rotation90, .rotation180, .rotation270]
    )
    func rotationInDisplaySpace(kind: FixtureKind) async throws {
        var options = VectorExtractionOptions.standard
        options.pageSpaceConvention = .cropBoxRotated
        let result = try await ExtractionTestSupport.extract(kind, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        let page = result.manifest.pages[0]
        let path = try #require(result.manifest.path(id: "rotation-marker"))
        let transform = result.extraction.pageTransform

        let quarterTurned = page.rotation == 90 || page.rotation == 270
        #expect(transform.canonicalWidth == (quarterTurned ? page.cropBox.height : page.cropBox.width))
        #expect(transform.canonicalHeight == (quarterTurned ? page.cropBox.width : page.cropBox.height))

        let extracted = ExtractionTestSupport.sortedVertices(of: result.extraction)
        for expectedSource in path.points {
            let expected = expectedRotated(expectedSource, rotation: page.rotation, cropBox: page.cropBox)
            let nearest = extracted.map { hypot($0.x - expected.x, $0.y - expected.y) }.min() ?? .infinity
            #expect(
                nearest <= ExtractionTestSupport.coordinateTolerance,
                "rotation \(page.rotation): nearest extracted vertex was \(nearest) from (\(expected.x), \(expected.y))"
            )
        }

        // S10: the page-space round trip is exact.
        for point in extracted {
            let roundTripped = transform.apply(to: transform.invert(point))
            #expect(abs(roundTripped.x - point.x) <= ExtractionTestSupport.roundTripTolerance)
            #expect(abs(roundTripped.y - point.y) <= ExtractionTestSupport.roundTripTolerance)
        }
    }

    // MARK: - Crop boxes

    @Test("A crop box inside the media box does not rebase user-space coordinates")
    func cropBoxSmallerThanMediaBox() async throws {
        let result = try await ExtractionTestSupport.extract(.cropBoxSmallerThanMediaBox)
        defer { ExtractionTestSupport.remove(result.directory) }

        let path = try #require(result.manifest.path(id: "crop-marker"))
        let page = result.manifest.pages[0]
        #expect(result.extraction.pageTransform.cropBox.minX == page.cropBox.llx)
        #expect(result.extraction.pageTransform.cropBox.minY == page.cropBox.lly)
        // The classic bug is reporting (28, 28) for the corner at (100, 100).
        ExtractionTestSupport.expectVertices(of: path, in: result.extraction)
    }

    @Test("Negative box origins survive in user space and rebase correctly in display space")
    func negativeOriginCropBox() async throws {
        let userSpace = try await ExtractionTestSupport.extract(.cropBoxNegativeOrigin)
        defer { ExtractionTestSupport.remove(userSpace.directory) }

        let path = try #require(userSpace.manifest.path(id: "negative-origin-line"))
        let page = userSpace.manifest.pages[0]
        #expect(page.mediaBox.llx == -100)
        #expect(page.cropBox.llx == -50)
        ExtractionTestSupport.expectVertices(of: path, in: userSpace.extraction)

        var options = VectorExtractionOptions.standard
        options.pageSpaceConvention = .cropBoxRotated
        let displaySpace = try await ExtractionTestSupport.extract(.cropBoxNegativeOrigin, options: options)
        defer { ExtractionTestSupport.remove(displaySpace.directory) }

        let primitive = try #require(displaySpace.extraction.primitives.first)
        guard case .line(let line) = primitive.geometry else {
            Issue.record("expected a line, got \(primitive.geometry)")
            return
        }
        // The line starts on the media box corner (-100, -50); relative to the crop box
        // corner (-50, -25) that is (-50, -25), which is legitimately outside the visible
        // area and must not be clamped away.
        #expect(abs(line.start.x - (-50)) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(line.start.y - (-25)) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(line.end.x - 190) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(line.end.y - 295) <= ExtractionTestSupport.coordinateTolerance)
        // Length is invariant under a rigid page transform.
        #expect(abs(line.length - path.length) <= ExtractionTestSupport.coordinateTolerance)
    }

    @Test("A /Rotate that is not a multiple of 90 is rounded, not trusted")
    func rotationNormalisation() {
        #expect(VectorPageTransform.normalise(0) == 0)
        #expect(VectorPageTransform.normalise(90) == 90)
        #expect(VectorPageTransform.normalise(-90) == 270)
        #expect(VectorPageTransform.normalise(450) == 90)
        #expect(VectorPageTransform.normalise(44) == 0)
        #expect(VectorPageTransform.normalise(46) == 90)
        #expect(VectorPageTransform.normalise(359) == 0)
    }
}
