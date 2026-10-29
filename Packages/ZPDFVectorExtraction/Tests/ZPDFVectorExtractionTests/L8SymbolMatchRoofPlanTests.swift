import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction
import ZPDFTestingSupport

/// L-72 (live test 8): on a real roof plan, a box round one "TH" symbol matched nothing —
/// "0 confirmed, 7 near misses", not even the boxed instance.
///
/// The symbol is two concentric rectangles drawn as eight separate lines (the "TH" inside is
/// real text). The matcher links strokes that sit within the exemplar's own stroke gap scaled to
/// the top of the scale band, and on an A1 drawing that reaches from every drawn thing to the
/// next: the whole sheet welded into one candidate, rejected on scale, and nothing else was left
/// to confirm. The live box held the inner frame only (``liveBox``). Once the second look freed
/// the outer frames, each of them passed as a second symbol at the same place, so the review
/// listed every symbol twice; the matcher now reports one instance per place.
///
/// These tests run the same searches on the Synthetic Roof Plan (`ZPDFTestingSupport`), whose
/// three symbols sit 15 pt from grid axis 1 and 25–28 pt from two distractors — inside the first
/// look's link reach (5 pt × 4 × 1.5 = 30 pt), outside the second look's (5 × 1 × 1.5 = 7.5 pt).
/// Every expected position below is derived from the symbols' drawn coordinates
/// (`SyntheticRoofPlan.symbolCentres`), never read back from the matcher.
@Suite("L-72: symbol matching on a heavy roof plan")
struct L8SymbolMatchRoofPlanTests {

    /// Page 0 as the automation store extracts it: hidden optional content included.
    static func roofPlanPrimitives() async throws -> [VectorPrimitive] {
        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let url = try ZPDFFixtures.shared(.syntheticRoofPlan).url
        return try await VectorExtractor(options: options).extract(documentAt: url, pageIndex: 0).primitives
    }

    /// The symbols' centres (`SyntheticRoofPlan.symbolCentres`), lowest first: the quarter-turned
    /// one at (1100, 640), then (1040, 990) and (1040, 1060). Each symbol is an inner 40 × 28 pt
    /// frame inside a 50 × 35 pt one, concentric, so the feature-point centroid of either frame —
    /// four evenly spaced points per line average to the line's midpoint — is the centre itself.
    static let centres = [CGPoint(x: 1100, y: 640), CGPoint(x: 1040, y: 990), CGPoint(x: 1040, y: 1060)]

    /// The primitives of a distractor the matcher works with: every line and curve inside its
    /// square (a closed shape takes part through its segments, not its subpath primitive).
    static func ids(inside box: VectorBounds, of primitives: [VectorPrimitive]) -> Set<UInt64> {
        Set(primitives.filter {
            ($0.kind == .lineSegment || $0.kind == .cubicCurve)
                && $0.bounds.minX >= box.minX && $0.bounds.maxX <= box.maxX && $0.bounds.minY >= box.minY && $0.bounds.maxY <= box.maxY
        }.map(\.id))
    }

    /// The square-in-square distractor at (1100, 710), outer square 40 pt; and the
    /// circle-in-square at (1115, 990), outer square 44 pt.
    static let squareDistractor = VectorBounds(minX: 1079, minY: 689, maxX: 1121, maxY: 731)
    static let circleDistractor = VectorBounds(minX: 1092, minY: 967, maxX: 1138, maxY: 1013)

    /// The box the estimator draws round the upper symbol: its outer frame is x 1015…1065,
    /// y 1042.5…1077.5, and the nearest other linework, axis 1 at x = 1000, is outside it.
    static let box = VectorBounds(minX: 1010, minY: 1037, maxX: 1070, maxY: 1083)

