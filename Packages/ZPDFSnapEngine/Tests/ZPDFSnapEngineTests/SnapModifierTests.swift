import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// `SNAP_CONTRACT` 13.8: the modifier semantics, driven as data with no view layer in sight.
@Suite("Snap modifiers (SNAP_CONTRACT 13.8)")
struct SnapModifierTests {

    static func scene() throws -> SnapScene {
        let page = try SnapScene.letterPage()
        return try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.point(id: 1, PDFPoint(x: 200, y: 200)),
                SnapScene.point(id: 2, PDFPoint(x: 260, y: 200))
            ]
        )
    }

    static func resolve(
        _ scene: SnapScene,
        at cursor: PDFPoint,
        modifiers: SnapModifiers,
        settings: SnapSettings,
        anchor: PDFPoint? = nil,
        engine: inout SnapEngine
    ) throws -> SnapResolution {
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

    static var pointsOnly: SnapSettings {
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint, .angleIncrement]
        return settings
    }

    @Test("Command inverts the configured enabled state in both directions")
    func commandToggles() throws {
        let scene = try Self.scene()
        var engine = SnapEngine()
        var on = Self.pointsOnly
        on.isEnabled = true

        let plain = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .none,
            settings: on, engine: &engine
        )
        #expect(plain.winner?.primitiveID == 1)

        let suppressed = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .command,
            settings: on, engine: &engine
        )
        #expect(suppressed.winner == nil)
        #expect(suppressed.resolvedPagePoint == PDFPoint(x: 203, y: 200))

        var off = Self.pointsOnly
        off.isEnabled = false
        let offPlain = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .none,
            settings: off, engine: &engine
        )
        #expect(offPlain.winner == nil)

        let offWithCommand = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .command,
            settings: off, engine: &engine
        )
        #expect(offWithCommand.winner?.primitiveID == 1)
    }

    @Test("Option held bypasses the snap and returns the raw point")
    func optionBypasses() throws {
        let scene = try Self.scene()
        var engine = SnapEngine()
        let bypassed = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .option,
            settings: Self.pointsOnly, engine: &engine
        )
        #expect(bypassed.winner == nil)
        #expect(bypassed.feedback == nil)
        #expect(bypassed.resolvedPagePoint == PDFPoint(x: 203, y: 200))

        // Releasing Option puts the user back where they were, not somewhere new.
        let released = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .none,
            settings: Self.pointsOnly, engine: &engine
        )
        #expect(released.winner?.primitiveID == 1)
    }

    @Test("An Option tap cycles like Tab")
    func optionTapCycles() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.point(id: 1, PDFPoint(x: 200, y: 200)),
                SnapScene.point(id: 2, PDFPoint(x: 203, y: 200))
            ]
        )
        var engine = SnapEngine()
        let first = try Self.resolve(
            scene, at: PDFPoint(x: 201, y: 200), modifiers: .none,
            settings: Self.pointsOnly, engine: &engine
        )
        engine.apply(.optionTapped)
        let second = try Self.resolve(
            scene, at: PDFPoint(x: 201, y: 200), modifiers: .none,
            settings: Self.pointsOnly, engine: &engine
        )
        #expect(first.winner?.primitiveID != second.winner?.primitiveID)
    }

    @Test("Shift constrains the direction from the in-progress point")
    func shiftConstrains() throws {
        let page = try SnapScene.letterPage()
        // Anchor at (100,100); the 45-degree ray is one of the 15-degree increments. `onRay`
        // sits exactly on it; `offRay` sits 12 page points along the ray's normal, which is
        // outside the 10-view-point direction tolerance at zoom 1. The cursor is placed so that
        // `offRay` is the *nearer* of the two, which is what makes the test mean something:
        // without Shift the nearer one must win, with Shift the constrained one must.
        let anchor = PDFPoint(x: 100, y: 100)
        let onRay = PDFPoint(x: 200, y: 200)
        let normal = PDFVector(dx: -1 / 2.0.squareRoot(), dy: 1 / 2.0.squareRoot())
        let offRay = PDFPoint(x: onRay.x + 12 * normal.dx, y: onRay.y + 12 * normal.dy)
        let cursor = PDFPoint(x: onRay.x + 7 * normal.dx, y: onRay.y + 7 * normal.dy)

        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [SnapScene.point(id: 1, onRay), SnapScene.point(id: 2, offRay)]
        )

        var settings = Self.pointsOnly
        settings.angleIncrementDegrees = 15
        var engine = SnapEngine()

        let unconstrained = try Self.resolve(
            scene, at: cursor, modifiers: .none, settings: settings,
            anchor: anchor, engine: &engine
        )
        #expect(unconstrained.winner?.primitiveID == 2)

        engine.reset()
        let constrained = try Self.resolve(
            scene, at: cursor, modifiers: .shift, settings: settings,
            anchor: anchor, engine: &engine
        )
        let winner = try #require(constrained.winner)
        #expect(winner.primitiveID == 1)
        #expect(winner.satisfiesDirectionConstraint)
        // The loser is still offered as an alternative, flagged as violating the constraint,
        // rather than being filtered out: one total order over all candidates, no hidden set.
        let rejected = try #require(constrained.alternatives.first { $0.primitiveID == 2 })
        #expect(!rejected.satisfiesDirectionConstraint)
    }

    @Test("Shift with nothing in range still projects onto the constrained ray")
    func shiftProjectsWithoutCandidate() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(page: page, primitives: [])
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint]
        settings.angleIncrementDegrees = 45
        var engine = SnapEngine()

        // Anchor (100,100), cursor (200,205): the nearest 45-degree ray is the diagonal, and
        // the projection of the cursor onto it is the midpoint of (200,205) and its mirror.
        let resolution = try Self.resolve(
            scene, at: PDFPoint(x: 200, y: 205), modifiers: .shift, settings: settings,
            anchor: PDFPoint(x: 100, y: 100), engine: &engine
        )
        #expect(resolution.winner == nil)
        #expect(Swift.abs(resolution.resolvedPagePoint.x - 202.5) < 1e-9)
        #expect(Swift.abs(resolution.resolvedPagePoint.y - 202.5) < 1e-9)
    }

    @Test("The modifier machine is a pure state machine")
    func machineSemantics() {
        var machine = SnapModifierMachine()
        #expect(!machine.isBypassing)
        #expect(machine.isSnapEnabled(configured: true))

        var effect = machine.apply(.keysChanged([.shift, .option]))
        #expect(effect.constrainsAngle)
        #expect(effect.bypassesSnap)

        effect = machine.apply(.cycleForward)
        #expect(effect.cycleAdvance == 1)
        effect = machine.apply(.cycleForward)
        #expect(effect.cycleAdvance == 2)
        effect = machine.apply(.cycleBackward)
        #expect(effect.cycleAdvance == 1)

        effect = machine.apply(.reset)
        #expect(effect.cycleAdvance == 0)
        #expect(effect.didReset)

        machine.apply(.keysChanged(.command))
        #expect(!machine.isSnapEnabled(configured: true))
        #expect(machine.isSnapEnabled(configured: false))
    }

    @Test("Escape clears the held candidate and the cycle")
    func escapeResets() throws {
        let scene = try Self.scene()
        var engine = SnapEngine()
        _ = try Self.resolve(
            scene, at: PDFPoint(x: 203, y: 200), modifiers: .none,
            settings: Self.pointsOnly, engine: &engine
        )
        #expect(engine.heldCandidate != nil)
        engine.apply(.reset)
        #expect(engine.heldCandidate == nil)
        #expect(engine.cycleAdvance == 0)
    }
}
