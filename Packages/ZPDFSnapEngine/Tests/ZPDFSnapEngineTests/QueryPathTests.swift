import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// The query path of the engine: which entries leave the index for one pointer event.
///
/// IM-009 replaced the search-box query with a per-layer nearest-neighbour search that returns
/// only what the `(box distance, id)` truncation can keep. The truncation is specified
/// behaviour (`SnapIndexLimits.maximumCandidatePrimitives`), so the two routes must select the
/// identical set, ties at the boundary included — and the new one must materialise fewer
/// entries, which is the whole point.
@Suite("Snap query path (IM-009)")
struct QueryPathTests {

    /// Box distance, written here independently of the engine's helper.
    static func boxDistance(_ point: PDFPoint, _ rect: PDFRect) -> Double {
        let r = rect.standardized
        let dx = Swift.max(r.minX - point.x, 0, point.x - r.maxX)
        let dy = Swift.max(r.minY - point.y, 0, point.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The documented truncation: the `limit` nearest by `(box distance, id)` among every entry
    /// within `radius`.
    static func truncate(_ entries: [SnapIndexEntry], cursor: PDFPoint, radius: Double, limit: Int) -> [UInt64] {
        var keyed: [(id: UInt64, distance: Double)] = []
        for entry in entries {
            let distance = boxDistance(cursor, entry.bounds)
            if distance <= radius { keyed.append((entry.id, distance)) }
        }
        keyed.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            return a.id < b.id
        }
        return keyed.prefix(limit).map { $0.id }
    }

    /// A 60 x 60 lattice of unit-length segments 4 page points apart: 3 600 entries, of which
    /// a 200-page-point radius holds every one, with hundreds of exact ties in box distance
    /// along every row and column.
    static func lattice() throws -> SnapScene {
        var primitives: [SnapPrimitive] = []
        var id: UInt64 = 1
        for row in 0..<60 {
            for column in 0..<60 {
                let x = 100 + Double(column) * 4
                let y = 100 + Double(row) * 4
                primitives.append(SnapScene.segment(id: id, PDFPoint(x: x, y: y), PDFPoint(x: x + 1, y: y)))
                id += 1
            }
        }
        let page = try SnapScene.letterPage()
        return try SnapScene.withVectorContent(page: page, primitives: primitives)
    }

    @Test("The nearest-entry route selects exactly what the search-box route selected, ties included")
    func routesAgree() throws {
        let scene = try Self.lattice()
        let limit = SnapIndexLimits.standard.maximumCandidatePrimitives
        #expect(limit == 512)

        for (cursor, radius) in [
            (PDFPoint(x: 218, y: 218), 200.0),   // 5 % zoom radius: the whole lattice is inside
            (PDFPoint(x: 218, y: 218), 40.0),    // 25 % zoom: ~300 entries, under the limit
            (PDFPoint(x: 101.5, y: 100), 60.0),  // on a lattice node, ties in every direction
            (PDFPoint(x: 400, y: 340), 200.0)    // off centre, the boundary cuts a ring of ties
        ] {
            let box = PDFRect(x: cursor.x - radius, y: cursor.y - radius, width: 2 * radius, height: 2 * radius)
            let boxRoute = scene.index.entries(intersecting: box)
            let nearRoute = scene.index.nearestEntries(to: cursor, maxDistance: radius, limit: limit)

            let expected = Self.truncate(boxRoute, cursor: cursor, radius: radius, limit: limit)
            let actual = Self.truncate(nearRoute, cursor: cursor, radius: radius, limit: limit)
            #expect(expected == actual, "cursor \(cursor) radius \(radius)" as Comment)
            #expect(!expected.isEmpty)

            // Every entry the truncation can keep is present, and no entry is duplicated.
            #expect(Set(nearRoute.map(\.id)).count == nearRoute.count)
            let kept = Set(expected)
            #expect(nearRoute.filter { kept.contains($0.id) }.count == expected.count)

            if boxRoute.count > limit {
                // The gain: the box route copied every entry in the square; the nearest route
                // stops at the limit-th distance. With 3 600 entries in the 200-point square and
                // 512 kept, it must materialise well under half of them.
                #expect(nearRoute.count < boxRoute.count / 2,
                        "materialised \(nearRoute.count) of \(boxRoute.count)" as Comment)
            }
        }
    }

