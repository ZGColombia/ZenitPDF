import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFVectorExtraction

/// NL-AUTO-02: the review between a symbol search and its count. Bugs fixed here:
/// `ProjectWindowController+SymbolSchedule.swift:202` (the warning fired on every sheet because
/// every stray stroke counted as a skip) and `:162-195` (a rerun double counted).
struct SymbolCountReviewTests {

    /// One stroked line, the only primitive these sheets are drawn with.
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

    /// A minimal real exemplar of two strokes.
    static func makeExemplar() throws -> SymbolExemplar {
        try SymbolExemplar(
            primitives: [
                linePrimitive(1, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 8)),
                linePrimitive(2, CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0))
            ],
            region: VectorBounds(minX: -1, minY: -1, maxX: 7, maxY: 9)
        )
    }

    /// A door-like symbol at `origin`: a 20-long leaf, a 12-long jamb and a 6-long stop, as
    /// three strokes. `stopLength` lets one instance be drawn slightly off.
    static func door(_ base: UInt64, at origin: CGPoint, stopLength: Double = 6) -> [VectorPrimitive] {
        let x = origin.x, y = origin.y
        return [
            linePrimitive(base, CGPoint(x: x, y: y), CGPoint(x: x + 20, y: y)),
            linePrimitive(base + 1, CGPoint(x: x, y: y), CGPoint(x: x, y: y + 12)),
            linePrimitive(base + 2, CGPoint(x: x + 20, y: y), CGPoint(x: x + 20, y: y + stopLength))
        ]
    }

    /// Six doors, one drawn with its stop 12 long instead of 6 (measured residual 0.137 of RMS radius against the 0.08 bar: a near miss under 2 × 0.08), and 40 stray single strokes —
    /// the hatch and text a real sheet is full of.
    static func sheet() -> [VectorPrimitive] {
        var primitives: [VectorPrimitive] = []
        let origins = [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 100),
                       CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 300), CGPoint(x: 300, y: 300)]
        for (index, origin) in origins.enumerated() {
            primitives += door(UInt64(10 * (index + 1)), at: origin)
        }
        primitives += door(200, at: CGPoint(x: 400, y: 200), stopLength: 12)
        for index in 0..<40 {
            let x = 50.0 + Double(index) * 12
            primitives.append(linePrimitive(UInt64(1000 + index), CGPoint(x: x, y: 600), CGPoint(x: x + 3, y: 605)))
        }
        return primitives
    }

    static func exemplar(_ primitives: [VectorPrimitive]) throws -> SymbolExemplar {
        try SymbolExemplar(primitives: primitives, region: VectorBounds(minX: 95, minY: 95, maxX: 125, maxY: 117))
    }

    @Test("Six doors and one drawn off: six confirmed, one near miss, and the stray strokes are only a count")
    func sixConfirmedOneNearMiss() throws {
        let primitives = Self.sheet()
        let exemplar = try Self.exemplar(primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        let page = PageID(UUID())
        let result = SymbolCountReviewBuilder().pageResult(
            pageID: page, pageIndex: 0, exemplar: exemplar, report: report, existing: []
        )
        #expect(result.confirmedCount == 6, "\(result.candidates.map(\.status))")
        #expect(result.nearMissCount == 1)
        let nearMiss = try #require(result.candidates.first { if case .nearMiss = $0.status { true } else { false } })
        // The off door sits at (400, 200): its position lies inside its own bounds.
        #expect(nearMiss.bounds.minX >= 399 && nearMiss.bounds.maxX <= 421, "\(nearMiss.bounds)")
        #expect(!nearMiss.isSelectedByDefault)
        // Old output: every rejection was a "skip", and the warning said so. Now the strays are
        // one number in the summary.
        #expect(result.otherShapeCount == report.rejected.count - 1)
        #expect(result.otherShapeCount > 0)

        // Unticking one confirmed instance lands five.
        var selected = Set(result.candidates.filter(\.isSelectedByDefault).map(\.id))
        selected.remove(try #require(selected.first))
        let accepted = SymbolCountReviewBuilder.acceptedPositions(from: [result], selected: selected, exemplar: exemplar)
        #expect(accepted.count == 1)
        #expect(accepted.first?.positions.count == 5)
    }

    @Test("Rerunning D-12 on the same page lands nothing new and says why")
    func rerunIsAlreadyCounted() throws {
        let primitives = Self.sheet()
        let exemplar = try Self.exemplar(primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        let page = PageID(UUID())
        let first = SymbolCountReviewBuilder().pageResult(
            pageID: page, pageIndex: 0, exemplar: exemplar, report: report, existing: []
        )
        let landed = first.candidates.filter(\.isSelectedByDefault).map {
            ExistingCountPoint(subject: "D-12", position: $0.position)
        }
        // Old output: a second count markup at the same six positions — a silent double count.
        let second = SymbolCountReviewBuilder().pageResult(
            pageID: page, pageIndex: 0, exemplar: exemplar, report: report, existing: landed
        )
        #expect(second.confirmedCount == 0)
        #expect(second.alreadyCountedCount == 6)
        #expect(second.candidates.filter(\.isSelectedByDefault).isEmpty)
        let accepted = SymbolCountReviewBuilder.acceptedPositions(
            from: [second],
            selected: Set(second.candidates.filter(\.isSelectedByDefault).map(\.id)),
            exemplar: exemplar
        )
        #expect(accepted.isEmpty)
    }

    @Test("A place already counted under another designation is reported as that designation's")
    func contestedAcrossRuns() throws {
        let primitives = Self.sheet()
        let exemplar = try Self.exemplar(primitives)
        let report = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        let first = try #require(report.confirmed.first)
        let existing = [ExistingCountPoint(subject: "D-13", position: PDFPoint(x: first.position.x + 0.5, y: first.position.y))]
        let result = SymbolCountReviewBuilder().pageResult(
            pageID: PageID(UUID()), pageIndex: 0, exemplar: exemplar, report: report, existing: existing
        )
        #expect(result.candidates.contains { $0.status == .alreadyCounted(subject: "D-13") })
        #expect(result.confirmedCount == 5)
    }

    @Test("The near-miss rule, by hand")
    func nearMissRule() throws {
        let exemplar = try Self.makeExemplar() // two primitives
        func rejection(_ count: Int, _ reason: SymbolRejectionReason) -> SymbolRejection {
            SymbolRejection(
                primitiveIDs: (0..<UInt64(count)).map { $0 + 50 },
                position: .zero,
                bounds: VectorBounds(point: .zero),
                reason: reason
            )
        }
        // Residual 0.15 against 0.08: under 2 × 0.08 = 0.16 → near miss.
        #expect(SymbolCountReviewBuilder.isNearMiss(rejection(2, .residualTooHigh(residual: 0.15, threshold: 0.08)), exemplar: exemplar))
        // 0.17 is over 0.16.
        #expect(!SymbolCountReviewBuilder.isNearMiss(rejection(2, .residualTooHigh(residual: 0.17, threshold: 0.08)), exemplar: exemplar))
        // Scale 5 against band 0.25…4: 4 × 1.5 = 6 → near miss; 7 is not.
        #expect(SymbolCountReviewBuilder.isNearMiss(rejection(2, .scaleOutsideBand(scale: 5, band: 0.25...4)), exemplar: exemplar))
        #expect(!SymbolCountReviewBuilder.isNearMiss(rejection(2, .scaleOutsideBand(scale: 7, band: 0.25...4)), exemplar: exemplar))
        // Four primitives against two is 200 %, outside 50…150 %.
        #expect(!SymbolCountReviewBuilder.isNearMiss(rejection(4, .residualTooHigh(residual: 0.1, threshold: 0.08)), exemplar: exemplar))
        // A single stray stroke is never a near miss.
        #expect(!SymbolCountReviewBuilder.isNearMiss(rejection(1, .tooFewPrimitives(found: 1, required: 2)), exemplar: exemplar))
    }
}

/// NL-AUTO-06: two types that both claim a place.
struct SymbolCountContestedTests {

    @Test("A door boxed as D-12 and, with a wider box, as D-13 is contested where both confirm it")
    func contested() throws {
        let primitives = SymbolCountReviewTests.sheet()
        let d12 = try SymbolCountReviewTests.exemplar(primitives)
        // The same symbol boxed again from another instance: every door is claimed by both.
        let d13 = try SymbolExemplar(primitives: primitives, region: VectorBounds(minX: 195, minY: 95, maxX: 225, maxY: 117))
        let page = PageID(UUID())
        let builder = SymbolCountReviewBuilder()
        let r12 = try SymbolMatcher().matches(exemplar: d12, in: primitives)
        let r13 = try SymbolMatcher().matches(exemplar: d13, in: primitives)
        let runs = [
            SymbolCountReviewBuilder.TypeRun(designation: "D-12", report: r12,
                result: builder.pageResult(pageID: page, pageIndex: 0, exemplar: d12, report: r12, existing: [], idOffset: 10_000_000)),
            SymbolCountReviewBuilder.TypeRun(designation: "D-13", report: r13,
                result: builder.pageResult(pageID: page, pageIndex: 0, exemplar: d13, report: r13, existing: [], idOffset: 20_000_000))
        ]
        let groups = SymbolCountReviewBuilder.contestedGroups(runs)
        // Six doors, each claimed once by each type: six groups of two.
        #expect(groups.count == 6)
        #expect(groups.allSatisfy { $0.count == 2 && $0[0] < 20_000_000 && $0[1] >= 20_000_000 })
        // One type alone contests nothing.
        #expect(SymbolCountReviewBuilder.contestedGroups([runs[0]]).isEmpty)
    }
}