    @Test("A box round one TH symbol confirms it and its two identical copies at their centres")
    func boxedSymbolAndCopiesMatch() async throws {
        let primitives = try await Self.roofPlanPrimitives()
        let exemplar = try SymbolExemplar(primitives: primitives, region: Self.box)
        // The eight lines of the two frames, nothing else inside the box.
        #expect(exemplar.primitiveIDs.count == 8)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // Old output on the original sheet: confirmed = [], and one rejection of nearly the whole
        // sheet, scaleOutsideBand at 13.67× — everything welded into one candidate.
        let found = report.confirmed.map(\.position).sorted { $0.y < $1.y }
        #expect(found.count == 3, "\(report.confirmed.map { ($0.position, $0.primitiveIDs.count) })")
        for (position, target) in zip(found, Self.centres) {
            #expect(abs(position.x - target.x) < 0.05 && abs(position.y - target.y) < 0.05, "\(position) vs \(target)")
        }
        // The boxed copy is the example itself; the other two — one of them turned a quarter —
        // are matches at scale 1.
        let boxed = try #require(report.confirmed.first { abs($0.position.y - 1060) < 0.05 })
        #expect(boxed.isExemplar && boxed.primitiveIDs == exemplar.primitiveIDs)
        #expect(report.confirmed.filter(\.isExemplar).count == 1)
        for copy in report.confirmed where !copy.isExemplar {
            #expect(abs(copy.scaleFactor - 1) < 0.001 && copy.residual <= report.residualThreshold)
        }
        // The square-in-square frame and the frame round a circle near the copies are other
        // symbols: neither is counted, and both are reported as not found.
        try Self.expectDistractorsRejected(report, primitives)
    }

    /// Both distractors are examined and rejected, and nothing is listed both as found and as not.
    static func expectDistractorsRejected(_ report: SymbolMatchReport, _ primitives: [VectorPrimitive]) throws {
        #expect(!report.wasTruncated, "every candidate was examined")
        let confirmedIDs = Set(report.confirmed.flatMap(\.primitiveIDs))
        let rejectedIDs = Set(report.rejected.flatMap(\.primitiveIDs))
        let square = Self.ids(inside: Self.squareDistractor, of: primitives)
        let circle = Self.ids(inside: Self.circleDistractor, of: primitives)
        // 8 lines; 4 lines and the circle's four curves.
        #expect(square.count == 8 && circle.count == 8, "\(square.count) \(circle.count)")
        #expect(square.isDisjoint(with: confirmedIDs) && circle.isDisjoint(with: confirmedIDs))
        #expect(square.isSubset(of: rejectedIDs) && circle.isSubset(of: rejectedIDs))
        #expect(rejectedIDs.isDisjoint(with: confirmedIDs))
    }

    /// The box the live test drew (L-72 re-fix): round the inner frame only (x 1020…1060,
    /// y 1046…1074), the "TH" inside it. The outer frame lies outside the box, so the exemplar
    /// is the inner rectangle's four lines.
    static let liveBox = VectorBounds(minX: 1017, minY: 1044, maxX: 1063, maxY: 1076)

    @Test("The live box round one TH symbol's inner frame confirms each of the three symbols once, at scale 1")
    func liveBoxConfirmsEachSymbolOnce() async throws {
        let primitives = try await Self.roofPlanPrimitives()
        let exemplar = try SymbolExemplar(primitives: primitives, region: Self.liveBox)
        #expect(exemplar.primitiveIDs.count == 4)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)

        // Old output on the original sheet: before L-72 (no second look) — confirmed = [], the
        // review's "0 confirmed, 7 near misses"; after the first L-72 fix — 6 confirmed, the
        // three inner frames at scale 1 and the three outer frames round them as second symbols
        // at the outer-to-inner scale. Here the outer frame is the inner one scaled by exactly
        // 50 / 40 = 35 / 28 = 1.25, so it matches at 1.25 with no residual: the case the
        // one-place rule exists for, at its sharpest.
        let found = report.confirmed.sorted { $0.position.y < $1.position.y }
        #expect(found.count == 3, "\(report.confirmed.map { ($0.position, $0.scaleFactor, $0.primitiveIDs.count) })")
        for (instance, target) in zip(found, Self.centres) {
            #expect(abs(instance.position.x - target.x) < 0.05 && abs(instance.position.y - target.y) < 0.05, "\(instance.position) vs \(target)")
            #expect(abs(instance.scaleFactor - 1) < 0.001, "\(instance.scaleFactor)")
        }
        #expect(!report.confirmed.contains { abs($0.scaleFactor - 1.25) < 0.01 }, "an outer frame listed as a symbol of its own")
        // No two confirmed places a review would land as one.
        let radius = exemplar.rmsRadius * SymbolMatcher.duplicateRadiusFactor
        for (i, a) in found.enumerated() {
            for b in found[(i + 1)...] {
                #expect(hypot(a.position.x - b.position.x, a.position.y - b.position.y) > radius)
            }
        }
        // The boxed copy is the example; the outer frame that was listed as a second symbol is
        // now part of it: eight strokes, the outer frame's bounds.
        let boxed = try #require(found.last)
        #expect(boxed.isExemplar && Set(exemplar.primitiveIDs).isSubset(of: boxed.primitiveIDs))
        #expect(report.confirmed.filter(\.isExemplar).count == 1)
        for instance in found {
            #expect(instance.primitiveIDs.count == 8 && instance.primitiveIDs == instance.primitiveIDs.sorted())
        }
        #expect(abs(boxed.bounds.minX - 1015) < 0.01 && abs(boxed.bounds.maxX - 1065) < 0.01)
        #expect(abs(boxed.bounds.minY - 1042.5) < 0.01 && abs(boxed.bounds.maxY - 1077.5) < 0.01)
        // The distractors are examined and rejected (in place of the original sheet's count of
        // rejections, which described that sheet and no other).
        try Self.expectDistractorsRejected(report, primitives)
    }

