import Foundation

/// The geometric fixtures: shapes whose length and area are known in closed form, plus
/// the transform, clipping, background and stress cases that surround them.
enum GeometricFixtures {

    // MARK: - Shared constants

    /// Every geometric fixture is a single US Letter page unless stated otherwise, so
    /// that a consumer comparing two fixtures is not also comparing two page sizes.
    static let page = FixturePageSize.letter

    /// The stroke width used for every drawn path. Stroke width does not enter any
    /// length or area in a manifest: the manifest describes the *path*, which is the
    /// centre line, not the painted ribbon.
    static let strokeWidth: Double = 1.0

    // MARK: - Single line

    /// A single stroked line whose length is exactly 500: a 300–400–500 triangle, so
    /// the truth is an integer and no rounding hides in it.
    static let lineStart = FixturePoint(100, 100)
    static let lineEnd = FixturePoint(400, 500)

    static func singleLine() throws -> FixtureBuild {
        let path = FixturePath(
            id: "line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [lineStart, lineEnd],
            length: 500,
            area: 0,
            derivation: .closedForm(
                "Pythagoras: sqrt((400-100)^2 + (500-100)^2) = sqrt(300^2 + 400^2) "
                    + "= sqrt(90000 + 160000) = sqrt(250000) = 500. "
                    + "A 3-4-5 triple, so the value is exact in binary floating point.",
                magnitudeFloor: 500
            )
        )

        let manifest = FixtureManifest(
            kind: .singleLine,
            title: "Single line, length exactly 500",
            purpose: "The smallest possible length check: one open segment, one exact answer.",
            fileName: FixtureKind.singleLine.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .singleLine)
            var content = PDFContentStream()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.move(to: lineStart)
            content.line(to: lineEnd)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Rectangle

    /// 288 × 180 at (72, 72): area 51 840, perimeter 936.
    static let rectangleBox = FixtureRect(x: 72, y: 72, width: 288, height: 180)

    static func rectangle() throws -> FixtureBuild {
        let path = FixturePath(
            id: "rect",
            pageIndex: 0,
            kind: .closedPolygon,
            points: rectangleBox.counterClockwiseCorners,
            length: 2 * (288 + 180),
            area: 288 * 180,
            derivation: .closedForm(
                "Rectangle 288 x 180 at (72, 72). Area = w*h = 288*180 = 51840. "
                    + "Perimeter = 2*(w+h) = 2*(288+180) = 936.",
                conditionNumber: 1.65,
                magnitudeFloor: 51_840
            )
        )

        let manifest = FixtureManifest(
            kind: .rectangle,
            title: "Axis-aligned rectangle 288 x 180",
            purpose: "Closed-form area and perimeter for the simplest closed shape (QUALITY_BAR M-A1).",
            fileName: FixtureKind.rectangle.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .rectangle)
            var content = PDFContentStream()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.appendRing(rectangleBox.counterClockwiseCorners, close: true)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - L-shape

    /// A concave hexagon: the union of a 300 × 150 rectangle and a 150 × 200 rectangle.
    static let lShapeRing: [FixturePoint] = [
        FixturePoint(100, 100),
        FixturePoint(400, 100),
        FixturePoint(400, 250),
        FixturePoint(250, 250),
        FixturePoint(250, 450),
        FixturePoint(100, 450)
    ]

    static func lShape() throws -> FixtureBuild {
        let path = FixturePath(
            id: "l-shape",
            pageIndex: 0,
            kind: .closedPolygon,
            points: lShapeRing,
            // Edge lengths in order: 300, 150, 150, 200, 150, 350.
            length: 300 + 150 + 150 + 200 + 150 + 350,
            // Union of x in [100,400] y in [100,250] and x in [100,250] y in [250,450].
            area: 300 * 150 + 150 * 200,
            derivation: .closedForm(
                "Decomposition into two disjoint rectangles: "
                    + "R1 = [100,400] x [100,250] -> 300*150 = 45000; "
                    + "R2 = [100,250] x [250,450] -> 150*200 = 30000; total 75000. "
                    + "Perimeter is the sum of the six axis-aligned edges "
                    + "300 + 150 + 150 + 200 + 150 + 350 = 1300.",
                conditionNumber: 1.8666666666666667,
                magnitudeFloor: 75_000
            )
        )

        let manifest = FixtureManifest(
            kind: .lShape,
            title: "Concave L-shape, area 75 000",
            purpose: "A concave polygon: catches implementations that assume convexity.",
            fileName: FixtureKind.lShape.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .lShape)
            var content = PDFContentStream()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.appendRing(lShapeRing, close: true)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Polygons with holes

    /// The 400 × 400 outer square shared by both hole fixtures, counter-clockwise.
    static let holeOuterRing: [FixturePoint] = [
        FixturePoint(100, 100),
        FixturePoint(500, 100),
        FixturePoint(500, 500),
        FixturePoint(100, 500)
    ]

    /// One 100 × 100 hole, wound clockwise so the non-zero winding rule removes it.
    static let singleHoleRing: [FixturePoint] = [
        FixturePoint(200, 200),
        FixturePoint(200, 300),
        FixturePoint(300, 300),
        FixturePoint(300, 200)
    ]

    static func polygonOneHole() throws -> FixtureBuild {
        let path = FixturePath(
            id: "square-one-hole",
            pageIndex: 0,
            kind: .polygonWithHoles,
            points: holeOuterRing,
            holes: [singleHoleRing],
            length: 4 * 400 + 4 * 100,
            area: 400 * 400 - 100 * 100,
            derivation: .closedForm(
                "Outer square 400x400 -> 160000. Hole 100x100 -> 10000. Net 150000. "
                    + "Total boundary length = 4*400 + 4*100 = 1600 + 400 = 2000.",
                conditionNumber: 1.9333333333333333,
                magnitudeFloor: 150_000
            )
        )

        let manifest = FixtureManifest(
            kind: .polygonOneHole,
            title: "400 x 400 square with one 100 x 100 hole",
            purpose: "Net area with a single cutout; even-odd versus non-zero fill behaviour.",
            fileName: FixtureKind.polygonOneHole.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path],
            notes: [
                "The outer ring is counter-clockwise and the hole is clockwise, so both "
                    + "the non-zero and the even-odd rule produce the same filled region."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            try holeDocument(kind: .polygonOneHole, holes: [singleHoleRing])
        }
    }

    /// Three holes of three different sizes.
    static let threeHoleRings: [[FixturePoint]] = [
        [   // 100 x 100
            FixturePoint(150, 150), FixturePoint(150, 250),
            FixturePoint(250, 250), FixturePoint(250, 150)
        ],
        [   // 50 x 50
            FixturePoint(350, 150), FixturePoint(350, 200),
            FixturePoint(400, 200), FixturePoint(400, 150)
        ],
        [   // 80 x 60
            FixturePoint(200, 350), FixturePoint(200, 410),
            FixturePoint(280, 410), FixturePoint(280, 350)
        ]
    ]

    static func polygonThreeHoles() throws -> FixtureBuild {
        let path = FixturePath(
            id: "square-three-holes",
            pageIndex: 0,
            kind: .polygonWithHoles,
            points: holeOuterRing,
            holes: threeHoleRings,
            length: 4 * 400 + 4 * 100 + 2 * (50 + 50) + 2 * (80 + 60),
            area: 400 * 400 - (100 * 100 + 50 * 50 + 80 * 60),
            derivation: .closedForm(
                "Outer square 400x400 -> 160000. Holes: 100x100 -> 10000, 50x50 -> 2500, "
                    + "80x60 -> 4800; total removed 17300. Net area 142700. "
                    + "Total boundary length = 1600 + 400 + 200 + 280 = 2480.",
                conditionNumber: 2.468815697267694,
                magnitudeFloor: 142_700
            )
        )

        let manifest = FixtureManifest(
            kind: .polygonThreeHoles,
            title: "400 x 400 square with three holes",
            purpose: "Multiple cutouts of differing size; hole ordering must not matter.",
            fileName: FixtureKind.polygonThreeHoles.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path]
        )

        return FixtureBuild(manifest: manifest) {
            try holeDocument(kind: .polygonThreeHoles, holes: threeHoleRings)
        }
    }

    private static func holeDocument(kind: FixtureKind, holes: [[FixturePoint]]) throws -> Data {
        let builder = PDFDocumentBuilder(kind: kind)
        var content = PDFContentStream()
        content.setLineWidth(strokeWidth)
        content.setStrokeGray(0)
        content.setFillGray(0.75)
        content.appendRing(holeOuterRing, close: true)
        for hole in holes { content.appendRing(hole, close: true) }
        // Fill with the non-zero rule and stroke every ring, so the file exercises both
        // a filled region with holes and the individual boundary paths.
        content.raw("B")
        let contents = try builder.addContentStream(content)
        builder.addPage(mediaBox: page, contentObject: contents)
        return try builder.data()
    }

    // MARK: - Bézier circle

    /// The circle the four Béziers approximate.
    static let circleCenter = FixturePoint(306, 396)
    static let circleRadius: Double = 144

    /// The classic four-arc control-point offset, `k = 4/3 * (sqrt(2) - 1)`, chosen so
    /// the curve passes exactly through the axis points and the 45° points.
    static let bezierKappa: Double = 4.0 / 3.0 * (2.0.squareRoot() - 1.0)

    /// A strict upper bound on the radial deviation of the four-Bézier circle,
    /// relative to the radius.
    ///
    /// The true maximum is 2.725300074275516e-4 of the radius, reached at t ≈ 0.2113
    /// on each arc; the bound below is rounded up so that a test may assert
    /// `|r(t) - R| <= radialErrorBoundRelative * R` for every t without ever sitting
    /// exactly on the boundary.
    static let radialErrorBoundRelative: Double = 2.7254e-4

    static func bezierCircle() throws -> FixtureBuild {
        let cx = circleCenter.x
        let cy = circleCenter.y
        let r = circleRadius
        let k = bezierKappa * r

        let east = FixturePoint(cx + r, cy)
        let north = FixturePoint(cx, cy + r)
        let west = FixturePoint(cx - r, cy)
        let south = FixturePoint(cx, cy - r)

        let cubics = [
            FixtureCubic(
                p0: east,
                p1: FixturePoint(cx + r, cy + k),
                p2: FixturePoint(cx + k, cy + r),
                p3: north
            ),
            FixtureCubic(
                p0: north,
                p1: FixturePoint(cx - k, cy + r),
                p2: FixturePoint(cx - r, cy + k),
                p3: west
            ),
            FixtureCubic(
                p0: west,
                p1: FixturePoint(cx - r, cy - k),
                p2: FixturePoint(cx - k, cy - r),
                p3: south
            ),
            FixtureCubic(
                p0: south,
                p1: FixturePoint(cx + k, cy - r),
                p2: FixturePoint(cx + r, cy - k),
                p3: east
            )
        ]

        // Exact enclosed area of the four-Bézier loop, from Green's theorem:
        //   A(K) = R^2 * (-3/5 K^2 + 12/5 K + 2), with K = 4/3 (sqrt(2) - 1).
        let kk = bezierKappa
        let bezierArea = r * r * (-0.6 * kk * kk + 2.4 * kk + 2.0)
        let trueArea = Double.pi * r * r
        let trueCircumference = 2 * Double.pi * r

        let path = FixturePath(
            id: "circle",
            pageIndex: 0,
            kind: .cubicBezierLoop,
            points: [east, north, west, south],
            cubics: cubics,
            length: trueCircumference,
            area: trueArea,
            derivation: .closedForm(
                "True circle of radius R = 144 centred at (306, 396): "
                    + "area = pi*R^2 = pi*20736 = 65144.06526483795; "
                    + "circumference = 2*pi*R = 288*pi = 904.7786842338604. "
                    + "The drawn geometry is the standard four-arc cubic approximation with "
                    + "K = 4/3*(sqrt(2)-1) = 0.5522847498307935, control offset K*R = "
                    + "79.52900397563425. Its exact enclosed area, from Green's theorem "
                    + "integral of (x dy - y dx)/2 over the four cubics, is "
                    + "R^2 * (-3/5 K^2 + 12/5 K + 2) = 65162.30628996533, which exceeds "
                    + "pi*R^2 by a factor 1.0002800105436, and its maximum radial deviation "
                    + "is 2.725300074275516e-4 * R = 0.03924432106956743 page points.",
                magnitudeFloor: 65_144
            ),
            notes: [
                "This is an approximation, by construction. Assert against pi*R^2 only with "
                    + "a tolerance of at least the recorded 2.8001e-4 relative area excess, or "
                    + "assert against the exact Bezier area 65162.30628996533 at 1e-9.",
                "Exact Bezier-loop area: 65162.30628996533 page points squared.",
                "Maximum radial deviation: 0.03924432106956743 page points, at t = 0.211325 "
                    + "on each arc."
            ]
        )

        let manifest = FixtureManifest(
            kind: .bezierCircle,
            title: "Circle of radius 144 as four cubic Béziers",
            purpose: "Curve flattening, arc-length and circle-fitting checks with a documented "
                + "approximation error, so a test never mistakes the approximation for a defect.",
            fileName: FixtureKind.bezierCircle.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [path],
            notes: [
                "Centre (306, 396), radius 144.",
                "Bezier control offset K*R with K = 4/3*(sqrt(2)-1).",
                "Exact enclosed area of the drawn loop: \(bezierArea).",
                "True circle area: \(trueArea). True circumference: \(trueCircumference)."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .bezierCircle)
            var content = PDFContentStream()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.move(to: east)
            for cubic in cubics { content.curve(cubic) }
            content.closeSubpath()
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Nested form XObjects

    /// Page-level CTM in force at the outer `Do`.
    static let outerPageMatrix = FixtureMatrix(a: 1, b: 0, c: 0, d: 1, e: 40, f: 30)
    /// `/Matrix` of the outer form.
    static let outerFormMatrix = FixtureMatrix(a: 1.5, b: 0, c: 0, d: 1.5, e: 20, f: 10)
    /// `/Matrix` of the inner form.
    static let innerFormMatrix = FixtureMatrix(a: 2, b: 0, c: 0, d: 2, e: 10, f: 5)

    /// The rectangle drawn inside the outer form, in that form's own space.
    static let outerFormRect = FixtureRect(x: 0, y: 0, width: 100, height: 50)
    /// The rectangle drawn inside the inner form, in that form's own space.
    static let innerFormRect = FixtureRect(x: 0, y: 0, width: 30, height: 20)

    static func nestedFormXObjects() throws -> FixtureBuild {
        // PDF composes a form's /Matrix *before* the CTM in force at the Do operator.
        let outerComposed = outerFormMatrix.concatenated(with: outerPageMatrix)
        let innerComposed = innerFormMatrix.concatenated(with: outerComposed)

        let outerSource = outerFormRect.counterClockwiseCorners
        let innerSource = innerFormRect.counterClockwiseCorners
        let outerPage = outerSource.map { outerComposed.apply(to: $0) }
        let innerPage = innerSource.map { innerComposed.apply(to: $0) }

        let outerPath = FixturePath(
            id: "outer-form-rect",
            pageIndex: 0,
            kind: .closedPolygon,
            points: outerPage,
            length: 2 * (100 + 50) * 1.5,
            area: 100 * 50 * 1.5 * 1.5,
            sourcePoints: outerSource,
            transform: outerComposed,
            derivation: .closedForm(
                "Rectangle 100x50 in form space, composed matrix [1.5 0 0 1.5 60 40] "
                    + "(outer /Matrix [1.5 0 0 1.5 20 10] then page cm [1 0 0 1 40 30]). "
                    + "A uniform scale of 1.5 multiplies length by 1.5 and area by 1.5^2 = 2.25: "
                    + "perimeter 2*(100+50)*1.5 = 450, area 100*50*2.25 = 11250. "
                    + "Page-space corners (60,40) (210,40) (210,115) (60,115).",
                conditionNumber: 1.9333333333333333,
                magnitudeFloor: 11_250
            )
        )

        let innerPath = FixturePath(
            id: "inner-form-rect",
            pageIndex: 0,
            kind: .closedPolygon,
            points: innerPage,
            length: 2 * (30 + 20) * 3,
            area: 30 * 20 * 3 * 3,
            sourcePoints: innerSource,
            transform: innerComposed,
            derivation: .closedForm(
                "Rectangle 30x20 in inner-form space, composed matrix [3 0 0 3 75 47.5] "
                    + "(inner /Matrix [2 0 0 2 10 5] then the outer composed [1.5 0 0 1.5 60 40]). "
                    + "Uniform scale 3: perimeter 2*(30+20)*3 = 300, area 30*20*9 = 5400. "
                    + "Page-space corners (75,47.5) (165,47.5) (165,107.5) (75,107.5).",
                conditionNumber: 2.625,
                magnitudeFloor: 5_400
            )
        )

        let manifest = FixtureManifest(
            kind: .nestedFormXObjects,
            title: "Two levels of form XObjects, each with a non-identity matrix",
            purpose: "Transform composition: an extractor that drops or misorders a form /Matrix "
                + "produces coordinates that miss the manifest by a visible margin.",
            fileName: FixtureKind.nestedFormXObjects.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [outerPath, innerPath],
            formNestingDepth: 2,
            notes: [
                "Page CTM at the outer Do: [1 0 0 1 40 30].",
                "Outer form /Matrix: [1.5 0 0 1.5 20 10]; composed [1.5 0 0 1.5 60 40].",
                "Inner form /Matrix: [2 0 0 2 10 5]; composed [3 0 0 3 75 47.5].",
                "PDF composes form /Matrix before the CTM in force at Do; reversing the order "
                    + "gives [1.5 0 0 1.5 50 40] for the outer form and is the classic bug."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .nestedFormXObjects)

            var innerContent = PDFContentStream()
            innerContent.setLineWidth(strokeWidth)
            innerContent.setStrokeGray(0)
            innerContent.appendRing(innerSource, close: true)
            innerContent.stroke()
            let innerForm = try builder.addFormXObject(
                bbox: FixtureRect(llx: 0, lly: 0, urx: 30, ury: 20),
                matrix: innerFormMatrix,
                resources: "<< >>",
                content: innerContent
            )

            var outerContent = PDFContentStream()
            outerContent.setLineWidth(strokeWidth)
            outerContent.setStrokeGray(0)
            outerContent.appendRing(outerSource, close: true)
            outerContent.stroke()
            outerContent.drawXObject(named: "Inner")
            let outerForm = try builder.addFormXObject(
                bbox: FixtureRect(llx: 0, lly: 0, urx: 100, ury: 50),
                matrix: outerFormMatrix,
                resources: "<< /XObject << /Inner \(innerForm) 0 R >> >>",
                content: outerContent
            )

            var pageContent = PDFContentStream()
            pageContent.saveState()
            pageContent.concat(outerPageMatrix)
            pageContent.drawXObject(named: "Outer")
            pageContent.restoreState()
            let contents = try builder.addContentStream(pageContent)
            builder.addPage(
                mediaBox: page,
                resources: "<< /XObject << /Outer \(outerForm) 0 R >> >>",
                contentObject: contents
            )
            return try builder.data()
        }
    }

    // MARK: - Clipping path

    static let clipBox = FixtureRect(llx: 200, lly: 200, urx: 400, ury: 400)
    static let clippedLineStart = FixturePoint(100, 300)
    static let clippedLineEnd = FixturePoint(500, 300)
    static let clippedFillRect = FixtureRect(x: 150, y: 150, width: 300, height: 300)

    static func clippedContent() throws -> FixtureBuild {
        let line = FixturePath(
            id: "crossing-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [clippedLineStart, clippedLineEnd],
            length: 400,
            area: 0,
            clippedVisibleLength: 200,
            clippedVisibleArea: 0,
            derivation: .closedForm(
                "Horizontal line y = 300 from x = 100 to x = 500: length 400. "
                    + "The clip box is x in [200,400], y in [200,400] and 300 lies inside "
                    + "[200,400], so the visible portion runs x in [200,400]: length 200.",
                magnitudeFloor: 400
            )
        )

        let filled = FixturePath(
            id: "overhanging-rect",
            pageIndex: 0,
            kind: .closedPolygon,
            points: clippedFillRect.counterClockwiseCorners,
            length: 2 * (300 + 300),
            area: 300 * 300,
            clippedVisibleLength: 0,
            clippedVisibleArea: 200 * 200,
            derivation: .closedForm(
                "Filled rectangle [150,450] x [150,450]: area 90000, perimeter 1200. "
                    + "Intersected with the clip box [200,400] x [200,400] the visible area is "
                    + "200*200 = 40000. None of the rectangle's own boundary lies inside the "
                    + "clip box (150 < 200 and 450 > 400 on both axes), so the visible boundary "
                    + "length is exactly 0.",
                conditionNumber: 2.0,
                magnitudeFloor: 90_000
            )
        )

        let manifest = FixtureManifest(
            kind: .clippedContent,
            title: "Geometry crossing a rectangular clipping path",
            purpose: "A reader that ignores `W n` reports the full 400-point line and the full "
                + "90 000-unit rectangle instead of the clipped 200 and 40 000.",
            fileName: FixtureKind.clippedContent.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page, clipPath: clipBox)],
            paths: [line, filled],
            notes: [
                "Clip box: [200 200 400 400], installed with `re W n` before any painting.",
                "`length` and `area` describe the *path*; `clippedVisibleLength` and "
                    + "`clippedVisibleArea` describe what survives the clip."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .clippedContent)
            var content = PDFContentStream()
            content.saveState()
            content.appendRectangle(clipBox)
            content.clipNonZeroAndEndPath()
            content.setFillGray(0.6)
            content.appendRectangle(clippedFillRect)
            content.fillNonZero()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.move(to: clippedLineStart)
            content.line(to: clippedLineEnd)
            content.stroke()
            content.restoreState()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Giant background rectangle

    static let backgroundLineStart = FixturePoint(200, 200)
    static let backgroundLineEnd = FixturePoint(400, 200)
    static let foregroundRect = FixtureRect(x: 250, y: 300, width: 120, height: 80)

    static func giantBackgroundRectangle() throws -> FixtureBuild {
        let background = FixturePath(
            id: "background",
            pageIndex: 0,
            kind: .closedPolygon,
            points: page.counterClockwiseCorners,
            length: 2 * (612 + 792),
            area: 612 * 792,
            isBackground: true,
            derivation: .closedForm(
                "The full media box 612 x 792: area 484704, perimeter 2808. "
                    + "Present so that snap has something enormous to ignore.",
                conditionNumber: 1.0,
                magnitudeFloor: 484_704
            ),
            notes: ["Snap and measurement must never select this path."]
        )

        let line = FixturePath(
            id: "foreground-line",
            pageIndex: 0,
            kind: .openPolyline,
            points: [backgroundLineStart, backgroundLineEnd],
            length: 200,
            area: 0,
            derivation: .closedForm(
                "Horizontal line y = 200 from x = 200 to x = 400: length 400 - 200 = 200.",
                magnitudeFloor: 200
            )
        )

        let rect = FixturePath(
            id: "foreground-rect",
            pageIndex: 0,
            kind: .closedPolygon,
            points: foregroundRect.counterClockwiseCorners,
            length: 2 * (120 + 80),
            area: 120 * 80,
            derivation: .closedForm(
                "Rectangle 120 x 80 at (250, 300): area 9600, perimeter 400.",
                conditionNumber: 6.833333333333333,
                magnitudeFloor: 9_600
            )
        )

        let manifest = FixtureManifest(
            kind: .giantBackgroundRectangle,
            title: "Full-bleed background rectangle plus real geometry",
            purpose: "Snap must ignore the page-sized rectangle and prefer the two small paths; "
                + "an implementation that scores by proximity alone will snap to the background "
                + "edge from anywhere on the page.",
            fileName: FixtureKind.giantBackgroundRectangle.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: [background, line, rect]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .giantBackgroundRectangle)
            var content = PDFContentStream()
            content.setFillGray(0.93)
            content.appendRectangle(page)
            content.fillNonZero()
            content.setLineWidth(strokeWidth)
            content.setStrokeGray(0)
            content.move(to: backgroundLineStart)
            content.line(to: backgroundLineEnd)
            content.stroke()
            content.appendRing(foregroundRect.counterClockwiseCorners, close: true)
            content.stroke()
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - 10 000 short segments

    static let stressGridColumns = 100
    static let stressGridRows = 100
    static let stressGridOrigin = FixturePoint(6, 6)
    static let stressGridSpacing: Double = 6
    /// Each segment is a 3-4-5 triple, so every length is exactly 5.
    static let stressSegmentLength: Double = 5

    static var stressSegmentCount: Int { stressGridColumns * stressGridRows }

    /// The segments, generated by a closed-form lattice rule rather than a PRNG, so the
    /// corpus is reproducible without recording a seed.
    static func stressSegments() -> [(FixturePoint, FixturePoint)] {
        var result: [(FixturePoint, FixturePoint)] = []
        result.reserveCapacity(stressSegmentCount)
        for row in 0..<stressGridRows {
            for column in 0..<stressGridColumns {
                let x = stressGridOrigin.x + Double(column) * stressGridSpacing
                let y = stressGridOrigin.y + Double(row) * stressGridSpacing
                result.append((FixturePoint(x, y), FixturePoint(x + 3, y + 4)))
            }
        }
        return result
    }

    static func tenThousandSegments() throws -> FixtureBuild {
        let segments = stressSegments()
        var paths: [FixturePath] = []
        paths.reserveCapacity(segments.count)
        let derivation = FixtureDerivation.closedForm(
            "Every segment is (x, y) -> (x+3, y+4), a 3-4-5 triple, so its length is exactly "
                + "sqrt(9 + 16) = 5. The lattice is x = 6 + 6*column, y = 6 + 6*row for "
                + "column, row in 0..<100, giving 10000 segments and a total length of "
                + "10000 * 5 = 50000.",
            magnitudeFloor: 5
        )
        for (index, segment) in segments.enumerated() {
            paths.append(
                FixturePath(
                    id: "seg-\(index)",
                    pageIndex: 0,
                    kind: .openPolyline,
                    points: [segment.0, segment.1],
                    length: stressSegmentLength,
                    area: 0,
                    derivation: derivation
                )
            )
        }

        let manifest = FixtureManifest(
            kind: .tenThousandSegments,
            title: "10 000 short segments on one page",
            purpose: "Extraction and snap-index stress: total length is exactly 50 000 and every "
                + "individual segment is exactly 5.",
            fileName: FixtureKind.tenThousandSegments.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            paths: paths,
            notes: [
                "Total length: 10000 * 5 = 50000 page points.",
                "Segment i is at column i % 100, row i / 100.",
                "The content stream is Flate-compressed; uncompressed it is roughly 300 KB."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .tenThousandSegments)
            var content = PDFContentStream()
            content.setLineWidth(0.25)
            content.setStrokeGray(0)
            for segment in segments {
                content.move(to: segment.0)
                content.line(to: segment.1)
            }
            content.stroke()
            let contents = try builder.addContentStream(content, compressed: true)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }

    // MARK: - Huge malformed operator stream

    /// Target size of the malformed content stream. Large enough to matter, small
    /// enough that generating it on every test run costs nothing.
    static let malformedStreamTargetBytes = 1 << 20

    /// The block repeated until the stream reaches `malformedStreamTargetBytes`.
    static let malformedStreamBlock = [
        "q 1 0 0 1 0 0 cm BT /NoSuchFont 12 Tf ET Q",
        "99 99 zzq",
        "[ (unterminated) 0 ] TJ",
        "0 0 0 0 0 0 0 0 0 sc",
        "/BogusXObject Do",
        "1 2 3 4 5 6 7 8 9 10 cm",
        "qqqq",
        "-0 -0 m l l l S",
        "Q Q Q"
    ]

    /// Bytes one block adds to the stream, newline included on every line.
    static var malformedStreamBlockBytes: Int {
        malformedStreamBlock.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    /// How many times the block is written: the loop stops at the first repetition
    /// that reaches the target.
    static var malformedStreamRepetitions: Int {
        (malformedStreamTargetBytes + malformedStreamBlockBytes - 1) / malformedStreamBlockBytes
    }

    /// Each block opens and closes one `q ... Q` pair and then pops three more states
    /// it never pushed (`Q Q Q`); `qqqq` is not an operator at all.
    static var malformedStreamUnbalancedRestores: Int { 3 * malformedStreamRepetitions }

    static func hugeMalformedOperatorStream() throws -> FixtureBuild {
        let manifest = FixtureManifest(
            kind: .hugeMalformedOperatorStream,
            title: "One page, one megabyte of invalid operators",
            purpose: "A structurally valid document whose content stream is token soup: unknown "
                + "operators, wrong operand counts, unbalanced q/Q, references to resources that "
                + "do not exist. The extractor must terminate, allocate nothing unbounded, and "
                + "report a typed error or an empty page — never hang.",
            fileName: FixtureKind.hugeMalformedOperatorStream.fileName,
            pageCount: 1,
            pages: [FixturePage(index: 0, mediaBox: page)],
            hostileTraits: [.malformedOperatorStream],
            notes: [
                "The page dictionary, page tree and cross-reference table are all valid.",
                "Content stream length is approximately \(malformedStreamTargetBytes) bytes, "
                    + "stored uncompressed so a reader cannot skip it cheaply.",
                "A \(malformedStreamBlock.count)-line, \(malformedStreamBlockBytes)-byte block is written "
                    + "\(malformedStreamRepetitions) times, so the stream is exactly "
                    + "\(malformedStreamRepetitions * malformedStreamBlockBytes) bytes.",
                "The stream contains \(malformedStreamUnbalancedRestores) unbalanced `Q` operators "
                    + "(three per block) and \"operators\" such as `zzq` and `qqqq` that appear in "
                    + "no PDF operator table."
            ]
        )

        return FixtureBuild(manifest: manifest) {
            let builder = PDFDocumentBuilder(kind: .hugeMalformedOperatorStream)
            var content = PDFContentStream()
            let block = malformedStreamBlock
            var written = 0
            var guardCounter = 0
            let guardLimit = malformedStreamTargetBytes
            while written < malformedStreamTargetBytes, guardCounter < guardLimit {
                for line in block {
                    content.raw(line)
                    written += line.utf8.count + 1
                }
                guardCounter += 1
            }
            let contents = try builder.addContentStream(content)
            builder.addPage(mediaBox: page, contentObject: contents)
            return try builder.data()
        }
    }
}
