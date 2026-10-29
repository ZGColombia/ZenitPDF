import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Match by example, the matching half: the estimator confirms one instance, the matcher
/// finds the rest and **states what it skipped and why**.
///
/// Every expected value below is derived by hand in the comment beside it; no
/// expectation is produced by the code under test (`QUALITY_BAR` 2.6).
struct SymbolMatchTests {

    // MARK: - The synthetic door symbol

    /// A chiral four-stroke "door": leaf, threshold, diagonal chord, stub. Chiral on
    /// purpose — no in-plane rotation maps its mirror image back onto it, so the mirror
    /// flag in a match is a real claim, not a freebie.
    ///
    ///     leaf       (0,0)–(0,8)
    ///     threshold  (0,0)–(6,0)
    ///     chord      (0,8)–(5,3)
    ///     stub       (6,0)–(6,1.5)
    static let doorStrokes: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 8)),
        (CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0)),
        (CGPoint(x: 0, y: 8), CGPoint(x: 5, y: 3)),
        (CGPoint(x: 6, y: 0), CGPoint(x: 6, y: 1.5))
    ]

    static func linePrimitive(_ id: UInt64, _ start: CGPoint, _ end: CGPoint) -> VectorPrimitive {
        let line = VectorLine(start: start, end: end)
        return VectorPrimitive(
            id: id,
            parentID: nil,
            kind: .lineSegment,
            geometry: .line(line),
            bounds: line.bounds,
            sourceObjectID: id,
            subpathIndex: 0,
            nestingDepth: 0,
            paint: .stroked,
            strokeWidth: 1,
            strokeIsDashed: false,
            clipRelation: .unclipped,
            clipBounds: nil,
            confidence: 1,
            layerID: nil
        )
    }

    /// The four door strokes with `map` applied to every endpoint, ids ascending from
    /// `firstID`.
    static func door(firstID: UInt64, _ map: (CGPoint) -> CGPoint) -> [VectorPrimitive] {
        doorStrokes.enumerated().map { index, stroke in
            linePrimitive(firstID + UInt64(index), map(stroke.0), map(stroke.1))
        }
    }

    static func translation(_ dx: Double, _ dy: Double) -> (CGPoint) -> CGPoint {
        { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// The standard scene: four true instances and three things that are not the door.
    ///
    /// | ids | what | expected |
    /// |---|---|---|
    /// | 1–4 | the exemplar, translated to (100, 100) | confirmed, identity |
    /// | 11–14 | rotated 90° CCW, at (300, 100) | confirmed, not mirrored |
    /// | 21–24 | mirrored (x negated), at (500, 100) | confirmed, mirrored |
    /// | 31–34 | scaled 2×, at (100, 300) | confirmed, scale 2 |
    /// | 41–44 | a Z of similar size, at (700, 100) | rejected: residual |
    /// | 51 | one lone stroke, at (900, 100) | rejected: too few |
    /// | 61–64 | the door at 8×, at (400, 600) | rejected: scale band |
    static func standardScene() -> [VectorPrimitive] {
        var primitives: [VectorPrimitive] = []
        // Exemplar instance.
        primitives += door(firstID: 1, translation(100, 100))
        // Rotated 90° counter-clockwise: (x, y) → (−y, x), then + (300, 100).
        primitives += door(firstID: 11) { CGPoint(x: -$0.y + 300, y: $0.x + 100) }
        // Mirrored: x → −x, then + (500, 100). The inverted stroke is the *threshold*:
        // local (0,0)–(6,0) becomes page (500,100)–(494,100) — its run reverses.
        primitives += door(firstID: 21) { CGPoint(x: -$0.x + 500, y: $0.y + 100) }
        // Scaled 2×: (x, y) → (2x, 2y), then + (100, 300).
        primitives += door(firstID: 31) { CGPoint(x: 2 * $0.x + 100, y: 2 * $0.y + 300) }
        // Z-shaped decoy with a similar bounding box (6 × 8) but different linework.
        primitives.append(linePrimitive(41, CGPoint(x: 700, y: 108), CGPoint(x: 706, y: 108)))
        primitives.append(linePrimitive(42, CGPoint(x: 706, y: 108), CGPoint(x: 700, y: 100)))
        primitives.append(linePrimitive(43, CGPoint(x: 700, y: 100), CGPoint(x: 706, y: 100)))
        primitives.append(linePrimitive(44, CGPoint(x: 703, y: 104), CGPoint(x: 705, y: 106)))
        // A lone stroke: a cluster of one primitive.
        primitives.append(linePrimitive(51, CGPoint(x: 900, y: 100), CGPoint(x: 907, y: 100)))
        // The door at 8× — outside the default 0.25…4 scale band.
        primitives += door(firstID: 61) { CGPoint(x: 8 * $0.x + 400, y: 8 * $0.y + 600) }
        return primitives
    }

    /// Exemplar built from the instance at (100, 100): bounds (100…106, 100…108),
    /// padded by 1 on every side.
    static func standardExemplar(in primitives: [VectorPrimitive]) throws -> SymbolExemplar {
        try SymbolExemplar(
            primitives: primitives,
            region: VectorBounds(minX: 99, minY: 99, maxX: 107, maxY: 109)
        )
    }

    // MARK: - The four true instances

    @Test("A finite primitive placed at 1e300 does not trap the clusterer (CR-41)")
    func astronomicallyPlacedPrimitiveDoesNotTrap() throws {
        // `isUsable` admits any finite coordinate. A short stroke at x = 1e300 has an extent
        // of 8, so the cell size stays small and `Int(1e300 / cellSize)` overflowed — a
        // trap on the old code, not a report.
        var primitives = Self.standardScene()
        primitives.append(Self.linePrimitive(99, CGPoint(x: 1e300, y: 100), CGPoint(x: 1e300, y: 108)))
        let exemplar = try Self.standardExemplar(in: primitives)

        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        // The four true instances are unaffected; the far stroke is its own one-member
        // candidate and is rejected, not matched.
        #expect(report.confirmed.count == 4)
        #expect(report.candidateCount == 8)
        #expect(!report.confirmed.contains { $0.primitiveIDs.contains(99) })
    }

    @Test("Rotated, mirrored and 2×-scaled copies are confirmed; the exemplar carries the identity transform")
    func fourInstancesConfirmed() throws {
        let primitives = Self.standardScene()
        let exemplar = try Self.standardExemplar(in: primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        #expect(report.confirmed.count == 4)
        #expect(report.candidateCount == 7)
        #expect(report.wasTruncated == false)

        func confirmed(startingAt id: UInt64) throws -> SymbolInstance {
            try #require(report.confirmed.first { $0.primitiveIDs.first == id })
        }

        // The exemplar itself: identity, unmirrored, scale 1, in the confirmed list.
        let own = try confirmed(startingAt: 1)
        #expect(own.isExemplar)
        #expect(own.transform == .identity)
        #expect(own.isMirrored == false)
        #expect(own.scaleFactor == 1)
        #expect(own.residual == 0)

        // Rotated 90° CCW: a rotation, not a mirror. The transform must send the
        // exemplar's hinge — page (100, 100), local (0, 0) — to the rotated instance's
        // hinge at page (300, 100), and the threshold's far end — page (106, 100),
        // local (6, 0) — to (−0 + 300, 6 + 100) = (300, 106).
        let rotated = try confirmed(startingAt: 11)
        #expect(rotated.isMirrored == false)
        #expect(abs(rotated.scaleFactor - 1) < 0.01)
        #expect(rotated.residual <= report.residualThreshold)
        let rotatedHinge = rotated.transform.apply(CGPoint(x: 100, y: 100))
        #expect(abs(rotatedHinge.x - 300) < 0.1 && abs(rotatedHinge.y - 100) < 0.1)
        let rotatedFarEnd = rotated.transform.apply(CGPoint(x: 106, y: 100))
        #expect(abs(rotatedFarEnd.x - 300) < 0.1 && abs(rotatedFarEnd.y - 106) < 0.1)

        // Mirrored: x was negated, so the *threshold* stroke — local (0,0)–(6,0) — is
        // the inverted line: it runs (500,100)–(494,100) on the page. The transform
        // must be a reflection (mirrored flag) and send the threshold's far end
        // (106, 100) to (494, 100).
        let mirrored = try confirmed(startingAt: 21)
        #expect(mirrored.isMirrored == true)
        #expect(abs(mirrored.scaleFactor - 1) < 0.01)
        #expect(mirrored.transform.determinant < 0)
        let mirroredFarEnd = mirrored.transform.apply(CGPoint(x: 106, y: 100))
        #expect(abs(mirroredFarEnd.x - 494) < 0.1 && abs(mirroredFarEnd.y - 100) < 0.1)

        // Non-vacuity for the mirror flag: the rotated and scaled instances must NOT be
        // flagged mirrored — a flag that is always on proves nothing.
        let scaled = try confirmed(startingAt: 31)
        #expect(scaled.isMirrored == false)

        // Scaled 2×: hinge (100, 100) → (100, 300); threshold far end (106, 100) →
        // (2·6 + 100, 300) = (112, 300); scale factor 2.
        #expect(abs(scaled.scaleFactor - 2) < 0.02)
        let scaledHinge = scaled.transform.apply(CGPoint(x: 100, y: 100))
        #expect(abs(scaledHinge.x - 100) < 0.1 && abs(scaledHinge.y - 300) < 0.1)
        let scaledFarEnd = scaled.transform.apply(CGPoint(x: 106, y: 100))
        #expect(abs(scaledFarEnd.x - 112) < 0.1 && abs(scaledFarEnd.y - 300) < 0.1)
    }

    // MARK: - The honest half: rejections

    @Test("The Z decoy, the lone stroke and the 8× copy are each rejected with the right typed reason")
    func rejectionsAreTypedAndComplete() throws {
        let primitives = Self.standardScene()
        let exemplar = try Self.standardExemplar(in: primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        #expect(report.rejected.count == 3)

        func rejection(startingAt id: UInt64) throws -> SymbolRejection {
            try #require(report.rejected.first { $0.primitiveIDs.first == id })
        }

        // The Z decoy: similar bounding box, different shape — the alignment must fail
        // on residual, and the rejection must carry both the residual and the bar.
        let decoy = try rejection(startingAt: 41)
        guard case let .residualTooHigh(residual, threshold) = decoy.reason else {
            Issue.record("expected residualTooHigh, got \(decoy.reason)")
            return
        }
        #expect(residual > threshold)
        #expect(threshold == report.residualThreshold)

        // The lone stroke: one primitive against a four-stroke exemplar.
        let lone = try rejection(startingAt: 51)
        #expect(lone.reason == .tooFewPrimitives(found: 1, required: 2))

        // The 8× copy: a real door shape, but outside the declared scale band — the
        // reason must state the scale that was measured.
        let giant = try rejection(startingAt: 61)
        guard case let .scaleOutsideBand(scale, band) = giant.reason else {
            Issue.record("expected scaleOutsideBand, got \(giant.reason)")
            return
        }
        #expect(abs(scale - 8) < 0.01)
        #expect(band == 0.25...4.0)
    }

    @Test("A candidate crossing the searched region's edge is rejected as partial overlap, never half-judged")
    func partialOverlapAtRegionEdge() throws {
        var primitives = Self.door(firstID: 1, Self.translation(100, 100))
        primitives += Self.door(firstID: 11, Self.translation(300, 100))
        let exemplar = try Self.standardExemplar(in: primitives)

        // The region ends at x = 304, cutting through the second instance: its leaf
        // (300,100)–(300,108) is inside, its threshold (300,100)–(306,100) and chord
        // (300,108)–(305,103) cross the edge, and its stub at x = 306 is outside
        // entirely. The matcher must refuse to judge the partial shape.
        let region = VectorBounds(minX: 99, minY: 99, maxX: 304, maxY: 120)
        let report = try SymbolMatcher().matches(
            exemplar: exemplar, in: primitives, region: region
        )

        #expect(report.confirmed.count == 1)
        #expect(report.confirmed.first?.isExemplar == true)
        let rejection = try #require(report.rejected.first)
        #expect(rejection.reason == .partialOverlap)
        #expect(rejection.primitiveIDs == [11, 12, 13])
        #expect(report.searchedRegion == region)
    }

    // MARK: - Truncation is declared, never silent

    @Test("Hitting the verification cap sets wasTruncated; the same scene under the default cap does not")
    func truncationIsDeclared() throws {
        let primitives = Self.standardScene()
        let exemplar = try Self.standardExemplar(in: primitives)

        // Cap of one alignment: the exemplar's own cluster is confirmed without
        // alignment, the rotated instance uses the single slot, and the search must
        // then stop and say so rather than quietly listing what it happened to reach.
        var options = SymbolMatchOptions.standard
        options.maximumVerifications = 1
        let truncated = try SymbolMatcher().matches(
            exemplar: exemplar, in: primitives, options: options
        )
        #expect(truncated.wasTruncated == true)
        #expect(truncated.confirmed.count == 2)
        // Candidates the search never reached are not painted as rejections.
        #expect(truncated.rejected.isEmpty)

        // Non-vacuity: the identical scene under the default cap completes — the flag
        // above was raised by the cap, not by the scene.
        let complete = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        #expect(complete.wasTruncated == false)
    }

    // MARK: - Determinism

    @Test("The same input produces the same report, twice")
    func deterministicReports() throws {
        let primitives = Self.standardScene()
        let exemplar = try Self.standardExemplar(in: primitives)
        let first = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        let second = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        #expect(first == second)
    }

    // MARK: - Exemplar construction refuses bad input

    @Test("An empty region, and a region holding one stroke, are typed errors")
    func exemplarConstructionErrors() {
        let primitives = Self.standardScene()

        #expect(throws: SymbolExemplarError.noPrimitivesInRegion) {
            try SymbolExemplar(
                primitives: primitives,
                region: VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1)
            )
        }

        // A region around the lone stroke at (900, 100): one primitive is not a symbol.
        #expect(throws: SymbolExemplarError.tooFewPrimitives(found: 1, required: 2)) {
            try SymbolExemplar(
                primitives: primitives,
                region: VectorBounds(minX: 899, minY: 99, maxX: 908, maxY: 101)
            )
        }
    }

    @Test("A nonsense option is refused by name before any work happens")
    func invalidOptionsAreRefused() throws {
        let primitives = Self.standardScene()
        let exemplar = try Self.standardExemplar(in: primitives)
        var options = SymbolMatchOptions.standard
        options.residualThreshold = 0
        #expect(throws: VectorExtractionError.self) {
            try SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: options)
        }
    }

    // MARK: - LT-15: a real construction plan, in miniature

    /// A column symbol: a 16 × 16 rectangle drawn as four edges, with a diagonal cross
    /// fill — the shape that failed to match on a live floor plan (LT-15, 2026-08-29),
    /// where every column sits **on** a grid-line intersection.
    static func columnSymbol(firstID: UInt64, cx: Double, cy: Double) -> [VectorPrimitive] {
        let h = 8.0
        let strokes: [(CGPoint, CGPoint)] = [
            (CGPoint(x: cx - h, y: cy - h), CGPoint(x: cx + h, y: cy - h)),
            (CGPoint(x: cx + h, y: cy - h), CGPoint(x: cx + h, y: cy + h)),
            (CGPoint(x: cx + h, y: cy + h), CGPoint(x: cx - h, y: cy + h)),
            (CGPoint(x: cx - h, y: cy + h), CGPoint(x: cx - h, y: cy - h)),
            (CGPoint(x: cx - h, y: cy - h), CGPoint(x: cx + h, y: cy + h)),
            (CGPoint(x: cx - h, y: cy + h), CGPoint(x: cx + h, y: cy - h))
        ]
        return strokes.enumerated().map { index, stroke in
            linePrimitive(firstID + UInt64(index), stroke.0, stroke.1)
        }
    }

    /// The distractor: the same 16 × 16 rectangle **without** the cross fill. It shares
    /// every corner with the column symbol and must still be rejected — this is the
    /// precision guard that stops contamination tolerance from buying recall blindly.
    static func plainRectangle(firstID: UInt64, cx: Double, cy: Double) -> [VectorPrimitive] {
        let h = 8.0
        let strokes: [(CGPoint, CGPoint)] = [
            (CGPoint(x: cx - h, y: cy - h), CGPoint(x: cx + h, y: cy - h)),
            (CGPoint(x: cx + h, y: cy - h), CGPoint(x: cx + h, y: cy + h)),
            (CGPoint(x: cx + h, y: cy + h), CGPoint(x: cx - h, y: cy + h)),
            (CGPoint(x: cx - h, y: cy + h), CGPoint(x: cx - h, y: cy - h))
        ]
        return strokes.enumerated().map { index, stroke in
            linePrimitive(firstID + UInt64(index), stroke.0, stroke.1)
        }
    }

    /// The plan: a 1000 × 800 sheet with a full structural grid, six identical column
    /// symbols on grid intersections — every instance crossed by **different** grid
    /// lines — two plain-rectangle distractors also on intersections, a long slanted
    /// leader through one column, and a dimension string with tick marks.
    ///
    /// Every grid line physically crosses other grid lines and passes through the
    /// symbols sitting on it, which is what real drawings do — nothing on this sheet is
    /// an isolated island.
    static func planScene() -> [VectorPrimitive] {
        var primitives: [VectorPrimitive] = []
        // Six columns on grid intersections.
        primitives += columnSymbol(firstID: 1, cx: 100, cy: 100)   // the exemplar
        primitives += columnSymbol(firstID: 11, cx: 300, cy: 100)
        primitives += columnSymbol(firstID: 21, cx: 500, cy: 400)
        primitives += columnSymbol(firstID: 31, cx: 700, cy: 400)
        primitives += columnSymbol(firstID: 41, cx: 300, cy: 700)
        primitives += columnSymbol(firstID: 51, cx: 900, cy: 700)
        // Two distractor rectangles, also on intersections, crossed by grid lines.
        primitives += plainRectangle(firstID: 61, cx: 500, cy: 100)
        primitives += plainRectangle(firstID: 71, cx: 700, cy: 700)
        // The structural grid: five verticals, three horizontals, page-spanning.
        for (offset, x) in [100.0, 300, 500, 700, 900].enumerated() {
            primitives.append(linePrimitive(
                101 + UInt64(offset), CGPoint(x: x, y: 0), CGPoint(x: x, y: 800)
            ))
        }
        for (offset, y) in [100.0, 400, 700].enumerated() {
            primitives.append(linePrimitive(
                111 + UInt64(offset), CGPoint(x: 0, y: y), CGPoint(x: 1000, y: y)
            ))
        }
        // A slanted leader line straight through the column at (500, 400) — long, but
        // much shorter than a grid line.
        primitives.append(linePrimitive(121, CGPoint(x: 400, y: 300), CGPoint(x: 620, y: 520)))
        // A dimension string near the bottom edge, with three tick marks across it.
        primitives.append(linePrimitive(131, CGPoint(x: 50, y: 760), CGPoint(x: 950, y: 760)))
        for (offset, x) in [200.0, 500, 800].enumerated() {
            primitives.append(linePrimitive(
                132 + UInt64(offset), CGPoint(x: x - 2, y: 757), CGPoint(x: x + 2, y: 763)
            ))
        }
        return primitives
    }

    /// The exemplar exactly as the estimator makes it live: a tight box around the
    /// column at (100, 100). The two grid lines passing through the box are not
    /// contained by it, so the members are the six column strokes.
    static func planExemplar(in primitives: [VectorPrimitive]) throws -> SymbolExemplar {
        try SymbolExemplar(
            primitives: primitives,
            region: VectorBounds(minX: 90, minY: 90, maxX: 110, maxY: 110)
        )
    }

    /// LT-15's live failure, reproduced and fixed. Pre-fix (run on the unchanged
    /// matcher, 2026-08-29, before the context filter existed) this scene produced
    /// exactly the live symptom:
    ///
    ///     Expectation failed: (report.confirmed.count → 0) == 6
    ///     Expectation failed: (report.candidateCount → 1) == 11
    ///     Expectation failed: report.confirmed.first { $0.isExemplar } → nil
    ///
    /// because every primitive on the sheet is connected to every other through the
    /// grid, so clustering produced one page-sized candidate, rejected on scale, and
    /// not even the exemplar's own instance was confirmed. The test below keeps that
    /// first-pass collapse reproducible through ``SymbolMatchOptions/contextExtentFactor``;
    /// since L-72 the second look inside the collapsed candidate recovers the columns.
    @Test("On a gridded plan, all six columns are found — the exemplar's own instance included — and the plain rectangles are not")
    func columnsOnAGriddedPlanAreFound() throws {
        let primitives = Self.planScene()
        let exemplar = try Self.planExemplar(in: primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // All six columns, nothing else. 6 columns + 2 rectangles + 3 ticks = 11
        // candidates once the page-spanning context lines are set aside.
        #expect(report.confirmed.count == 6)
        #expect(report.candidateCount == 11)
        #expect(report.wasTruncated == false)

        // The exemplar's own instance is confirmed at its own centre.
        let own = try #require(report.confirmed.first { $0.isExemplar })
        #expect(abs(own.position.x - 100) < 1 && abs(own.position.y - 100) < 1)

        // Every confirmed position is a grid intersection that holds a column.
        let expectedCenters = [
            CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 500, y: 400),
            CGPoint(x: 700, y: 400), CGPoint(x: 300, y: 700), CGPoint(x: 900, y: 700)
        ]
        for center in expectedCenters {
            #expect(report.confirmed.contains {
                abs($0.position.x - center.x) < 2 && abs($0.position.y - center.y) < 2
            }, "no confirmed instance at (\(center.x), \(center.y))")
        }

        // The distractor rectangles are rejected on residual — they share all four
        // corners with the column symbol, so only the cross fill separates them.
        for firstID: UInt64 in [61, 71] {
            let rejection = try #require(
                report.rejected.first { $0.primitiveIDs.first == firstID },
                "distractor \(firstID) missing from the rejected list"
            )
            guard case .residualTooHigh = rejection.reason else {
                Issue.record("distractor \(firstID): expected residualTooHigh, got \(rejection.reason)")
                return
            }
        }

        // The three lone tick marks are rejected for being too few strokes.
        let tooFew = report.rejected.filter {
            if case .tooFewPrimitives = $0.reason { return true }
            return false
        }
        #expect(tooFew.count == 3)
    }

    // MARK: - LT-15: contamination that survives inside the cluster

    /// The same column with short dash strokes through it — a dashed grid line's dashes,
    /// too short to be filtered as page context, clustered into the candidate itself.
    /// The exemplar's own crop catches one dash; every other instance carries
    /// **different** dashes. The distractor rectangle carries a dash of its own and must
    /// still be rejected.
    static func dashedScene() -> [VectorPrimitive] {
        var primitives: [VectorPrimitive] = []
        // The exemplar's instance, with one horizontal dash through its middle.
        primitives += columnSymbol(firstID: 1, cx: 100, cy: 100)
        primitives.append(linePrimitive(7, CGPoint(x: 94, y: 96), CGPoint(x: 106, y: 96)))
        // A second instance with two different dashes.
        primitives += columnSymbol(firstID: 11, cx: 300, cy: 100)
        primitives.append(linePrimitive(17, CGPoint(x: 292, y: 103), CGPoint(x: 308, y: 103)))
        primitives.append(linePrimitive(18, CGPoint(x: 297, y: 92), CGPoint(x: 297, y: 110)))
        // A third instance with one slanted dash.
        primitives += columnSymbol(firstID: 21, cx: 500, cy: 400)
        primitives.append(linePrimitive(27, CGPoint(x: 492, y: 394), CGPoint(x: 509, y: 401)))
        // The distractor: a plain rectangle with its own dash.
        primitives += plainRectangle(firstID: 31, cx: 700, cy: 100)
        primitives.append(linePrimitive(35, CGPoint(x: 692, y: 98), CGPoint(x: 708, y: 98)))
        return primitives
    }

    @Test("An exemplar cropped with a contaminating dash still matches instances carrying different dashes; the dashed rectangle is still rejected")
    func contaminatedExemplarMatchesDifferentlyContaminatedInstances() throws {
        let primitives = Self.dashedScene()
        // The crop contains the column *and* the dash — seven members, the live
        // condition: the estimator cannot draw a box that excludes a through-stroke.
        let exemplar = try SymbolExemplar(
            primitives: primitives,
            region: VectorBounds(minX: 90, minY: 90, maxX: 110, maxY: 110)
        )
        #expect(exemplar.primitiveIDs == [1, 2, 3, 4, 5, 6, 7])

        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // All three true instances, each contaminated differently, are confirmed.
        #expect(report.confirmed.count == 3)
        #expect(report.candidateCount == 4)
        for center in [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 500, y: 400)] {
            #expect(report.confirmed.contains {
                abs($0.position.x - center.x) < 3 && abs($0.position.y - center.y) < 3
            }, "no confirmed instance at (\(center.x), \(center.y))")
        }

        // The dashed rectangle is not a column, dash or no dash.
        let rejection = try #require(report.rejected.first { $0.primitiveIDs.first == 31 })
        guard case .residualTooHigh = rejection.reason else {
            Issue.record("expected residualTooHigh for the dashed rectangle, got \(rejection.reason)")
            return
        }
    }

    // MARK: - Non-vacuity: the old behaviour still fails these scenes

    @Test("Without the context filter, the gridded plan still collapses into one page-sized candidate, and the second look inside it finds the six columns (L-72)")
    func withoutContextFilterTheGridWeldsThePage() throws {
        let primitives = Self.planScene()
        let exemplar = try Self.planExemplar(in: primitives)
        var options = SymbolMatchOptions.standard
        options.contextExtentFactor = .infinity

        let report = try SymbolMatcher().matches(
            exemplar: exemplar, in: primitives, options: options
        )

        // Every primitive on the sheet is connected to every other through the grid: the
        // first pass still forms one candidate, the whole sheet, out of the scale band —
        // the pre-fix failure of LT-15, kept reproducible.
        #expect(report.candidateCount == 1)
        // Old output (before L-72): confirmed = [], the exemplar's own instance included.
        // The second look clusters the sheet again one octave at a time, where no grid line
        // is short enough to take part, and judges what it finds: the six columns, and not
        // the two plain rectangles.
        #expect(report.confirmed.count == 6)
        #expect(report.confirmed.contains { $0.isExemplar })
        for center in [
            CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 500, y: 400),
            CGPoint(x: 700, y: 400), CGPoint(x: 300, y: 700), CGPoint(x: 900, y: 700)
        ] {
            #expect(report.confirmed.contains {
                abs($0.position.x - center.x) < 2 && abs($0.position.y - center.y) < 2
            }, "no confirmed instance at (\(center.x), \(center.y))")
        }
        // What nothing confirmed stays the sheet's one rejection, measured as before.
        #expect(report.rejected.count == 1)
        let rejection = try #require(report.rejected.first)
        guard case let .scaleOutsideBand(scale, band) = rejection.reason else {
            Issue.record("expected scaleOutsideBand for the welded sheet, got \(rejection.reason)")
            return
        }
        #expect(scale > band.upperBound)
        #expect(Set(rejection.primitiveIDs).isDisjoint(with: report.confirmed.flatMap(\.primitiveIDs)))
        #expect([61, 71].allSatisfy { Set(rejection.primitiveIDs).contains($0) }, "the plain rectangles stay unconfirmed")
    }

    @Test("With zero contamination tolerance, differently-dashed instances are rejected on residual — the tolerance is what buys them, and the exemplar's own cluster is all that survives")
    func withoutContaminationToleranceDashedInstancesFail() throws {
        let primitives = Self.dashedScene()
        let exemplar = try SymbolExemplar(
            primitives: primitives,
            region: VectorBounds(minX: 90, minY: 90, maxX: 110, maxY: 110)
        )
        var options = SymbolMatchOptions.standard
        options.exemplarContaminationTolerance = 0
        options.candidateContaminationTolerance = 0

        let report = try SymbolMatcher().matches(
            exemplar: exemplar, in: primitives, options: options
        )

        // Only the exemplar's own cluster — confirmed by identity, not by alignment —
        // survives. Both true instances fail on residual: their dashes sit elsewhere.
        #expect(report.confirmed.count == 1)
        #expect(report.confirmed.first?.isExemplar == true)
        for firstID: UInt64 in [11, 21] {
            let rejection = try #require(
                report.rejected.first { $0.primitiveIDs.first == firstID },
                "instance \(firstID) should be rejected without contamination tolerance"
            )
            guard case .residualTooHigh = rejection.reason else {
                Issue.record("instance \(firstID): expected residualTooHigh, got \(rejection.reason)")
                return
            }
        }
    }

    @Test("The new options are validated by name")
    func newOptionsAreValidated() throws {
        let primitives = Self.planScene()
        let exemplar = try Self.planExemplar(in: primitives)

        var belowOne = SymbolMatchOptions.standard
        belowOne.contextExtentFactor = 0.5
        #expect(throws: VectorExtractionError.self) {
            try SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: belowOne)
        }

        var wholeShapeContamination = SymbolMatchOptions.standard
        wholeShapeContamination.exemplarContaminationTolerance = 1
        #expect(throws: VectorExtractionError.self) {
            try SymbolMatcher().matches(
                exemplar: exemplar, in: primitives, options: wholeShapeContamination
            )
        }

        var infiniteCandidateShare = SymbolMatchOptions.standard
        infiniteCandidateShare.candidateContaminationTolerance = .infinity
        #expect(throws: VectorExtractionError.self) {
            try SymbolMatcher().matches(
                exemplar: exemplar, in: primitives, options: infiniteCandidateShare
            )
        }
    }
}