    /// An instance at `position` for the one-place rule.
    static func instance(_ ids: [UInt64], _ position: CGPoint, scale: Double, residual: Double, isExemplar: Bool = false) -> SymbolInstance {
        SymbolInstance(
            primitiveIDs: ids, position: position,
            bounds: VectorBounds(minX: position.x - 10 * scale, minY: position.y - 5 * scale, maxX: position.x + 10 * scale, maxY: position.y + 5 * scale),
            transform: .identity, isMirrored: false, scaleFactor: scale, residual: residual, isExemplar: isExemplar
        )
    }

    @Test("One place, one instance: the example first, then the scale nearest 1, then the residual; strokes join, distinct places stay")
    func onePlaceOneInstance() throws {
        let radius = 5.0
        // The example at a worse scale still keeps the place; the nested frame inside it joins.
        let outer = Self.instance([1, 2], CGPoint(x: 100.4, y: 100), scale: 1.3, residual: 0.04, isExemplar: true)
        let kept = SymbolMatcher.onePerPlace([
            Self.instance([5, 6], CGPoint(x: 100, y: 100), scale: 1.0, residual: 0.01),
            outer,
            Self.instance([9], CGPoint(x: 200, y: 100), scale: 1.0, residual: 0.0),
        ], radius: radius)
        #expect(kept.count == 2)
        let example = try #require(kept.first { $0.isExemplar })
        #expect(example.primitiveIDs == [1, 2, 5, 6])
        #expect(example.position == outer.position && example.scaleFactor == 1.3 && example.residual == 0.04)
        #expect(example.bounds == outer.bounds, "the inner frame's bounds lie inside the outer's")
        #expect(kept.contains { $0.primitiveIDs == [9] })
        // Without the example: ×½ and ×2 weigh alike, so the residual decides; ×1.1 beats both.
        let halves = SymbolMatcher.onePerPlace([
            Self.instance([1], CGPoint(x: 0, y: 0), scale: 2.0, residual: 0.03),
            Self.instance([2], CGPoint(x: 1, y: 0), scale: 0.5, residual: 0.02),
        ], radius: radius)
        #expect(halves.map(\.scaleFactor) == [0.5] && halves.first?.primitiveIDs == [1, 2])
        let nearest = SymbolMatcher.onePerPlace([
            Self.instance([1], CGPoint(x: 0, y: 0), scale: 0.5, residual: 0.0),
            Self.instance([2], CGPoint(x: 0, y: 1), scale: 1.1, residual: 0.07),
        ], radius: radius)
        #expect(nearest.map(\.scaleFactor) == [1.1])
        // Just outside the radius is another place; input order does not change the result.
        let apart = [Self.instance([1], CGPoint(x: 0, y: 0), scale: 1, residual: 0), Self.instance([2], CGPoint(x: 5.001, y: 0), scale: 1.3, residual: 0)]
        #expect(SymbolMatcher.onePerPlace(apart, radius: radius).count == 2)
        let shuffled = [Self.instance([3], CGPoint(x: 0, y: 0), scale: 1.2, residual: 0), Self.instance([4], CGPoint(x: 0, y: 2), scale: 0.9, residual: 0)]
        #expect(SymbolMatcher.onePerPlace(shuffled, radius: radius) == SymbolMatcher.onePerPlace(Array(shuffled.reversed()), radius: radius))
    }

