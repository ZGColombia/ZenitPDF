import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Bug hunt 2 on the symbol matcher: identity by ids alone (BH-332), a decoy excused its
/// one distinguishing stroke (BH-333), a welded second instance counted as one (BH-334),
/// a marker pulled onto a wall stub (BH-335), backward residuals in the wrong unit
/// (BH-869), a ratio that trapped (BH-870), the exemplar lost to the verification cap
/// (BH-871) and a reported scale outside the closed band (BH-872).
///
/// Every expected number is derived by hand beside it, from the door of
/// `SymbolMatchTests` (feature-point centroid (2.875, 2.5625), RMS radius 3.869) and the
/// 16 × 16 column of the same file.
struct SymbolMatchPrecisionTests {
    typealias T = SymbolMatchTests

    // MARK: - BH-332

    @Test("Another page's primitives under the exemplar's ids are judged on geometry, not confirmed by definition (BH-332)")
    func exemplarIdentityNeedsMatchingGeometry() throws {
        // Page A: the exemplar door at (100, 100), ids 1–4.
        let pageA = T.door(firstID: 1, T.translation(100, 100))
        let exemplar = try T.standardExemplar(in: pageA)

        // Page B: ids 1–4 are a Z decoy at (700, 100); ids 11–14 a true door at (300, 100).
        var pageB: [VectorPrimitive] = []
        pageB.append(T.linePrimitive(1, CGPoint(x: 700, y: 108), CGPoint(x: 706, y: 108)))
        pageB.append(T.linePrimitive(2, CGPoint(x: 706, y: 108), CGPoint(x: 700, y: 100)))
        pageB.append(T.linePrimitive(3, CGPoint(x: 700, y: 100), CGPoint(x: 706, y: 100)))
        pageB.append(T.linePrimitive(4, CGPoint(x: 703, y: 104), CGPoint(x: 705, y: 106)))
        pageB += T.door(firstID: 11, T.translation(300, 100))
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: pageB)

        // Old output: ids 1–4 confirmed with the identity transform, residual 0,
        // isExemplar true and position (102.875, 102.5625) — page A's coordinates — plus
        // the door at (300, 100): 2 confirmed. Now the Z is rejected on residual and
        // nothing on page B is the exemplar.
        #expect(report.confirmed.count == 1)
        #expect(!report.confirmed.contains { $0.isExemplar })
        let door = try #require(report.confirmed.first)
        #expect(door.primitiveIDs == [11, 12, 13, 14])
        #expect(abs(door.position.x - 302.875) < 0.05 && abs(door.position.y - 102.5625) < 0.05)
        let decoy = try #require(report.rejected.first { $0.primitiveIDs == [1, 2, 3, 4] })
        guard case .residualTooHigh = decoy.reason else {
            Issue.record("expected residualTooHigh for the Z under the exemplar's ids, got \(decoy.reason)")
            return
        }