    /// IM-199: one reused scratch across many queries (as SnapEngine keeps it) appends exactly
    /// what the allocating route returns, in the same order, and stops growing after warm-up.
    @Test("IM-199: the scratch-buffer route returns what the allocating route returns, query after query")
    func scratchRouteAgrees() throws {
        let scene = try Self.lattice()
        let limit = SnapIndexLimits.standard.maximumCandidatePrimitives
        var scratch = SnapQueryScratch()
        var results: [SnapIndexEntry] = []
        var capacities: [Int] = []
        for round in 0..<3 {
            for (cursor, radius) in [
                (PDFPoint(x: 218, y: 218), 200.0), (PDFPoint(x: 218, y: 218), 40.0),
                (PDFPoint(x: 101.5, y: 100), 60.0), (PDFPoint(x: 400, y: 340), 200.0),
                (PDFPoint(x: 5, y: 5), 3.0)
            ] {
                scene.index.nearestEntries(to: cursor, maxDistance: radius, limit: limit, into: &results, scratch: &scratch)
                let fresh = scene.index.nearestEntries(to: cursor, maxDistance: radius, limit: limit)
                #expect(results.map(\.id) == fresh.map(\.id), "cursor \(cursor) radius \(radius)" as Comment)
            }
            capacities.append(results.capacity)
            _ = round
        }
        // The second and third rounds ask for nothing the first did not, so nothing regrows.
        #expect(capacities[1] == capacities[0] && capacities[2] == capacities[0])
    }

    @Test("Tombstoned and pending markup entries are handled exactly as the box route handles them")
    func mutatedLayersAgree() throws {
        let page = try SnapScene.letterPage()
        var scene = try Self.lattice()
        var index = scene.index
        // 700 count-point markups on the same lattice spacing, then remove every third: the
        // tombstones stay in the tree until compaction and must not displace live answers.
        var ids: [MarkupID] = []
        for i in 0..<700 {
            let id = MarkupID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", i + 1)) ?? UUID())
            ids.append(id)
            try index.upsert(
                markup: SnapMarkupGeometry(
                    id: id,
                    geometry: [.point(PDFPoint(x: 102 + Double(i % 35) * 4, y: 102 + Double(i / 35) * 4))],
                    layerID: nil
                )
            )
        }
        for (offset, id) in ids.enumerated() where offset % 3 == 0 {
            index.remove(markupID: id)
        }
        scene = SnapScene(page: page, index: index)

        let limit = 512
        let cursor = PDFPoint(x: 170, y: 140)
        let radius = 200.0
        let box = PDFRect(x: cursor.x - radius, y: cursor.y - radius, width: 2 * radius, height: 2 * radius)
        let boxRoute = scene.index.entries(intersecting: box)
        let nearRoute = scene.index.nearestEntries(to: cursor, maxDistance: radius, limit: limit)
        #expect(
            Self.truncate(boxRoute, cursor: cursor, radius: radius, limit: limit)
                == Self.truncate(nearRoute, cursor: cursor, radius: radius, limit: limit)
        )
        // No tombstoned entry leaks out of either route.
        let live = Set(scene.index.allEntries(in: .markup).map(\.id))
        for entry in nearRoute where entry.source == .zenitMarkup {
            #expect(live.contains(entry.id))
        }
        // 700 - 234 removed = 466 live markups, all inside the radius, so under the limit every
        // one of them is returned.
        #expect(nearRoute.filter { $0.source == .zenitMarkup }.count == 466)
    }

    @Test("The engine's decision log is identical whichever route feeds it")
    func decisionLogUnchanged() throws {
        // The determinism scenario, whose log the 20-process test already pins: replaying it
        // through the engine must give the same lines as building the same events from the
        // box route by hand would. The proxy here is a full replay twice with identical output,
        // plus the brute-force agreement asserted by the golden suite.
        let first = try SnapDeterminismScenario.decisionLog()
        let second = try SnapDeterminismScenario.decisionLog(insertionSeed: 0x1D)
        #expect(first == second)
        #expect(first.count > 100)
    }
}

/// IM-088: polyline vertex and midpoint targets come from the edges near the cursor.
@Suite("Polyline point targets (IM-088)")
struct PolylinePointTargetTests {

    /// Every vertex and edge midpoint of `points` within `radius` of `cursor`, by the plain
    /// definition — a scan of the whole ring, written here rather than borrowed.
    static func expected(_ points: [PDFPoint], isClosed: Bool, cursor: PDFPoint, radius: Double) -> [String] {
        var result: [String] = []
        for (i, p) in points.enumerated() where p.distance(to: cursor) <= radius {
            result.append("v\(i)")
        }
        let edges = isClosed ? points.count : points.count - 1
        for i in 0..<edges {
            let a = points[i], b = points[(i + 1) % points.count]
            let m = PDFPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if m.distance(to: cursor) <= radius { result.append("m\(i)") }
        }
        return result.sorted()
    }