    /// A frame symbol — inner 12 × 8 pt rectangle inside a 16 × 12 pt one, 2 pt apart — as
    /// eight lines centred on `centre`, turned a quarter when `quarterTurn`.
    static func frame(firstID: UInt64, centre: CGPoint, quarterTurn: Bool = false) -> [VectorPrimitive] {
        func rectangle(_ halfWidth: Double, _ halfHeight: Double) -> [(CGPoint, CGPoint)] {
            let (w, h) = quarterTurn ? (halfHeight, halfWidth) : (halfWidth, halfHeight)
            let a = CGPoint(x: centre.x - w, y: centre.y - h), b = CGPoint(x: centre.x + w, y: centre.y - h)
            let c = CGPoint(x: centre.x + w, y: centre.y + h), d = CGPoint(x: centre.x - w, y: centre.y + h)
            return [(a, b), (b, c), (c, d), (d, a)]
        }
        return (rectangle(6, 4) + rectangle(8, 6)).enumerated().map { index, line in
            SymbolMatchTests.linePrimitive(firstID + UInt64(index), line.0, line.1)
        }
    }

    @Test("Frame symbols inside a field of short strokes are found once the field no longer welds them in")
    func framesInsideDenseField() throws {
        let centres = [CGPoint(x: 100, y: 100), CGPoint(x: 250, y: 150), CGPoint(x: 330, y: 220)]
        var page = Self.frame(firstID: 1, centre: centres[0])
        page += Self.frame(firstID: 11, centre: centres[1], quarterTurn: true)
        page += Self.frame(firstID: 21, centre: centres[2])
        // The field: 4 pt strokes every 9 pt in rows 9 pt apart (5 pt gaps along a row), with
        // every stroke that would come within 4.5 pt of a frame's outer edge left out.
        var id: UInt64 = 1000
        for row in 0...33 {
            for column in 0...44 {
                let start = CGPoint(x: Double(column) * 9, y: Double(row) * 9)
                let stroke = VectorBounds(minX: start.x, minY: start.y, maxX: start.x + 4, maxY: start.y)
                let clear = centres.allSatisfy { centre in
                    SymbolFeatureExtraction.gap(stroke, VectorBounds(minX: centre.x - 8, minY: centre.y - 8, maxX: centre.x + 8, maxY: centre.y + 8)) > 4.5
                }
                guard clear else { continue }
                page.append(SymbolMatchTests.linePrimitive(id, start, CGPoint(x: start.x + 4, y: start.y)))
                id += 1
            }
        }
        let exemplar = try SymbolExemplar(primitives: page, region: VectorBounds(minX: 91, minY: 93, maxX: 109, maxY: 107))
        #expect(exemplar.primitiveIDs == Array(1...8))
        // The exemplar's widest stroke gap is the 2 pt between its frames: the first pass links
        // at 2 × 4 × 1.5 = 12 pt and the 5 pt gaps of the field weld every frame into it; the
        // octave 0.5…1 links at 2 × 1 × 1.5 = 3 pt, under the frames' 4.5 pt clearance.
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: page)
        // Old output: confirmed = [] — one rejected cluster holding all three frames and the
        // whole field, far over the band.
        let found = report.confirmed.sorted { $0.position.x < $1.position.x }
        #expect(found.count == 3, "\(report.confirmed.map(\.position))")
        for (instance, centre) in zip(found, centres) {
            // Concentric frames: the feature-point centroid is the centre.
            #expect(abs(instance.position.x - centre.x) < 1e-6 && abs(instance.position.y - centre.y) < 1e-6, "\(instance.position)")
            #expect(abs(instance.scaleFactor - 1) < 1e-6)
        }
        #expect(found.map(\.isExemplar) == [true, false, false])
        #expect(found.map(\.primitiveIDs) == [Array(1...8), Array(11...18), Array(21...28)])
        // The field stays a rejection, without the frames.
        let confirmedIDs = Set(report.confirmed.flatMap(\.primitiveIDs))
        #expect(report.rejected.allSatisfy { Set($0.primitiveIDs).isDisjoint(with: confirmedIDs) })
    }
}
