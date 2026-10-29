import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
@testable import ZPDFSnapEngine
import ZPDFVectorExtraction

/// Quality-loop iteration 1, area "quantities-core": snap and trace findings R-173, R-180, R-185.
@Suite("Iteration 1 quantities-core (snap)")
struct Iter1QuantitiesCoreSnapTests {

    static func point(_ id: UInt64, x: Double, y: Double) -> SnapIndexEntry {
        let position = PDFPoint(x: x, y: y)
        return SnapIndexEntry(
            primitive: SnapPrimitive(
                id: id, bounds: PDFRect(origin: position, size: .zero), kind: .point,
                geometry: .point(position), sourceObjectID: id, confidence: 1, layerID: nil
            ),
            source: .pdfPathObject, ownerID: nil, kindSet: .pdfVector
        )
    }

    /// The box distance as the engine's truncation defines it, written out here.
    static func boxDistance(_ point: PDFPoint, _ rect: PDFRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - R-180

    /// The cases the rounded box dropped, found by replaying the tree's own arithmetic: a cursor
    /// at `x` near the page's left edge, a point entry straight to its right at `e`, whose box
    /// distance is `d = e − x`. Where the distance exceeds the coordinate, `d` is rounded, and
    /// the tree's query box, which ends at `(x − d) + 2d`, can end below `e` — the entry was
    /// outside the old box although it is exactly `d` away (a few percent of such placements at
    /// 5 % zoom, where the radius is 200 pt). With the entry as the nearest (`limit` 1) and two
    /// farther entries beside it, old output: an empty answer. Now every such case keeps it.
    @Test("R-180: the nearest route keeps the limit-th entry that the rounded query box used to drop")
    func nearestKeepsTheCutoffEntry() throws {
        var state: UInt64 = 0xC0FF_EE00_1234_5678
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var cases: [(cursor: PDFPoint, entryX: Double)] = []
        var tried = 0
        while cases.count < 25, tried < 2_000_000 {
            tried += 1
            let x = 50 * next()
            let entryX = x + 0.01 + 190 * next()
            let distance = entryX - x
            if (x - distance) + 2 * distance < entryX {
                cases.append((PDFPoint(x: x, y: 500 + 1_000 * next()), entryX))
            }
        }
        #expect(cases.count == 25, "the replay must find cases the old box dropped (tried \(tried))")
        for (index, sample) in cases.enumerated() {
            let cursor = sample.cursor
            let nearest = Self.point(1, x: sample.entryX, y: cursor.y)
            let farther = [
                Self.point(2, x: sample.entryX + 5, y: cursor.y),
                Self.point(3, x: cursor.x, y: cursor.y + (sample.entryX - cursor.x) + 30)
            ]
            let layer = try SnapLayer(entries: [nearest] + farther)
            var found: [SnapIndexEntry] = []
            layer.nearest(to: cursor, maxDistance: 400, limit: 1, into: &found)
            #expect(found.map(\.id) == [1], "case \(index): \(sample)")
        }
    }

    // MARK: - R-173

    /// 700 points within 60 pt of the cursor (the radius at 5 % zoom is 200 pt), with repeated
    /// distances so the id tie-break matters. Above the 512 limit the engine keeps exactly the
    /// nearest 512 by (box distance, id), in that order — computed here by sorting every entry.
    /// The golden brute-force scorer does not truncate, so this rule had no test of its own.
    @Test("R-173: above the candidate limit the engine keeps exactly the nearest 512 by (distance, id)")
    func candidateTruncationRule() throws {
        let cursor = PDFPoint(x: 1_000, y: 1_000)
        var entries: [SnapIndexEntry] = []
        var id: UInt64 = 1
        for ring in 1...35 {
            let radius = Double(ring) * 1.7
            for step in 0..<20 {
                let angle = Double(step) * .pi / 10
                entries.append(Self.point(id * 7_919 % 100_003, x: cursor.x + radius * cos(angle), y: cursor.y + radius * sin(angle)))
                id += 1
            }
        }
        #expect(entries.count == 700)
        let limits = SnapIndexLimits.standard
        #expect(limits.maximumCandidatePrimitives == 512)
        let layer = try SnapLayer(entries: entries)
        var nearest: [SnapIndexEntry] = []
        layer.nearest(to: cursor, maxDistance: 200, limit: limits.maximumCandidatePrimitives, into: &nearest)
        let locals = SnapTargetGenerator(limits: limits).localPrimitives(nearest, cursor: cursor, radius: 200)

        let reference = entries
            .map { (id: $0.id, distance: Self.boxDistance(cursor, $0.bounds)) }
            .sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.id < $1.id }
            .prefix(limits.maximumCandidatePrimitives)
        #expect(locals.map(\.entry.id) == reference.map(\.id))
    }

    // MARK: - R-185

    /// A 2.13 × 1.07 `re` rectangle at (12345.17, 13579.31): 2.2791 page points². The traced
    /// area is now the geometry package's origin-shifted, compensated shoelace of the traced
    /// ring, bit for bit. Old output: RegionTracer's own raw-coordinate sum, which forms products
    /// near 1.7e8 and loses digits to cancellation — 2.2791000306…, off by 3e-8 on this ring; the
    /// raw formula is replayed below to show it.
    @Test("R-185: a traced region's area is PolygonMath's shoelace of its ring")
    func tracedAreaUsesTheOneShoelace() throws {
        let rectangle = RegionTracerTests.rectangle(1, x: 12_345.17, y: 13_579.31, width: 2.13, height: 1.07)
        let result = RegionTracer.trace(primitives: [rectangle], click: PDFPoint(x: 12_346, y: 13_580))
        let region = try #require(result.region, "expected a traced region, got \(result)")
        #expect(region.area == PolygonMath.area(region.ring))
        #expect(abs(region.area - 2.2791) <= 1e-9)

        var raw = 0.0
        var previous = region.ring[region.ring.count - 1]
        for vertex in region.ring {
            raw += previous.x * vertex.y - vertex.x * previous.y
            previous = vertex
        }
        #expect(abs(abs(raw / 2) - 2.2791) > 1e-9, "the old raw sum is off on this ring")
    }
}
