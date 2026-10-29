import Foundation
import Testing
@testable import ZPDFDXF

/// Iteration 7: entities stored in their object coordinate system are placed by their
/// extrusion direction (X-048). Every expected value is derived by hand from the fixture.
@Suite("DXF — iteration 7", .serialized)
struct Iter7DXFTests {

    static func read(_ entities: String, blocks: String = "") throws -> DXFDrawing {
        try DXFReader.read(DXFIntakeTests.dxf(layers: ["0"], blocks: blocks, entities: entities))
    }

    static func near(_ p: DXFPoint, _ x: Double, _ y: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(p.x - x) <= tolerance && abs(p.y - y) <= tolerance
    }

    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-12) -> Bool { abs(a - b) <= tolerance }

    static let down = "210\n0\n220\n0\n230\n-1\n"

    // MARK: - X-048: extrusion (0, 0, −1)

    /// For N = (0, 0, −1) the arbitrary-axis rule gives Ax = (−1, 0, 0), Ay = (0, 1, 0): the
    /// stored (x, y) is drawn at (−x, y), and the counter-clockwise run 0°…90° becomes the run
    /// from 180° − 90° to 180° − 0°.
    /// Old output: `.arc(center: (2000, 1000), radius: 500, start: 0, end: π/2)` — mirrored.
    @Test("X-048: an ARC with extrusion (0,0,−1) lands at (−2000, 1000) with its sweep reversed")
    func arcAlongMinusZ() throws {
        let drawing = try Self.read("0\nARC\n8\n0\n10\n2000\n20\n1000\n30\n0\n40\n500\n50\n0\n51\n90\n" + Self.down)
        guard case let .arc(center, radius, start, end) = try #require(drawing.entities.first).shape else {
            Issue.record("not an arc: \(drawing.entities)"); return
        }
        #expect(Self.near(center, -2000, 1000))
        #expect(radius == 500)
        #expect(Self.near(start, .pi / 2) && Self.near(end, .pi), "\(start) … \(end)")
        // The OCS 45° point (2000 + 500/√2, 1000 + 500/√2) is drawn at (−2353.553…, 1353.553…),
        // the image's 135° point.
        let mid = (start + end) / 2
        #expect(Self.near(DXFPoint(x: center.x + radius * cos(mid), y: center.y + radius * sin(mid)),
                          -2000 - 500 / 2.0.squareRoot(), 1000 + 500 / 2.0.squareRoot()))
    }

    /// Old output: `.circle(center: (3000, 500), radius: 200)`.
    @Test("X-048: a CIRCLE and a TEXT with extrusion (0,0,−1) are mirrored to −x")
    func circleAndTextAlongMinusZ() throws {
        let drawing = try Self.read(
            "0\nCIRCLE\n8\n0\n10\n3000\n20\n500\n30\n0\n40\n200\n" + Self.down
                + "0\nTEXT\n8\n0\n10\n100\n20\n5000\n30\n0\n40\n250\n1\nRoom 101\n" + Self.down
        )
        #expect(drawing.entities.count == 2)
        #expect(drawing.entities[0].shape == .circle(center: DXFPoint(x: -3000, y: 500), radius: 200))
        guard case let .text(position, height, _, string) = drawing.entities[1].shape else {
            Issue.record("not a text: \(drawing.entities[1])"); return
        }
        #expect(Self.near(position, -100, 5000) && height == 250 && string == "Room 101")
    }

    /// Whether two angles name the same direction.
    static func sameDirection(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(remainder(a - b, 2 * .pi)) <= tolerance
    }

    /// The text's own baseline direction is Ax cos r + Ay sin r = (−cos r, sin r) for
    /// N = (0, 0, −1): 90° stays 90° (the image of straight up is straight up) and 30° becomes
    /// 150°. Old output: π + r — 270° and 210°, both upside down.
    @Test("X-048: a rotated TEXT with extrusion (0,0,−1) runs along its mirrored baseline")
    func rotatedTextAlongMinusZ() throws {
        let drawing = try Self.read(
            "0\nTEXT\n8\n0\n10\n100\n20\n5000\n30\n0\n40\n250\n50\n90\n1\nUp\n" + Self.down
                + "0\nTEXT\n8\n0\n10\n300\n20\n200\n30\n0\n40\n250\n50\n30\n1\nSlant\n" + Self.down
        )
        #expect(drawing.entities.count == 2)
        guard case let .text(up, _, upRotation, _) = drawing.entities[0].shape,
              case let .text(slant, _, slantRotation, _) = drawing.entities[1].shape else {
            Issue.record("not texts: \(drawing.entities)"); return
        }
        #expect(Self.near(up, -100, 5000))
        #expect(Self.sameDirection(upRotation, .pi / 2), "\(upRotation)")
        #expect(Self.near(slant, -300, 200))
        #expect(Self.sameDirection(slantRotation, 5 * .pi / 6), "\(slantRotation)")
    }

    /// The same rule inside a block placed with x scale −1: a member text at (100, 0) turned 30°
    /// lands at (−100, 0) running at 150°. A block stretched 2 × 1 turns a 45° baseline (1, 1)
    /// into (2, 1), atan(½) = 26.565…°. Old output: 210° and 45°.
    @Test("X-048: a rotated TEXT in a mirrored or stretched INSERT runs along its placed baseline")
    func rotatedTextInPlacedBlocks() throws {
        let block = "0\nBLOCK\n8\n0\n2\nT\n70\n0\n10\n0\n20\n0\n30\n0\n"
            + "0\nTEXT\n8\n0\n10\n100\n20\n0\n30\n0\n40\n10\n50\n30\n1\nMember\n0\nENDBLK\n8\n0\n"
            + "0\nBLOCK\n8\n0\n2\nS\n70\n0\n10\n0\n20\n0\n30\n0\n"
            + "0\nTEXT\n8\n0\n10\n0\n20\n0\n30\n0\n40\n10\n50\n45\n1\nStretched\n0\nENDBLK\n8\n0\n"
        let drawing = try Self.read(
            "0\nINSERT\n8\n0\n2\nT\n10\n0\n20\n0\n30\n0\n41\n-1\n42\n1\n"
                + "0\nINSERT\n8\n0\n2\nS\n10\n0\n20\n0\n30\n0\n41\n2\n42\n1\n",
            blocks: block
        )
        #expect(drawing.entities.count == 2)
        guard case let .text(mirrored, _, mirroredRotation, _) = drawing.entities[0].shape,
              case let .text(_, _, stretchedRotation, _) = drawing.entities[1].shape else {
            Issue.record("not texts: \(drawing.entities)"); return
        }
        #expect(Self.near(mirrored, -100, 0))
        #expect(Self.sameDirection(mirroredRotation, 5 * .pi / 6), "\(mirroredRotation)")
        #expect(Self.sameDirection(stretchedRotation, atan2(1, 2)), "\(stretchedRotation)")
    }

    /// Bulge 1 from (6000, 0) to (8000, 0) is the counter-clockwise half circle that dips to
    /// (7000, −1000). Mirrored, it runs from (−6000, 0) to (−8000, 0) through (−7000, −1000):
    /// clockwise, bulge −1.
    /// Old output: points [(6000, 0), (8000, 0)], bulges [1, 0].
    @Test("X-048: a bulged LWPOLYLINE with extrusion (0,0,−1) is mirrored and its bulge turns")
    func bulgedPolylineAlongMinusZ() throws {
        let drawing = try Self.read("0\nLWPOLYLINE\n8\n0\n90\n2\n70\n0\n10\n6000\n20\n0\n42\n1\n10\n8000\n20\n0\n" + Self.down)
        guard case let .polyline(points, bulges, closed) = try #require(drawing.entities.first).shape else {
            Issue.record("not a polyline: \(drawing.entities)"); return
        }
        #expect(points == [DXFPoint(x: -6000, y: 0), DXFPoint(x: -8000, y: 0)])
        #expect(bulges == [-1, 0] && !closed)
        let samples = Expander.bulgeSamples(from: points[0], to: points[1], bulge: bulges[0])
        #expect(Self.near(samples[samples.count / 2], -7000, -1000, 1e-6))
    }

    /// Centre and major axis are in the world; the minor axis is N × major × ratio =
    /// (0, 0, −1) × (100, 0, 0) × ½ = (0, −50). Parameters 0…π/2 run from (100, 0) to (0, −50):
    /// the quarter below the axis, which the plan ellipse draws as 3π/2…2π.
    /// Old output: start 0, end π/2 — the quarter above the axis, (100, 0) to (0, 50).
    @Test("X-048: a partial ELLIPSE with extrusion (0,0,−1) draws the quarter below its axis")
    func partialEllipseAlongMinusZ() throws {
        let drawing = try Self.read(
            "0\nELLIPSE\n8\n0\n10\n0\n20\n0\n30\n0\n11\n100\n21\n0\n31\n0\n40\n0.5\n41\n0\n42\n\(Double.pi / 2)\n" + Self.down
        )
        guard case let .ellipse(center, major, ratio, start, end) = try #require(drawing.entities.first).shape else {
            Issue.record("not an ellipse: \(drawing.entities)"); return
        }
        #expect(center == DXFPoint(x: 0, y: 0) && major == DXFPoint(x: 100, y: 0) && ratio == 0.5)
        #expect(Self.near(start, 3 * .pi / 2) && Self.near(end, 2 * .pi), "\(start) … \(end)")
        func point(_ t: Double) -> DXFPoint { DXFPoint(x: 100 * cos(t), y: 50 * sin(t)) }
        #expect(Self.near(point(start), 0, -50) && Self.near(point(end), 100, 0))
        #expect(point((start + end) / 2).y < 0, "the quarter must lie below the major axis")
    }

    /// The INSERT's insertion point and rotation are in its OCS, so the whole placement is
    /// mirrored: the block's 900 line placed at (2000, 0) runs from (−2000, 0) to (−2900, 0).
    /// Old output: (2000, 0) to (2900, 0).
    @Test("X-048: an INSERT with extrusion (0,0,−1) places its block mirrored")
    func insertAlongMinusZ() throws {
        let block = "0\nBLOCK\n8\n0\n2\nB\n70\n0\n10\n0\n20\n0\n30\n0\n" + DXFIntakeTests.line("0", 0, 0, 900, 0) + "0\nENDBLK\n8\n0\n"
        let drawing = try Self.read("0\nINSERT\n8\n0\n2\nB\n10\n2000\n20\n0\n30\n0\n" + Self.down, blocks: block)
        guard case let .polyline(points, _, _) = try #require(drawing.entities.first).shape else {
            Issue.record("not a polyline: \(drawing.entities)"); return
        }
        #expect(points.count == 2 && Self.near(points[0], -2000, 0) && Self.near(points[1], -2900, 0))
    }

    // MARK: - X-048: what does not change

    @Test("X-048: no extrusion, an explicit (0,0,1), a 3D POLYLINE and a LINE read as before")
    func planEntitiesUnchanged() throws {
        let arc = "0\nARC\n8\n0\n10\n2000\n20\n1000\n30\n0\n40\n500\n50\n0\n51\n90\n"
        let plain = try Self.read(arc)
        let explicit = try Self.read(arc + "210\n0\n220\n0\n230\n1\n")
        #expect(plain.entities == explicit.entities)
        #expect(plain.entities.first?.shape == .arc(center: DXFPoint(x: 2000, y: 1000), radius: 500, start: 0, end: 90 * .pi / 180))

        // A 3D polyline (flag 8) keeps world vertices, and a LINE's endpoints are in the world.
        let world = try Self.read(
            "0\nPOLYLINE\n8\n0\n66\n1\n70\n8\n" + Self.down
                + "0\nVERTEX\n8\n0\n10\n10\n20\n20\n30\n0\n70\n32\n0\nVERTEX\n8\n0\n10\n30\n20\n40\n30\n0\n70\n32\n0\nSEQEND\n8\n0\n"
                + "0\nLINE\n8\n0\n10\n1\n20\n2\n30\n0\n11\n3\n21\n4\n31\n0\n" + Self.down
        )
        #expect(world.entities.map(\.shape) == [
            .polyline(points: [DXFPoint(x: 10, y: 20), DXFPoint(x: 30, y: 40)], bulges: [0, 0], closed: false),
            .polyline(points: [DXFPoint(x: 1, y: 2), DXFPoint(x: 3, y: 4)], bulges: [0], closed: false)
        ])
    }

    // MARK: - X-048: tilted and edge-on planes

    /// N = (0, −1, 1)/√2: Ax = Wz × N = (1, 0, 0) and Ay = N × Ax = (0, 1/√2, 1/√2), so seen from
    /// above x stays and y shrinks by 1/√2. A circle of radius 100 is an ellipse of semi-axes
    /// 100 and 70.710678…, drawn sampled.
    @Test("X-048: a CIRCLE on a plane tilted 45° is drawn as its plan view, an ellipse")
    func tiltedCircleIsProjected() throws {
        let drawing = try Self.read("0\nCIRCLE\n8\n0\n10\n0\n20\n0\n30\n0\n40\n100\n210\n0\n220\n-1\n230\n1\n")
        guard case let .polyline(points, _, closed) = try #require(drawing.entities.first).shape else {
            Issue.record("not sampled: \(drawing.entities)"); return
        }
        #expect(closed && points.count > 8)
        let semiMinor = 100 / 2.0.squareRoot()
        for point in points {
            let onEllipse = (point.x / 100) * (point.x / 100) + (point.y / semiMinor) * (point.y / semiMinor)
            #expect(abs(onEllipse - 1) < 1e-9, "\(point)")
        }
        #expect(abs((points.map(\.y).max() ?? 0) - semiMinor) < 1e-9)
        #expect(abs((points.map(\.x).max() ?? 0) - 100) < 1e-9)
    }

    /// N = (1, 0, 0) is a vertical plane: it has no area in the plan.
    /// Old output: the circle drawn flat at (500, 500) as if it lay in the plan.
    @Test("X-048: an entity on a vertical plane is not drawn and is counted as skipped")
    func edgeOnIsSkipped() throws {
        let drawing = try Self.read(
            "0\nCIRCLE\n8\n0\n10\n500\n20\n500\n30\n0\n40\n100\n210\n1\n220\n0\n230\n0\n"
                + DXFIntakeTests.line("0", 0, 0, 10, 0)
        )
        #expect(drawing.entities.count == 1)
        #expect(drawing.skipped == ["CIRCLE (edge-on)": 1])
    }

    @Test("X-048: the arbitrary-axis basis for ±Z is exactly the plan and its mirror")
    func basisAlongZ() {
        #expect(DXFReader.objectCoordinates(extrusion: nil, elevation: 0) == .plan)
        #expect(DXFReader.objectCoordinates(extrusion: (0, 0, 2), elevation: 7) == .plan)
        guard case let .projected(mirror) = DXFReader.objectCoordinates(extrusion: (0, 0, -1), elevation: 25) else {
            Issue.record("−Z must project"); return
        }
        #expect(mirror.apply(DXFPoint(x: 2000, y: 1000)) == DXFPoint(x: -2000, y: 1000))
        #expect(mirror.determinant == -1 && mirror.isSimilarity)
        #expect(DXFReader.objectCoordinates(extrusion: (0, 0, 0), elevation: 0) == .plan, "a zero extrusion reads as the default")
    }
}