        // A true door under the exemplar's ids elsewhere on page B is confirmed by
        // alignment: translation (400, 0), not the identity, and not the exemplar.
        let pageC = T.door(firstID: 1, T.translation(500, 100))
        let moved = try SymbolMatcher().matches(exemplar: exemplar, in: pageC)
        let instance = try #require(moved.confirmed.first)
        #expect(!instance.isExemplar)
        #expect(instance.transform != .identity)
        #expect(abs(instance.position.x - 502.875) < 0.05 && abs(instance.position.y - 102.5625) < 0.05)
    }

    // MARK: - BH-333

    /// A 16 × 16 rectangle with **one** diagonal: five strokes, every endpoint a corner.
    static func crossedOnce(firstID: UInt64, cx: Double, cy: Double) -> [VectorPrimitive] {
        T.plainRectangle(firstID: firstID, cx: cx, cy: cy)
            + [T.linePrimitive(firstID + 4, CGPoint(x: cx - 8, y: cy - 8), CGPoint(x: cx + 8, y: cy + 8))]
    }

    @Test("A five-stroke symbol does not confirm its four-stroke decoy: a corner-to-corner stroke is never written off (BH-333)")
    func singleDiagonalIsNotExcused() throws {
        var primitives = Self.crossedOnce(firstID: 1, cx: 100, cy: 100)       // the exemplar
        primitives += T.plainRectangle(firstID: 11, cx: 300, cy: 100)          // the decoy
        primitives += Self.crossedOnce(firstID: 21, cx: 500, cy: 100)          // a true instance
        let exemplar = try SymbolExemplar(
            primitives: primitives, region: VectorBounds(minX: 90, minY: 90, maxX: 110, maxY: 110)
        )
        #expect(exemplar.primitiveIDs == [1, 2, 3, 4, 5])
        // Every stroke ends on a corner shared with another stroke, so none is droppable.
        #expect(SymbolMatcher.droppableStrokes(of: exemplar) == [false, false, false, false, false])

        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // Old output: 3 confirmed — exemplarDropCount = Int(5 × 0.2) = 1 wrote the
        // diagonal off and the plain rectangle passed with residual 0.
        #expect(report.confirmed.count == 2)
        #expect(report.confirmed.contains { $0.isExemplar })
        #expect(report.confirmed.contains { $0.primitiveIDs == [21, 22, 23, 24, 25] })
        let decoy = try #require(report.rejected.first { $0.primitiveIDs == [11, 12, 13, 14] })
        guard case let .residualTooHigh(residual, threshold) = decoy.reason else {
            Issue.record("expected residualTooHigh for the plain rectangle, got \(decoy.reason)")
            return
        }
        // The diagonal's ⅓ and ⅔ samples sit (−2.667, −2.667) and (2.667, 2.667) from the
        // centre; the nearest rectangle feature point to each is an edge sample 5.333
        // away, so the stroke's RMS over its four points is 5.333/√2 = 3.771 pt, or
        // 3.771 / 8.219 = 0.459 of the rectangle's RMS radius (Σr² over its 16 points =
        // 4 × 128 + 8 × 71.11 = 1080.9, /16 = 67.56, √ = 8.219). Far above 0.08.
        #expect(residual > 0.35 && residual < 0.6)
        #expect(threshold == 0.08)

        // Non-vacuity: a free-ended dash caught in the crop is still droppable, and the
        // dashed scene of the base suite still finds its three columns.
        let dashed = T.dashedScene()
        let dashedExemplar = try SymbolExemplar(
            primitives: dashed, region: VectorBounds(minX: 90, minY: 90, maxX: 110, maxY: 110)
        )
        #expect(SymbolMatcher.droppableStrokes(of: dashedExemplar) == [false, false, false, false, false, false, true])
        #expect(try SymbolMatcher().matches(exemplar: dashedExemplar, in: dashed).confirmed.count == 3)
    }

    // MARK: - BH-334, BH-335

    @Test("A contaminating stub does not move the marker: the position is the exemplar's centroid under the transform (BH-335)")
    func positionFollowsTheTransform() throws {
        var primitives = T.door(firstID: 1, T.translation(100, 100))
        primitives += T.door(firstID: 11, T.translation(300, 100))
        // A wall stub 0.5 pt past the door's own stub (x = 306, y 100…101.5): inside the
        // 0.75 pt link tolerance, 5.5 pt long — far under the member extent limit — so
        // it is clustered and never pruned.
        primitives.append(T.linePrimitive(19, CGPoint(x: 306.5, y: 100.5), CGPoint(x: 312, y: 100.5)))
        let exemplar = try T.standardExemplar(in: primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        let instance = try #require(report.confirmed.first { $0.primitiveIDs.first == 11 })
        #expect(instance.primitiveIDs == [11, 12, 13, 14, 19])
        // The door's own centroid is (2.875, 2.5625) + (300, 100) = (302.875, 102.5625).
        // Old output: the centroid of all 20 feature points, x = (16 × 302.875 + 306.5
        // + 308.333 + 310.167 + 312) / 20 = 304.15, y = (16 × 102.5625 + 4 × 100.5) / 20
        // = 102.15 — 1.3 pt off the door, towards the wall.
        #expect(abs(instance.position.x - 302.875) < 0.05)
        #expect(abs(instance.position.y - 102.5625) < 0.05)
        #expect(instance.position == instance.transform.apply(exemplar.centroid))
    }

    @Test("Two touching instances welded into one cluster are counted as two (BH-334)")
    func weldedSecondInstanceIsCounted() throws {
        var primitives = T.door(firstID: 1, T.translation(100, 100))
        // Door A at (300, 100), and door B at half size touching A's stub: B's leaf at
        // x = 306.5 is 0.5 pt from A's stub at x = 306, inside the link tolerance, so
        // clustering welds the eight strokes into one candidate.
        primitives += T.door(firstID: 11, T.translation(300, 100))
        primitives += T.door(firstID: 21) { CGPoint(x: 0.5 * $0.x + 306.5, y: 0.5 * $0.y + 100) }
        let exemplar = try T.standardExemplar(in: primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // Old output: 2 confirmed — the exemplar and the welded cluster as one
        // instance, B's four strokes written off as candidate contamination
        // (Int(8 × 0.5) = 4 allowed) and never looked at again.
        #expect(report.candidateCount == 2)
        #expect(report.confirmed.count == 3)
        let a = try #require(report.confirmed.first { $0.primitiveIDs.first == 11 })
        #expect(a.primitiveIDs == [11, 12, 13, 14, 21, 22, 23, 24])
        #expect(abs(a.scaleFactor - 1) < 0.02)
        #expect(abs(a.position.x - 302.875) < 0.1 && abs(a.position.y - 102.5625) < 0.1)
        // B: scale ½, centroid 0.5 × (2.875, 2.5625) + (306.5, 100) = (307.9375, 101.28125).
        let b = try #require(report.confirmed.first { $0.primitiveIDs.first == 21 })
        #expect(b.primitiveIDs == [21, 22, 23, 24])
        #expect(abs(b.scaleFactor - 0.5) < 0.02)
        #expect(abs(b.position.x - 307.9375) < 0.1 && abs(b.position.y - 101.28125) < 0.1)
    }

    // MARK: - BH-869

    @Test("The backward residual is reported in candidate units, scaled by the alignment (BH-869)")
    func backwardResidualIsInCandidateUnits() {
        // One exemplar stroke along the x-axis; the candidate is the same stroke at
        // twice the scale plus a second stroke displaced by 0.1 in candidate units. The
        // alignment is the pure scale 2. Forward: exemplar points land exactly on the
        // first candidate stroke → 0. Backward: the second stroke maps by ½ to y = 0.05
        // in exemplar units. Old output: max(0, 0.05) = 0.05 — under an 0.08 bar. In
        // candidate units the same displacement is 0.1 — over it.
        let exemplarPoints = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 3, y: 0)]
        let candidatePoints = [
            CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 6, y: 0),
            CGPoint(x: 0, y: 0.1), CGPoint(x: 2, y: 0.1), CGPoint(x: 4, y: 0.1), CGPoint(x: 6, y: 0.1)
        ]
        let alignment = SymbolAlignment.Alignment(
            r00: 1, r01: 0, r10: 0, r11: 1, scale: 2, tx: 0, ty: 0, residual: .infinity, isMirrored: false
        )
        let judgement = SymbolAlignment.judge(
            exemplarPoints: exemplarPoints, exemplarCounts: [4], exemplarDroppable: nil,
            candidatePoints: candidatePoints, candidateCounts: [4, 4],
            alignment: alignment, exemplarDropCount: 0, candidateDropCount: 0, threshold: 0.08
        )
        #expect(abs(judgement.residual - 0.1) < 1e-12)
        #expect(judgement.unmatchedCandidateStrokes == [1])

        // With one candidate drop the displaced stroke is set aside and the residual is 0.
        #expect(SymbolAlignment.judge(
            exemplarPoints: exemplarPoints, exemplarCounts: [4], exemplarDroppable: nil,
            candidatePoints: candidatePoints, candidateCounts: [4, 4],
            alignment: alignment, exemplarDropCount: 0, candidateDropCount: 1, threshold: 0.08
        ).residual == 0)
    }

    // MARK: - BH-870

    @Test("A primitive-count ratio whose product overflows Int is refused by name, not trapped (BH-870)")
    func overflowingRatioIsRefused() throws {
        let primitives = T.standardScene()
        let exemplar = try T.standardExemplar(in: primitives)
        var options = SymbolMatchOptions.standard
        options.minimumPrimitiveCountRatio = 1e30
        // Old behaviour: `Int((4 × 1e30).rounded(.up))` trapped the process — not
        // reproducible in a test, which is the point.
        do {
            _ = try SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: options)
            Issue.record("a ratio of 1e30 was accepted")
        } catch VectorExtractionError.invalidOption(let name, _) {
            #expect(name == "minimumPrimitiveCountRatio")
        }
    }

    // MARK: - BH-871

    @Test("The verification cap never drops the exemplar's own instance, wherever its ids sort (BH-871)")
    func capKeepsTheExemplar() throws {
        // Two doors with low ids, the clicked one with the highest.
        var primitives = T.door(firstID: 1, T.translation(100, 100))
        primitives += T.door(firstID: 11, T.translation(300, 100))
        primitives += T.door(firstID: 91, T.translation(900, 100))
        let exemplar = try SymbolExemplar(
            primitives: primitives, region: VectorBounds(minX: 899, minY: 99, maxX: 907, maxY: 109)
        )
        #expect(exemplar.primitiveIDs == [91, 92, 93, 94])
        var options = SymbolMatchOptions.standard
        options.maximumVerifications = 1
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: options)

        // Old output: 1 confirmed (ids 1–4, the one alignment), no isExemplar instance —
        // the loop broke at ids 11–14 before reaching the clicked door.
        #expect(report.wasTruncated)
        #expect(report.confirmed.count == 2)
        let own = try #require(report.confirmed.first { $0.isExemplar })
        #expect(own.primitiveIDs == [91, 92, 93, 94])
        #expect(own.transform == .identity)
        // Candidates the search never reached are still not painted as rejections.
        #expect(report.rejected.isEmpty)
    }

    // MARK: - BH-872

    /// The door at `scale` with a short tick lying inside its chord's bounding box: the
    /// tick's four feature points sit near the centroid and deflate the cluster's RMS
    /// radius, so the raw ratio is under the band while the true scale is `scale`.
    static func tickedDoor(firstID: UInt64, scale: Double) -> [VectorPrimitive] {
        var strokes = T.door(firstID: firstID) { CGPoint(x: scale * $0.x + 100, y: scale * $0.y + 300) }
        let cx = scale * 2.875 + 100
        let cy = scale * 2.5625 + 300 + 2
        strokes.append(T.linePrimitive(firstID + 4, CGPoint(x: cx - 0.2, y: cy), CGPoint(x: cx + 0.2, y: cy)))
        return strokes
    }

    @Test("The reported scale factor lies inside the closed band, or the candidate is rejected with it (BH-872)")
    func reportedScaleIsInsideTheBand() throws {
        var primitives = T.door(firstID: 1, T.translation(100, 100))
        primitives += Self.tickedDoor(firstID: 11, scale: 4.1)
        let exemplar = try T.standardExemplar(in: primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // Hand-derived: the door's Σr² about its centroid is 239.5 over 16 points (RMS
        // 3.869); at 4.1× that is 16 × 15.86² = 4024.6, and the tick adds four points
        // about 2 pt from the centroid, ≈ 16, so the cluster's RMS is √(4040.6 / 20) =
        // 14.21 and the raw ratio 14.21 / 3.869 = 3.67 — inside 0.25…4. The alignment
        // recovers the true 4.1 (Procrustes scale 4.1 × 3.869 / 14.21 = 1.116).
        //
        // Old output: confirmed with scaleFactor 4.10, outside the band the options
        // call closed. Now: rejected, and the rejection carries that scale.
        #expect(report.confirmed.count == 1)
        #expect(report.confirmed.first?.isExemplar == true)
        let rejection = try #require(report.rejected.first { $0.primitiveIDs.first == 11 })
        guard case let .scaleOutsideBand(scale, band) = rejection.reason else {
            Issue.record("expected scaleOutsideBand, got \(rejection.reason)")
            return
        }
        #expect(abs(scale - 4.1) < 0.03)
        #expect(band == 0.25...4.0)

        // Non-vacuity: the same construction at 3.9× is confirmed at 3.9.
        var inBand = T.door(firstID: 1, T.translation(100, 100))
        inBand += Self.tickedDoor(firstID: 11, scale: 3.9)
        let ok = try SymbolMatcher().matches(exemplar: try T.standardExemplar(in: inBand), in: inBand)
        let instance = try #require(ok.confirmed.first { $0.primitiveIDs.first == 11 })
        #expect(abs(instance.scaleFactor - 3.9) < 0.03)
    }
}
