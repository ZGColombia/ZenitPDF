import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// Regressions in the engine's per-event state: the `Tab` cycle, the modifier
/// inputs, the hysteresis flag and the Shift constraint (BH-215, BH-660, BH-661, BH-662).
///
/// Scores use the documented default weights: priority step 1.0, 0.5 per view point of
/// distance, a hysteresis margin of 2 x 4 view points x 0.5 = 4.0. Every expected winner below
/// is derived from those numbers in a comment.
@Suite("Engine state regressions")
struct EngineStateRegressionTests {

    static func resolve(
        _ scene: SnapScene,
        at cursor: PDFPoint,
        kinds: Set<SnapKind>,
        modifiers: SnapModifiers = .none,
        anchor: PDFPoint? = nil,
        engine: inout SnapEngine
    ) throws -> SnapResolution {
        var settings = SnapSettings.default
        settings.enabledKinds = kinds
        let layout = SnapReplay.layout(zoom: 1)
        return try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: scene.page, layout: layout),
                    layout: layout,
                    modifiers: modifiers,
                    anchorPagePoint: anchor
                ),
                settings: settings
            ),
            in: scene.index
        )
    }

    static func points(_ list: [(UInt64, Double, Double)]) throws -> SnapScene {
        try SnapScene.withVectorContent(
            page: try SnapScene.letterPage(),
            primitives: list.map { SnapScene.point(id: $0.0, PDFPoint(x: $0.1, y: $0.2)) }
        )
    }

    // MARK: - BH-215

    @Test("A sub-pixel swap of two equidistant candidates does not reset the Tab cycle (BH-215)")
    func tabSurvivesAReorder() throws {
        // A (200, 200), B (206, 200), C (203, 205), all equal-priority endpoints.
        // At (202.99, 200.5): |A| = sqrt(2.99^2 + 0.5^2) = 3.0315, |B| = sqrt(3.01^2 + 0.5^2)
        // = 3.0512, |C| = sqrt(0.01^2 + 4.5^2) = 4.5000: ranked A, B, C.
        // At (203.01, 200.5) — 0.02 view points away — |A| and |B| trade places: B, A, C.
        let scene = try Self.points([(1, 200, 200), (2, 206, 200), (3, 203, 205)])
        let left = PDFPoint(x: 202.99, y: 200.5)
        let right = PDFPoint(x: 203.01, y: 200.5)
        var engine = SnapEngine()

        let first = try Self.resolve(scene, at: left, kinds: [.endpoint], engine: &engine)
        #expect(first.winner?.primitiveID == 1)

        engine.apply(.cycleForward)
        engine.apply(.cycleForward)
        let third = try Self.resolve(scene, at: left, kinds: [.endpoint], engine: &engine)
        #expect(third.winner?.primitiveID == 3)
        #expect(third.cycleIndex == 2)

        // The jitter of the hand that pressed Tab. Old output: winner B (id 2), cycleIndex 0 —
        // the reorder changed the signature and threw the user back to the top.
        let jittered = try Self.resolve(scene, at: right, kinds: [.endpoint], engine: &engine)
        #expect(jittered.winner?.primitiveID == 3, "winner \(String(describing: jittered.winner))" as Comment)
        #expect(jittered.cycleIndex == 2)

        // The next Tab completes the cycle in the order it started in: C -> A.
        engine.apply(.cycleForward)
        let wrapped = try Self.resolve(scene, at: right, kinds: [.endpoint], engine: &engine)
        #expect(wrapped.winner?.primitiveID == 1)
        #expect(wrapped.cycleIndex == 0)

        // A genuinely different candidate set still resets: at (203, 194) C is 11 view points
        // away, outside the 10-point radius, and only A and B remain.
        let away = try Self.resolve(scene, at: PDFPoint(x: 203, y: 194), kinds: [.endpoint], engine: &engine)
        #expect(away.cycleIndex == 0)
        #expect(engine.cycleAdvance == 0)
    }

    // MARK: - BH-660

    @Test("Keys fed through apply(.keysChanged) are honoured by the next resolve (BH-660)")
    func appliedKeysAreHonoured() throws {
        let scene = try Self.points([(1, 200, 200)])
        var engine = SnapEngine()
        let cursor = PDFPoint(x: 201, y: 200)

        let effect = engine.apply(.keysChanged([.option]))
        #expect(effect.bypassesSnap)
        // Old output: winner id 1 — the event's `.none` overwrote the Option the caller had
        // just been told was bypassing.
        let bypassed = try Self.resolve(scene, at: cursor, kinds: [.endpoint], engine: &engine)
        #expect(bypassed.winner == nil)
        #expect(bypassed.resolvedPagePoint == cursor)

        engine.apply(.keysChanged(.none))
        let released = try Self.resolve(scene, at: cursor, kinds: [.endpoint], engine: &engine)
        #expect(released.winner?.primitiveID == 1)

        // Keys carried on the event keep working exactly as before.
        let viaEvent = try Self.resolve(scene, at: cursor, kinds: [.endpoint], modifiers: .option, engine: &engine)
        #expect(viaEvent.winner == nil)
        engine.apply(.reset)
        let afterReset = try Self.resolve(scene, at: cursor, kinds: [.endpoint], engine: &engine)
        #expect(afterReset.winner?.primitiveID == 1)
    }

    // MARK: - BH-661

    @Test("A held candidate that lost is not flagged as held in the alternatives (BH-661)")
    func losingHeldAlternativeIsNotFlagged() throws {
        // A (200, 200), B (215, 200). Acquire A at (200, 200), then move to (212, 200):
        // |A| = 12 view points (inside the 14-point held band), |B| = 3.
        // Raw A = 3 + 6 = 9, effective 9 - 4 = 5; raw B = 3 + 1.5 = 4.5. B wins.
        let scene = try Self.points([(1, 200, 200), (2, 215, 200)])
        var engine = SnapEngine()
        _ = try Self.resolve(scene, at: PDFPoint(x: 200, y: 200), kinds: [.endpoint], engine: &engine)
        let moved = try Self.resolve(scene, at: PDFPoint(x: 212, y: 200), kinds: [.endpoint], engine: &engine)

        #expect(moved.winner?.primitiveID == 2)
        #expect(moved.winner?.isHeldByHysteresis == false)
        let a = try #require(moved.alternatives.first { $0.primitiveID == 1 })
        // Old output: true — nothing is holding A; it lost.
        #expect(a.isHeldByHysteresis == false)
        // Its score is still the effective one the ranking used: 5.
        #expect(Swift.abs(a.score - 5) <= 1e-9)
    }

    // MARK: - BH-662

    @Test("A candidate that violates the Shift constraint never beats one that satisfies it (BH-662)")
    func shiftConstraintIsAbsolute() throws {
        // Anchor (100, 200), increment 15 degrees. Cursor (200, 209): angle atan(9/100) = 5.14
        // degrees rounds to 0, so the constrained ray is y = 200 and the angle-increment target
        // is (200, 200), 9 view points away: 15 + 4.5 = 19.5.
        // An endpoint at (200, 210.5) is 1.5 view points from the cursor and 10.5 off the ray,
        // outside the 10-point band: 3 + 0.75 + penalty. Old penalty 12: 15.75 < 19.5, the
        // endpoint won and the placed point left the constrained direction.
        let scene = try Self.points([(1, 200, 210.5)])
        var engine = SnapEngine()
        let resolution = try Self.resolve(
            scene,
            at: PDFPoint(x: 200, y: 209),
            kinds: [.endpoint, .angleIncrement],
            modifiers: .shift,
            anchor: PDFPoint(x: 100, y: 200),
            engine: &engine
        )
        let winner = try #require(resolution.winner)
        #expect(winner.kind == .angleIncrement, "winner \(winner)" as Comment)
        #expect(winner.position.distance(to: PDFPoint(x: 200, y: 200)) <= 1e-9)
        #expect(resolution.resolvedPagePoint.distance(to: PDFPoint(x: 200, y: 200)) <= 1e-9)
        let endpoint = try #require(resolution.alternatives.first { $0.kind == .endpoint })
        #expect(!endpoint.satisfiesDirectionConstraint)

        // The default penalty exceeds the widest possible spread of every other term: priority
        // 0..16, distance up to the 24 + 4 view-point held radius x 0.5 = 14, layer 6,
        // confidence 2 — 16 + 14 + 6 + 2 = 38.
        #expect(SnapScoringWeights.standard.directionConstraintViolation > 38)
    }
}

