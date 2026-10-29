import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFVectorExtraction

/// Which candidates a closed shape may contribute: a curved ring its centre only (CR-35), a
/// closed polyline its bounding-box centre only when it is a parallelogram (CR-40).
@Suite("Shape candidates (CR-35, CR-40)")
struct SnapShapeCandidateTests {

    static func page() throws -> PageDescriptor { try SnapScene.letterPage() }

    /// The five primitives the extractor emits for a four-Bézier circle: the closed subpath
    /// as a ring of its four axis vertices, and the four cubics as its children.
    static func bezierCircle(centre: CGPoint, radius r: Double, firstID: UInt64) -> [VectorPrimitive] {
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1) * r
        let east = CGPoint(x: centre.x + r, y: centre.y)
        let north = CGPoint(x: centre.x, y: centre.y + r)
        let west = CGPoint(x: centre.x - r, y: centre.y)
        let south = CGPoint(x: centre.x, y: centre.y - r)
        let cubics = [
            VectorCubic(p0: east, p1: CGPoint(x: centre.x + r, y: centre.y + k), p2: CGPoint(x: centre.x + k, y: centre.y + r), p3: north),
            VectorCubic(p0: north, p1: CGPoint(x: centre.x - k, y: centre.y + r), p2: CGPoint(x: centre.x - r, y: centre.y + k), p3: west),
            VectorCubic(p0: west, p1: CGPoint(x: centre.x - r, y: centre.y - k), p2: CGPoint(x: centre.x - k, y: centre.y - r), p3: south),
            VectorCubic(p0: south, p1: CGPoint(x: centre.x + k, y: centre.y - r), p2: CGPoint(x: centre.x + r, y: centre.y - k), p3: east)
        ]
        var bounds = cubics[0].bounds
        for cubic in cubics.dropFirst() { bounds = bounds.union(cubic.bounds) }
        var primitives = [
            primitive(
                id: firstID, parentID: nil, kind: .closedSubpath,
                geometry: .ring(VectorRing(vertices: [east, north, west, south], isClosed: true, containsCurves: true)),
                bounds: bounds
            )
        ]
        for (index, cubic) in cubics.enumerated() {
            primitives.append(
                primitive(id: firstID + UInt64(index + 1), parentID: firstID, kind: .cubicCurve,
                          geometry: .cubic(cubic), bounds: cubic.bounds)
            )
        }
        return primitives
    }

    static func primitive(
        id: UInt64, parentID: UInt64?, kind: VectorPrimitiveKind, geometry: VectorGeometry, bounds: VectorBounds
    ) -> VectorPrimitive {
        VectorPrimitive(
            id: id, parentID: parentID, kind: kind, geometry: geometry, bounds: bounds,
            sourceObjectID: 1, subpathIndex: 0, nestingDepth: 0, paint: .stroked, strokeWidth: 1,
            strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: nil
        )
    }

    /// Every kind but the grid, which has no primitive behind it and would otherwise be the
    /// answer wherever a shape has none.
    static var settings: SnapSettings {
        var settings = SnapSettings.default
        settings.enabledKinds = Set(SnapKind.allCases).subtracting([.grid])
        return settings
    }

    static func resolve(_ index: SnapIndex, page: PageDescriptor, at cursor: PDFPoint) throws -> SnapResolution {
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        return try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout), layout: layout
                ),
                settings: Self.settings
            ),
            in: index
        )
    }

    // MARK: - CR-35

    @Test("A curved ring contributes its centre and no chord candidates (CR-35)")
    func curvedRingIsCentreOnly() throws {
        let centre = CGPoint(x: 306, y: 396)
        let extraction = SnapIndexTests.extraction(
            primitives: Self.bezierCircle(centre: centre, radius: 144, firstID: 10)
        )
        let page = try Self.page()
        let index = try SnapIndexBuilder().build(page: page, extraction: extraction)

        let entries = index.allEntries(in: .vector)
        #expect(entries.count == 5)
        let ring = try #require(entries.first { $0.id == 10 })
        guard case .point(let bridged) = ring.primitive.geometry else {
            Issue.record("the curved ring should be bridged as its centre, got \(ring.primitive.geometry)")
            return
        }
        #expect(bridged == PDFPoint(x: 306, y: 396))
        #expect(ring.kindSet.vertex == .center)

        // The midpoint of the chord from the east vertex to the north vertex: (378, 468),
        // 42 pt inside the arc. Old output: winner `.midpoint` at exactly that point.
        let atChord = try Self.resolve(index, page: page, at: PDFPoint(x: 378, y: 468))
        #expect(atChord.winner == nil, "\(String(describing: atChord.winner))" as Comment)

        // Along the chord, 20 pt from its midpoint: old output was `.pdfVectorContent` on it.
        let alongChord = try Self.resolve(index, page: page, at: PDFPoint(x: 378 + 14, y: 468 - 14))
        #expect(alongChord.winner == nil, "\(String(describing: alongChord.winner))" as Comment)

        let atCentre = try Self.resolve(index, page: page, at: PDFPoint(x: 307, y: 397))
        #expect(atCentre.winner?.kind == .center)
        #expect(atCentre.winner?.position == PDFPoint(x: 306, y: 396))
        #expect(atCentre.winner?.primitiveID == 10)

        // The arc is reachable through its cubic: the east–north cubic's midpoint is the
        // 45° point of the circle.
        let on45 = PDFPoint(x: 306 + 144 / 2.0.squareRoot(), y: 396 + 144 / 2.0.squareRoot())
        let atArc = try Self.resolve(index, page: page, at: PDFPoint(x: on45.x + 1, y: on45.y - 1))
        #expect(atArc.winner?.kind == .midpoint)
        #expect(atArc.winner?.primitiveID == 11)
        #expect(try #require(atArc.winner).position.distance(to: on45) <= 1e-9)
    }

    @Test("A curved ring that is not centrally symmetric has no candidate of its own (CR-35)")
    func asymmetricCurvedRingHasNoCentre() throws {
        let vertices = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 220, y: 260)]
        let cubic = VectorCubic(p0: vertices[2], p1: CGPoint(x: 150, y: 300), p2: CGPoint(x: 80, y: 200), p3: vertices[0])
        let bounds = VectorBounds(minX: 80, minY: 100, maxX: 300, maxY: 280)
        let extraction = SnapIndexTests.extraction(primitives: [
            Self.primitive(id: 20, parentID: nil, kind: .closedSubpath,
                           geometry: .ring(VectorRing(vertices: vertices, isClosed: true, containsCurves: true)),
                           bounds: bounds),
            Self.primitive(id: 21, parentID: 20, kind: .cubicCurve, geometry: .cubic(cubic), bounds: cubic.bounds)
        ])
        let index = try SnapIndexBuilder().build(page: try Self.page(), extraction: extraction)
        #expect(index.allEntries(in: .vector).map(\.id) == [21])
    }

    @Test("A straight ring is still bridged as its polyline")
    func straightRingIsAPolyline() throws {
        let vertices = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300)]
        let extraction = SnapIndexTests.extraction(primitives: [
            Self.primitive(id: 30, parentID: nil, kind: .closedSubpath,
                           geometry: .ring(VectorRing(vertices: vertices, isClosed: true, containsCurves: false)),
                           bounds: VectorBounds(minX: 100, minY: 100, maxX: 300, maxY: 300))
        ])
        let index = try SnapIndexBuilder().build(page: try Self.page(), extraction: extraction)
        let entry = try #require(index.allEntries(in: .vector).first)
        guard case .polyline(let points, let isClosed) = entry.primitive.geometry else {
            Issue.record("expected a polyline")
            return
        }
        #expect(points.count == 4 && isClosed)
    }

    // MARK: - CR-40

    @Test("A closed polyline that is not a parallelogram has no centre candidate (CR-40)")
    func onlyParallelogramsHaveACentre() throws {
        let page = try Self.page()
        // A fat L: its bounding-box centre (150, 150) is 50 pt from every edge.
        let fatL = try #require(SnapScene.polyline(
            id: 1,
            [PDFPoint(x: 0, y: 0), PDFPoint(x: 300, y: 0), PDFPoint(x: 300, y: 100),
             PDFPoint(x: 100, y: 100), PDFPoint(x: 100, y: 300), PDFPoint(x: 0, y: 300)],
            isClosed: true
        ))
        // A trapezoid: four vertices, diagonals that do not bisect each other.
        let trapezoid = try #require(SnapScene.polyline(
            id: 2,
            [PDFPoint(x: 400, y: 100), PDFPoint(x: 600, y: 100), PDFPoint(x: 550, y: 200), PDFPoint(x: 450, y: 200)],
            isClosed: true
        ))
        // A rotated parallelogram: centre at the diagonals' common midpoint (160, 460).
        let parallelogram = try #require(SnapScene.polyline(
            id: 3,
            [PDFPoint(x: 100, y: 400), PDFPoint(x: 200, y: 420), PDFPoint(x: 220, y: 520), PDFPoint(x: 120, y: 500)],
            isClosed: true
        ))
        let scene = try SnapScene.withVectorContent(page: page, primitives: [fatL, trapezoid, parallelogram])

        // Old output: `.center` at (150, 150) — the bounding-box centre of the L.
        let atL = try Self.resolve(scene.index, page: page, at: PDFPoint(x: 150, y: 150))
        #expect(atL.winner == nil, "\(String(describing: atL.winner))" as Comment)

        // Old output: `.center` at (500, 150) — the bounding-box centre of the trapezoid.
        let atTrapezoid = try Self.resolve(scene.index, page: page, at: PDFPoint(x: 500, y: 150))
        #expect(atTrapezoid.winner == nil, "\(String(describing: atTrapezoid.winner))" as Comment)

        let atParallelogram = try Self.resolve(scene.index, page: page, at: PDFPoint(x: 161, y: 461))
        #expect(atParallelogram.winner?.kind == .center)
        #expect(atParallelogram.winner?.position == PDFPoint(x: 160, y: 460))
        #expect(atParallelogram.winner?.primitiveID == 3)
    }
}
