import CoreGraphics
import Foundation
import Testing
import ZPDFContracts

@testable import ZPDFGeometry

/// The degenerate and extreme inputs a real drawing produces, pinned so a later refactor cannot
/// quietly regress them.
///
/// Unlike the contract package's adversarial suite, most of these passed on the first attempt —
/// the origin shift in the shoelace, the normalised collinearity measure and the algebraic
/// inverse in the coordinate converter were already doing their jobs. They are pinned anyway,
/// because "it happens to be right today" and "it is guarded" are different states. The two that
/// did fail are ``angleBetweenIdenticalVectors()`` and ``insetCollapses()``.
@Suite("Adversarial geometry")
struct AdversarialGeometryTests {

    private static let documentID = DocumentID(
        UUID(uuidString: "00000000-0000-0000-0000-00000000D0C1")!
    )
    private static let pageID = PageID(UUID(uuidString: "00000000-0000-0000-0000-00000000A6E1")!)
    private static let scaleID = ScaleID(UUID(uuidString: "00000000-0000-0000-0000-00000005CA1E")!)

    // MARK: - Three-point circle

    /// Collinear input has no circumcircle. The rejection is on the *normalised* measure, so it
    /// must hold at any coordinate magnitude — a collinear triple far from the origin forms its
    /// determinant from large numbers whose difference is zero, and the origin shift is what
    /// keeps that exact.
    @Test("A collinear or duplicated triple has no circumcircle")
    func collinearTriplesAreRejected() {
        let cases: [(String, PDFPoint, PDFPoint, PDFPoint)] = [
            ("collinear at origin", .init(x: 0, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 2)),
            ("collinear far away", .init(x: 1e6, y: 1e6), .init(x: 1e6 + 1, y: 1e6 + 1),
             .init(x: 1e6 + 2, y: 1e6 + 2)),
            ("collinear horizontal", .init(x: 0, y: 5), .init(x: 100, y: 5), .init(x: 250, y: 5)),
            ("collinear vertical", .init(x: 5, y: 0), .init(x: 5, y: 100), .init(x: 5, y: 250)),
            ("two points coincide", .init(x: 0, y: 0), .init(x: 0, y: 0), .init(x: 1, y: 0)),
            ("all three coincide", .init(x: 5, y: 5), .init(x: 5, y: 5), .init(x: 5, y: 5))
        ]
        for (name, a, b, c) in cases {
            #expect(throws: (any Error).self, "\(name) produced a circle") {
                try SegmentMath.circumcircle(a, b, c)
            }
        }
    }

    /// The threshold is dimensionless, so it must not depend on how big the triangle is: the same
    /// *shape* has to get the same verdict at 1 point across and at 1000 points across.
    @Test("Collinearity rejection is scale invariant")
    func collinearityIsScaleInvariant() throws {
        // Bend ratio 1e-12 of the span: rejected at every size.
        for span in [1.0, 100.0, 10_000.0] {
            #expect(throws: (any Error).self, "span \(span)") {
                try SegmentMath.circumcircle(
                    .init(x: 0, y: 0),
                    .init(x: span / 2, y: span * 1e-12),
                    .init(x: span, y: 0)
                )
            }
        }
        // Bend ratio 0.1 of the span: accepted at every size, with a radius that scales.
        var radii: [Double] = []
        for span in [1.0, 100.0, 10_000.0] {
            let circle = try SegmentMath.circumcircle(
                .init(x: 0, y: 0),
                .init(x: span / 2, y: span * 0.1),
                .init(x: span, y: 0)
            )
            radii.append(circle.radius / span)
        }
        for radius in radii.dropFirst() {
            #expect(abs(radius - radii[0]) < 1e-9, "radius/span drifted: \(radii)")
        }
    }

    /// A genuine circle must come back exactly enough to price.
    @Test("A well-conditioned circumcircle is accurate")
    func wellConditionedCircumcircle() throws {
        let circle = try SegmentMath.circumcircle(
            .init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: -1, y: 0)
        )
        #expect(abs(circle.radius - 1) < 1e-12)
        #expect(abs(circle.center.x) < 1e-12)
        #expect(abs(circle.center.y) < 1e-12)
    }

    // MARK: - Zero-length segments

    /// PDF content is full of zero-length stubs. Every predicate has to answer rather than divide
    /// by zero or return a NaN.
    @Test("Zero-length segments are answered, not divided by")
    func zeroLengthSegments() throws {
        let zero = SegmentGeometry(start: .init(x: 3, y: 4), end: .init(x: 3, y: 4))

        let nearest = SegmentMath.nearestPoint(on: zero, to: .init(x: 0, y: 0))
        #expect(nearest.distance == 5)
        #expect(nearest.t == 0)
        #expect(nearest.isEndpoint)
        #expect(nearest.point == PDFPoint(x: 3, y: 4))

        // Two coincident degenerate segments meet at their shared point.
        guard case .point(let hit, _, _) = SegmentMath.intersect(zero, zero) else {
            Issue.record("coincident degenerate segments did not report a point")
            return
        }
        #expect(hit == PDFPoint(x: 3, y: 4))

        // A degenerate segment far from another segment simply misses.
        let far = SegmentGeometry(start: .init(x: 100, y: 100), end: .init(x: 200, y: 100))
        #expect(SegmentMath.intersect(zero, far) == .none)

        // The infinite-line helpers have no answer at all and must say so.
        #expect(throws: GeometryError.degenerateSegment) {
            try SegmentMath.perpendicularFoot(
                from: .init(x: 0, y: 0), onLineThrough: .init(x: 1, y: 1), and: .init(x: 1, y: 1)
            )
        }
        #expect(throws: GeometryError.degenerateSegment) {
            try SegmentMath.signedDistance(
                from: .init(x: 0, y: 0), toLineThrough: .init(x: 1, y: 1), and: .init(x: 1, y: 1)
            )
        }
    }

    // MARK: - Near-degenerate polygons

    /// A sliver still has the area it has. The floor is for *zero*, not for *small*.
    @Test("A sliver polygon reports its real area")
    func sliverPolygon() throws {
        let sliver: [PDFPoint] = [.init(x: 0, y: 0), .init(x: 1000, y: 0), .init(x: 1000, y: 1e-9)]
        let area = PolygonMath.signedArea(sliver)
        #expect(abs(area - 5e-7) < 1e-18)
        #expect(area > GeometryEpsilon.standard.areaFloor)

        let flat: [PDFPoint] = [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0)]
        #expect(PolygonMath.signedArea(flat) == 0)
    }

    /// The origin shift is the whole reason the shoelace survives far-from-origin geometry: the
    /// naive form loses four significant digits on a page-coordinate square at 1e9.
    @Test("Shoelace area is exact regardless of distance from the origin")
    func areaIsTranslationInvariant() {
        for base in [0.0, 1e4, 1e6, 1e9] {
            let square: [PDFPoint] = [
                .init(x: base, y: base), .init(x: base + 100, y: base),
                .init(x: base + 100, y: base + 100), .init(x: base, y: base + 100)
            ]
            #expect(PolygonMath.signedArea(square) == 10_000, "drifted at base \(base)")
            #expect(PolygonMath.perimeter(square) == 400, "perimeter drifted at base \(base)")
        }
    }

    /// A point exactly on an edge or a vertex is the commonest case in a takeoff, because the
    /// user snapped to it. It must be reported as boundary, not guessed either way.
    @Test("A point on an edge or vertex classifies as boundary")
    func boundaryClassification() {
        let square: [PDFPoint] = [
            .init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 10, y: 10), .init(x: 0, y: 10)
        ]
        #expect(PolygonMath.classify(.init(x: 0, y: 0), in: square) == .onBoundary)
        #expect(PolygonMath.classify(.init(x: 5, y: 0), in: square) == .onBoundary)
        #expect(PolygonMath.classify(.init(x: 10, y: 10), in: square) == .onBoundary)
        #expect(PolygonMath.classify(.init(x: 5, y: 5), in: square) == .inside)
        #expect(PolygonMath.classify(.init(x: -1, y: 5), in: square) == .outside)
        // Within the on-segment epsilon, either side of the edge is still the boundary.
        #expect(PolygonMath.classify(.init(x: 5, y: 1e-7), in: square) == .onBoundary)
        #expect(PolygonMath.classify(.init(x: 5, y: -1e-7), in: square) == .onBoundary)
    }

    // MARK: - Scale extremes

    /// `uniform()` compares in `Decimal` and `isExtreme` compares the `Double` projection. They
    /// must agree, or a scale is created and then immediately flagged as impossible.
    @Test("The sane-range guard and isExtreme agree at the boundary")
    func saneRangeAndIsExtremeAgree() throws {
        for text in [
            "0.000001", "0.0000010000000001", "0.0000009999999999",
            "10000", "9999.999999", "10000.000001", "1", "0.001"
        ] {
            let factor = try #require(Decimal(string: text, locale: nil))
            let accepted = (try? ScaleTransform.uniform(
                id: Self.scaleID, metresPerPoint: factor, units: .metric, source: .preset
            )) != nil
            let scale = try ScaleTransform.uniform(
                id: Self.scaleID, metresPerPoint: factor, units: .metric,
                source: .preset, allowExtreme: true
            )
            #expect(accepted == !scale.isExtreme, "\(text): accepted=\(accepted) isExtreme=\(scale.isExtreme)")
        }
    }

    /// Under a separate-XY scale a bare page distance has no length until a direction is given.
    /// The area factor is the determinant, which is the only form that is also right under shear.
    @Test("A separate-XY scale refuses a directionless length and uses det(A) for area")
    func separateXYScale() throws {
        let scale = try ScaleTransform.separateXY(
            id: Self.scaleID,
            metresPerPointX: try #require(Decimal(string: "0.01", locale: nil)),
            metresPerPointY: try #require(Decimal(string: "0.02", locale: nil)),
            units: .metric,
            source: .calibrationXY
        )
        #expect(!scale.isUniform)
        #expect(scale.areaFactor == (try #require(Decimal(string: "0.0002", locale: nil))))

        // Lengths along each axis follow that axis's factor: 100 pt is 1 m along x, 2 m along y.
        // (The deleted `ScaleApplication` also refused a directionless length and a circle under
        // this scale, R-174. The engine that production measures through has no directionless
        // length — every length goes from two endpoints through the matrix, as the two lines
        // below do — and its refusal of a radius under a separate-XY scale is asserted in
        // ZPDFMeasurementEngine's `EngineBehaviourTests.radiusNonUniform`.)
        #expect(abs(scale.matrix.length(from: .init(x: 0, y: 0), to: .init(x: 100, y: 0)) - 1) <= 1e-15)
        #expect(abs(scale.matrix.length(from: .init(x: 0, y: 0), to: .init(x: 0, y: 100)) - 2) <= 1e-15)
    }

    // MARK: - Coordinate conversion

    /// A negative crop origin, every `/Rotate`, both view conventions and a zoom at each end of
    /// the legal range. `viewToPage` is the algebraic inverse of `pageToView`, so the round trip
    /// has to close to a few ulps in all of them — 90 and 270 included, where the displayed width
    /// and height swap.
    @Test("Round trip closes for every rotation, flip and zoom, with a negative crop origin")
    func coordinateRoundTrip() throws {
        let boxes = PageBoxes(
            media: PDFRect(x: -200, y: -150, width: 1000, height: 800),
            crop: PDFRect(x: -100, y: -50, width: 600, height: 400)
        )
        let probes: [PDFPoint] = [
            .init(x: -100, y: -50), .init(x: 500, y: 350), .init(x: 0, y: 0),
            .init(x: 123.456789, y: -7.891011)
        ]

        for rotation in PageRotation.allCases {
            let page = PageDescriptor(
                id: Self.pageID, documentID: Self.documentID, index: 0, label: "1",
                boxes: boxes, rotation: rotation
            )
            for flipped in [false, true] {
                for zoom in [0.05, 1.0, 2.5, 64.0] {
                    let layout = PageViewLayout(
                        anchor: CGPoint(x: -13, y: 29), zoom: zoom,
                        backingScale: 2, isViewFlipped: flipped
                    )
                    let converter = try PageCoordinateConverter(page: page, layout: layout)

                    for point in probes {
                        let back = try converter.viewToPage(try converter.pageToView(point))
                        #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9,
                                "rot \(rotation.rawValue) flip \(flipped) zoom \(zoom) point \(point)")
                    }

                    // 90 and 270 swap the displayed extents.
                    let displayed = converter.displayedSize
                    let expected = rotation.swapsAxes
                        ? CGSize(width: 400 * zoom, height: 600 * zoom)
                        : CGSize(width: 600 * zoom, height: 400 * zoom)
                    #expect(abs(displayed.width - expected.width) < 1e-9)
                    #expect(abs(displayed.height - expected.height) < 1e-9)

                    // The crop corners land exactly on the displayed rectangle's corners: the
                    // anchor and the displayed size.
                    let a = try converter.pageToView(.init(x: -100, y: -50))
                    let b = try converter.pageToView(.init(x: 500, y: 350))
                    #expect(abs(min(a.x, b.x) - layout.anchor.x) < 1e-9)
                    #expect(abs(max(a.x, b.x) - (layout.anchor.x + displayed.width)) < 1e-9)
                    #expect(abs(min(a.y, b.y) - layout.anchor.y) < 1e-9)
                    #expect(abs(max(a.y, b.y) - (layout.anchor.y + displayed.height)) < 1e-9)
                }
            }
        }
    }

    /// A snap radius is authored in logical points and must not change with the backing scale,
    /// or a 12-point target would be half the size on a Retina display.
    @Test("Screen tolerance ignores backing scale")
    func toleranceConversion() throws {
        let page = PageDescriptor(
            id: Self.pageID, documentID: Self.documentID, index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 600, height: 400))
        )
        for backingScale in [1.0, 2.0] {
            let layout = PageViewLayout(
                anchor: .zero, zoom: 4, backingScale: backingScale, isViewFlipped: false
            )
            let converter = try PageCoordinateConverter(page: page, layout: layout)
            #expect(try converter.screenToleranceToPage(pixels: 12) == 3)
        }
    }

    // MARK: - PDFRect

    /// Shrinking deeper than half an extent must empty the rectangle, not turn it inside out.
    /// (`outsetBy` is the honest name for the function `insetBy` always was — CR-92.)
    @Test("outsetBy collapses rather than inverting")
    func insetCollapses() {
        let rect = PDFRect(x: 0, y: 0, width: 10, height: 10)
        #expect(rect.outsetBy(2).width == 14)
        #expect(rect.outsetBy(-4).width == 2)
        #expect(rect.outsetBy(-5).width == 0)

        let over = rect.outsetBy(-8)
        #expect(over.width == 0)
        #expect(over.height == 0)
        // The inverted result used to span 2...8 and claim to contain these; the collapsed one
        // is the single midpoint.
        #expect(!over.contains(PDFPoint(x: 3, y: 3)))
        #expect(!over.contains(PDFPoint(x: 7, y: 7)))
        #expect(over.minX == 5 && over.minY == 5)
    }

    // MARK: - Compensated summation

    /// A 200 000-vertex traced boundary is the case Kahan-Babuska-Neumaier exists for.
    @Test("Compensated summation holds a long perimeter together")
    func compensatedPerimeter() {
        var points: [PDFPoint] = []
        for index in 0..<100_000 {
            points.append(PDFPoint(x: Double(index) * 0.001, y: 0))
        }
        // 99 999 segments of exactly 0.001 page points.
        let length = PolygonMath.perimeter(points, isClosed: false)
        #expect(abs(length - 99.999) < 1e-12, "got \(length)")

        var accumulator = KahanAccumulator()
        accumulator.add(1e16)
        for _ in 0..<200 { accumulator.add(1.0) }
        #expect(accumulator.total == 1.00000000000002e16)
    }
}