/// IM-086: one angle-constraint definition for the target, the direction test and the placed
/// point.
@Suite("Angle constraint (IM-086)")
struct AngleConstraintTests {

    @Test("Valid increments are (0, 180]; anything else constrains nothing, on every path")
    func incrementRange() {
        for degrees in [0.0, -15, 181, 360, .nan, .infinity] {
            #expect(SnapAngleConstraint(anchor: .zero, incrementDegrees: degrees) == nil, "\(degrees)" as Comment)
        }
        for degrees in [15.0, 90, 180] {
            #expect(SnapAngleConstraint(anchor: .zero, incrementDegrees: degrees) != nil, "\(degrees)" as Comment)
        }

        // Anchor (0, 0), candidate (100, 50) at atan(0.5) = 26.57 degrees. With an increment of
        // 200 degrees the old direction test rounded 26.57 / 200 to 0, measured a 50-point
        // offset from the x axis and reported a violation, while the target path emitted no
        // angle target at all for the same increment. Now both agree that 200 constrains
        // nothing.
        let position = PDFPoint(x: 100, y: 50)
        #expect(SnapSyntheticTargets.angleIncrement(cursor: position, anchor: .zero, incrementDegrees: 200, radius: 1_000).isEmpty)
        #expect(SnapSyntheticTargets.satisfiesDirection(position, anchor: .zero, incrementDegrees: 200, toleranceViewPoints: 10, zoom: 1))
    }