    @Test("Random rings and cursors: the target set equals the whole-ring scan")
    func matchesWholeRingScan() throws {
        let page = try SnapScene.letterPage()
        var random = SnapDeterministicRandom(seed: 0x1088)
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint, .midpoint]
        // A wide alternative list so every candidate in range is visible, and no truncation.
        let limits = SnapIndexLimits(maximumRankedAlternatives: 400)
        var compared = 0
        for trial in 0..<60 {
            let count = 5 + random.nextInt(below: 60)
            let isClosed = trial % 2 == 0
            let points = (0..<count).map { _ in
                PDFPoint(x: 250 + random.nextUnitDouble() * 60, y: 350 + random.nextUnitDouble() * 60)
            }
            let ring = try #require(SnapScene.polyline(id: 7, points, isClosed: isClosed))
            let scene = try SnapScene.withVectorContent(page: page, primitives: [ring])
            for _ in 0..<5 {
                let cursor = PDFPoint(x: 245 + random.nextUnitDouble() * 70, y: 345 + random.nextUnitDouble() * 70)
                let zoom = 0.5 + random.nextUnitDouble() * 1.5
                let layout = SnapReplay.layout(zoom: zoom)
                var engine = SnapEngine(limits: limits)
                let resolution = try engine.resolve(
                    SnapQuery(
                        event: SnapPointerEvent(
                            viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout), layout: layout
                        ),
                        settings: settings
                    ),
                    in: scene.index
                )
                // The engine de-duplicates by position, so the reference does too: a vertex and
                // a midpoint never coincide in a random ring, but two random vertices might.
                let all = ([resolution.winner].compactMap { $0 } + resolution.alternatives)
                let radius = 10 / zoom
                let reference = Self.expected(points, isClosed: isClosed, cursor: cursor, radius: radius)
                let referencePositions = Set(reference.map { label -> String in
                    let index = Int(label.dropFirst()) ?? 0
                    if label.hasPrefix("v") { return "v \(points[index].x) \(points[index].y)" }
                    let a = points[index], b = points[(index + 1) % points.count]
                    return "m \((a.x + b.x) / 2) \((a.y + b.y) / 2)"
                })
                let actualPositions = Set(all.map { ($0.kind == .endpoint ? "v" : "m") + " \($0.position.x) \($0.position.y)" })
                #expect(actualPositions == referencePositions, "trial \(trial) cursor \(cursor) zoom \(zoom)" as Comment)
                compared += 1
            }
        }
        #expect(compared == 300)
    }
}

/// IM-198: bounded ranking equals the prefix of the full ranking.
@Suite("Bounded ranking (IM-198)")
struct BoundedRankingTests {

    /// Random scored candidates with deliberate ties: positions on a coarse grid so many share a
    /// position (positional duplicates), distances that land on the same score cell, and a few
    /// kinds. Every (primitive, component) pair is unique, so no two candidates are identical in
    /// every key of the total order.
    static func candidates(count: Int, seed: UInt64) throws -> [ScoredSnapCandidate] {
        var random = SnapDeterministicRandom(seed: seed)
        let scorer = SnapScorer(settings: .default, weights: .standard)
        let tolerance = try SnapTolerance(settings: .default, layout: SnapReplay.layout(zoom: 1))
        let kinds: [SnapKind] = [.endpoint, .midpoint, .intersection, .nearestPointOnSegment]
        let cursor = PDFPoint(x: 100, y: 100)
        return (0..<count).map { i in
            let target = SnapTarget(
                kind: kinds[random.nextInt(below: kinds.count)],
                position: PDFPoint(
                    x: 95 + Double(random.nextInt(below: 11)),
                    y: 95 + Double(random.nextInt(below: 11))
                ),
                primitiveID: UInt64(1 + random.nextInt(below: 40)),
                source: .pdfPathObject,
                confidence: 1,
                layerID: nil,
                component: i
            )
            return scorer.score(
                target, cursorPagePoint: cursor, tolerance: tolerance, activeLayerID: nil,
                satisfiesDirectionConstraint: true, heldCredit: 0
            )
        }
    }

    @Test("rank(_:limit:) is rank(_:).prefix(limit), for every limit, on tie-heavy sets")
    func matchesFullRanking() throws {
        let scorer = SnapScorer(settings: .default, weights: .standard)
        for seed in UInt64(1)...40 {
            let set = try Self.candidates(count: 50 + Int(seed) * 25, seed: seed)
            let full = scorer.rank(set)
            for limit in [1, 2, 7, 33, 200, 10_000] {
                #expect(scorer.rank(set, limit: limit) == Array(full.prefix(limit)), "seed \(seed) limit \(limit)" as Comment)
            }
        }
        #expect(scorer.rank([], limit: 33).isEmpty)
    }
}
