import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFVectorExtraction

/// Measurements for the performance improvements IM-087, IM-088, IM-090, IM-092, IM-094 and
/// IM-198.
///
/// Each test prints a `FIX-MEASURE` line with thread-CPU percentiles, so a change can be
/// measured before and after. Thread CPU, not wall clock: the machine these run on may be
/// shared. Nothing here asserts a time budget — the S12/S13 budgets are asserted by
/// `SnapPerformanceTests` — but every test asserts that the work it times produced the result
/// it should, so a change that made a case fast by making it wrong fails here.
@Suite("Performance improvement measurements (IM-087, IM-088, IM-090, IM-092, IM-094, IM-198)", .serialized)
struct ImprovementMeasurementTests {

    static func cpuMilliseconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    static func describe(_ label: String, _ samples: [Double]) -> String {
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[Swift.min(sorted.count - 1, Int((q * Double(sorted.count - 1)).rounded()))] }
        return String(
            format: "FIX-MEASURE %@  n=%d  cpu p50=%.4f ms  p95=%.4f ms  max=%.4f ms  mean=%.4f ms",
            label, sorted.count, at(0.5), at(0.95), sorted.last ?? 0,
            sorted.reduce(0, +) / Double(Swift.max(1, sorted.count))
        )
    }

    // MARK: - IM-087

    @Test("Curve-heavy page with tangent and perpendicular snap switched off (IM-087)")
    func curveHeavyDisabledKinds() throws {
        // 20 000 S-shaped cubics on an 80 x 250 lattice, 10 page points apart.
        var primitives: [SnapPrimitive] = []
        var id: UInt64 = 1
        for row in 0..<80 {
            for column in 0..<250 {
                let x = 20 + Double(column) * 10
                let y = 20 + Double(row) * 10
                if let cubic = SnapScene.cubic(
                    id: id,
                    PDFPoint(x: x, y: y), PDFPoint(x: x + 3, y: y + 8),
                    PDFPoint(x: x + 6, y: y - 4), PDFPoint(x: x + 9, y: y + 5)
                ) {
                    primitives.append(cubic)
                }
                id += 1
            }
        }
        let page = try SnapScene.letterPage(media: PDFRect(x: 0, y: 0, width: 2600, height: 900))
        let scene = try SnapScene.withVectorContent(page: page, primitives: primitives)
        var settings = SnapSettings.default
        // Intersections are off as well: two rows of these cubics overlap, and the cubic x cubic
        // solve would otherwise dominate the time and hide what IM-087 changes.
        settings.enabledKinds = Set(SnapKind.allCases).subtracting([.tangent, .perpendicularProjection, .intersection])
        let layout = SnapReplay.layout(zoom: 0.5)
        var random = SnapDeterministicRandom(seed: "im-087")
        var engine = SnapEngine()
        var samples: [Double] = []
        var winners = 0
        for i in 0..<400 {
            let cursor = PDFPoint(x: 100 + random.nextUnitDouble() * 2300, y: 100 + random.nextUnitDouble() * 600)
            let event = SnapPointerEvent(
                viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout),
                layout: layout, anchorPagePoint: PDFPoint(x: cursor.x - 30, y: cursor.y + 25), sequence: i
            )
            let start = Self.cpuMilliseconds()
            let resolution = try engine.resolve(SnapQuery(event: event, settings: settings), in: scene.index)
            samples.append(Self.cpuMilliseconds() - start)
            if let winner = resolution.winner {
                winners += 1
                #expect(winner.kind != .tangent && winner.kind != .perpendicularProjection && winner.kind != .intersection)
            }
        }
        print(Self.describe("IM-087 20k cubics zoom 0.5 tangent+perpendicular+intersection off", samples))
        #expect(winners == 400)
    }

    // MARK: - IM-088

    @Test("One 50 000-vertex closed polyline under the cursor (IM-088)")
    func hugeRingUnderCursor() throws {
        // A circle of radius 2000 drawn as 50 000 vertices, edges 0.25 page points long.
        let count = 50_000
        let centre = PDFPoint(x: 2500, y: 2500)
        let points = (0..<count).map { i -> PDFPoint in
            let angle = Double(i) / Double(count) * 2 * Double.pi
            return PDFPoint(x: centre.x + 2000 * Foundation.cos(angle), y: centre.y + 2000 * Foundation.sin(angle))
        }
        let page = try SnapScene.letterPage(media: PDFRect(x: 0, y: 0, width: 5000, height: 5000))
        let ring = try #require(SnapScene.polyline(id: 1, points, isClosed: true))
        let scene = try SnapScene.withVectorContent(page: page, primitives: [ring])
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint, .midpoint]
        let layout = SnapReplay.layout(zoom: 4)
        var engine = SnapEngine()
        var samples: [Double] = []
        for i in 0..<300 {
            // Walk along the ring, 1 page point outside it.
            let angle = Double(i) / 300 * 2 * Double.pi
            let cursor = PDFPoint(x: centre.x + 2001 * Foundation.cos(angle), y: centre.y + 2001 * Foundation.sin(angle))
            let event = SnapPointerEvent(
                viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout), layout: layout, sequence: i
            )
            let start = Self.cpuMilliseconds()
            let resolution = try engine.resolve(SnapQuery(event: event, settings: settings), in: scene.index)
            samples.append(Self.cpuMilliseconds() - start)
            #expect(resolution.winner != nil)
        }
        print(Self.describe("IM-088 50k-vertex ring zoom 4", samples))
    }

    // MARK: - IM-090

    @Test("Circle x cubic intersections in both argument orders (IM-090)")
    func circleCubicIntersections() throws {
        var random = SnapDeterministicRandom(seed: "im-090")
        var pairs: [(SnapCurve, SnapCurve)] = []
        for _ in 0..<2000 {
            let c = PDFPoint(x: 200 + random.nextUnitDouble() * 50, y: 200 + random.nextUnitDouble() * 50)
            let circle = SnapCurve.circle(CircleGeometry(center: c, radius: 40 + random.nextUnitDouble() * 30))
            let cubic = SnapCurve.cubic(
                p0: PDFPoint(x: 120 + random.nextUnitDouble() * 20, y: 150 + random.nextUnitDouble() * 100),
                p1: PDFPoint(x: 180 + random.nextUnitDouble() * 40, y: 100 + random.nextUnitDouble() * 200),
                p2: PDFPoint(x: 240 + random.nextUnitDouble() * 40, y: 100 + random.nextUnitDouble() * 200),
                p3: PDFPoint(x: 310 + random.nextUnitDouble() * 20, y: 150 + random.nextUnitDouble() * 100)
            )
            pairs.append((circle, cubic))
        }
        var circleFirst: [Double] = []
        var cubicFirst: [Double] = []
        var hits = 0
        var disagreements = 0
        for (circle, cubic) in pairs {
            var start = Self.cpuMilliseconds()
            let a = SnapIntersectionSolver.intersections(circle, cubic, near: PDFPoint(x: 225, y: 225), within: 400)
            circleFirst.append(Self.cpuMilliseconds() - start)
            start = Self.cpuMilliseconds()
            let b = SnapIntersectionSolver.intersections(cubic, circle, near: PDFPoint(x: 225, y: 225), within: 400)
            cubicFirst.append(Self.cpuMilliseconds() - start)
            hits += a.count
            if a.count != b.count || zip(a, b).contains(where: { $0.point.distance(to: $1.point) > 1e-9 }) {
                disagreements += 1
            }
            for hit in a {
                // S4's defining property: on both curves.
                #expect(try #require(circle.nearestPoint(to: hit.point)).distance <= 1e-7)
                #expect(try #require(cubic.nearestPoint(to: hit.point)).distance <= 1e-7)
            }
        }
        print(Self.describe("IM-090 circle x cubic, circle first", circleFirst))
        print(Self.describe("IM-090 circle x cubic, cubic first", cubicFirst))
        print("FIX-MEASURE IM-090 hits=\(hits) order-disagreements=\(disagreements)")
        #expect(hits > 1000)
        #expect(disagreements == 0)
    }

    // MARK: - IM-092

    @Test("Markup upsert cost with 100, 1 000 and 10 000 markups committed (IM-092)")
    func markupUpsertScaling() throws {
        let page = try SnapScene.letterPage()
        var means: [Double] = []
        for committed in [100, 1_000, 10_000] {
            var markups: [SnapMarkupGeometry] = []
            for i in 0..<committed {
                markups.append(
                    SnapMarkupGeometry(
                        id: MarkupID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", i + 1)) ?? UUID()),
                        geometry: [.point(PDFPoint(x: Double(i % 500), y: Double(i / 500)))],
                        layerID: nil
                    )
                )
            }
            var index = try SnapIndexBuilder().build(page: page, extraction: nil, markups: markups)
            let dragged = markups[committed / 2].id
            var samples: [Double] = []
            // 200 drag events of one committed markup: remove its committed entry, add a
            // pending one, and keep replacing it. Kept under the compaction threshold on
            // purpose, so the time measured is the owner lookup and not a rebuild.
            for step in 0..<200 {
                let start = Self.cpuMilliseconds()
                try index.upsert(markup: SnapMarkupGeometry(id: dragged, geometry: [.point(PDFPoint(x: 300, y: Double(step)))], layerID: nil))
                samples.append(Self.cpuMilliseconds() - start)
            }
            #expect(index.markupPrimitiveCount == committed)
            print(Self.describe("IM-092 upsert with \(committed) committed", samples))
            means.append(samples.reduce(0, +) / Double(samples.count))
        }
        print("FIX-MEASURE IM-092 mean ratio 10000/100 = \(String(format: "%.2f", means[2] / Swift.max(means[0], 1e-9)))")
    }

    // MARK: - IM-198

    @Test("Ranking 2 000 scored candidates to keep 33 (IM-198)")
    func boundedRanking() throws {
        var random = SnapDeterministicRandom(seed: "im-198")
        let scorer = SnapScorer(settings: .default, weights: .standard)
        let tolerance = try SnapTolerance(settings: .default, layout: SnapReplay.layout(zoom: 0.05))
        let cursor = PDFPoint(x: 1000, y: 1000)
        var sets: [[ScoredSnapCandidate]] = []
        for _ in 0..<50 {
            sets.append((0..<2000).map { i in
                let target = SnapTarget(
                    kind: [.endpoint, .midpoint, .nearestPointOnSegment][random.nextInt(below: 3)],
                    position: PDFPoint(x: 800 + random.nextUnitDouble() * 400, y: 800 + random.nextUnitDouble() * 400),
                    primitiveID: UInt64(1 + random.nextInt(below: 512)),
                    source: .pdfPathObject, confidence: 1, layerID: nil, component: i
                )
                return scorer.score(target, cursorPagePoint: cursor, tolerance: tolerance, activeLayerID: nil,
                                    satisfiesDirectionConstraint: true, heldCredit: 0)
            })
        }
        var full: [Double] = []
        var bounded: [Double] = []
        for set in sets {
            var start = Self.cpuMilliseconds()
            let a = Array(scorer.rank(set).prefix(33))
            full.append(Self.cpuMilliseconds() - start)
            start = Self.cpuMilliseconds()
            let b = scorer.rank(set, limit: 33)
            bounded.append(Self.cpuMilliseconds() - start)
            #expect(a == b)
        }
        print(Self.describe("IM-198 full sort then prefix 33 of 2000", full))
        print(Self.describe("IM-198 bounded rank(limit: 33) of 2000", bounded))
    }

    // MARK: - IM-094

    static func line(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> VectorPrimitive {
        let start = CGPoint(x: x0, y: y0)
        let end = CGPoint(x: x1, y: y1)
        return VectorPrimitive(
            id: id, parentID: nil, kind: .lineSegment, geometry: .line(VectorLine(start: start, end: end)),
            bounds: VectorBounds(point: start).union(end), sourceObjectID: id, subpathIndex: 0,
            nestingDepth: 0, paint: .stroked, strokeWidth: 0.5, strokeIsDashed: false,
            clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: nil
        )
    }

    /// A 150 x 150 grid of 20 x 20 rooms (walls shared, 302 long lines) plus 67 500 short
    /// hatch strokes, 3 per room, clear of the walls: 67 802 primitives.
    static func tracePage() -> [VectorPrimitive] {
        var primitives: [VectorPrimitive] = []
        var id: UInt64 = 1
        for i in 0...150 {
            let c = Double(i) * 20
            primitives.append(line(id, c, 0, c, 3000)); id += 1
            primitives.append(line(id, 0, c, 3000, c)); id += 1
        }
        for row in 0..<150 {
            for column in 0..<150 {
                let x = Double(column) * 20
                let y = Double(row) * 20
                for k in 0..<3 {
                    let yy = y + 12 + Double(k) * 2
                    primitives.append(line(id, x + 12, yy, x + 17, yy)); id += 1
                }
            }
        }
        return primitives
    }

    @Test("Room trace on a 67 802-primitive page: 20 clicks in different rooms (IM-094)")
    func traceClicks() throws {
        let primitives = Self.tracePage()
        var clicks: [PDFPoint] = []
        var random = SnapDeterministicRandom(seed: "im-094")
        for _ in 0..<20 {
            let column = Double(random.nextInt(below: 150))
            let row = Double(random.nextInt(below: 150))
            clicks.append(PDFPoint(x: column * 20 + 5, y: row * 20 + 5))
        }
        var samples: [Double] = []
        for click in clicks {
            let start = Self.cpuMilliseconds()
            let result = RegionTracer.trace(primitives: primitives, click: click)
            samples.append(Self.cpuMilliseconds() - start)
            // 20 x 20 = 400: the hatch strokes are islands inside the room.
            let region = try #require(result.region, "\(result)")
            #expect(Swift.abs(region.area - 400) <= 1e-9)
        }
        print(Self.describe("IM-094 trace(primitives:) per click, 67 802 primitives", samples))
        measurePrepared(primitives: primitives, clicks: clicks)
    }
}

extension ImprovementMeasurementTests {
    /// The prepared path: collection and indexing once, then each click.
    func measurePrepared(primitives: [VectorPrimitive], clicks: [PDFPoint]) {
        var start = Self.cpuMilliseconds()
        let prepared = RegionTracer.prepare(primitives: primitives)
        let prepareTime = Self.cpuMilliseconds() - start
        var samples: [Double] = []
        for click in clicks {
            start = Self.cpuMilliseconds()
            let result = RegionTracer.trace(prepared, click: click)
            samples.append(Self.cpuMilliseconds() - start)
            #expect(result == RegionTracer.trace(primitives: primitives, click: click))
        }
        print(String(format: "FIX-MEASURE IM-094 prepare once: %.4f ms (%d segments)", prepareTime, prepared.segmentCount))
        print(Self.describe("IM-094 trace(prepared) per click, 67 802 primitives", samples))
    }
}