    @Test("Projection, direction and offset match the closed form")
    func closedForm() throws {
        // Anchor (10, 20), increment 90, point (110, 45): angle atan(25/100) = 14.04 degrees
        // rounds to 0, so the direction is +x, the projection is (110, 20) and the offset 25.
        let constraint = try #require(SnapAngleConstraint(anchor: PDFPoint(x: 10, y: 20), incrementDegrees: 90))
        let point = PDFPoint(x: 110, y: 45)
        let direction = try #require(constraint.direction(toward: point))
        #expect(Swift.abs(direction.dx - 1) <= 1e-15 && Swift.abs(direction.dy) <= 1e-15)
        #expect(try #require(constraint.projection(of: point)).distance(to: PDFPoint(x: 110, y: 20)) <= 1e-12)
        #expect(Swift.abs(constraint.perpendicularOffset(of: point) - 25) <= 1e-12)
        // At the anchor there is no direction; the anchor is on every ray.
        #expect(constraint.direction(toward: PDFPoint(x: 10, y: 20)) == nil)
        #expect(constraint.perpendicularOffset(of: PDFPoint(x: 10, y: 20)) == 0)

        // The target path and the direction test agree on that point: the angle target is the
        // projection, and the 25-point offset is a violation at zoom 1 with a 10-point band.
        let target = try #require(
            SnapSyntheticTargets.angleIncrement(
                cursor: point, anchor: PDFPoint(x: 10, y: 20), incrementDegrees: 90, radius: 30
            ).first
        )
        #expect(target.position.distance(to: PDFPoint(x: 110, y: 20)) <= 1e-12)
        #expect(!SnapSyntheticTargets.satisfiesDirection(point, anchor: PDFPoint(x: 10, y: 20), incrementDegrees: 90, toleranceViewPoints: 10, zoom: 1))
        #expect(SnapSyntheticTargets.satisfiesDirection(point, anchor: PDFPoint(x: 10, y: 20), incrementDegrees: 90, toleranceViewPoints: 10, zoom: 0.25))
    }

    @Test("Shift with nothing to snap to places the same point the angle target would")
    func placedPointMatchesTarget() throws {
        // Empty vector layer, grid off: the placed point is the engine's constrained point.
        // Anchor (100, 100), cursor (180, 130): atan(30/80) = 20.56 degrees rounds to 15.
        // Direction (cos 15, sin 15), projection 80 cos 15 + 30 sin 15 = 77.274 + 7.765 = 85.039.
        let scene = try SnapScene.withoutVectorContent(page: try SnapScene.letterPage())
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint]
        let layout = SnapReplay.layout(zoom: 1)
        var engine = SnapEngine()
        let cursor = PDFPoint(x: 180, y: 130)
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: scene.page, layout: layout),
                    layout: layout, modifiers: .shift, anchorPagePoint: PDFPoint(x: 100, y: 100)
                ),
                settings: settings
            ),
            in: scene.index
        )
        let angle = 15.0 * Double.pi / 180
        let length = 80 * Foundation.cos(angle) + 30 * Foundation.sin(angle)
        let expected = PDFPoint(x: 100 + length * Foundation.cos(angle), y: 100 + length * Foundation.sin(angle))
        #expect(Swift.abs(length - 85.039) <= 1e-3)
        #expect(resolution.winner == nil)
        #expect(resolution.resolvedPagePoint.distance(to: expected) <= 1e-12)
        let target = try #require(
            SnapSyntheticTargets.angleIncrement(cursor: cursor, anchor: PDFPoint(x: 100, y: 100), incrementDegrees: 15, radius: 100).first
        )
        #expect(target.position == resolution.resolvedPagePoint)
    }
}
