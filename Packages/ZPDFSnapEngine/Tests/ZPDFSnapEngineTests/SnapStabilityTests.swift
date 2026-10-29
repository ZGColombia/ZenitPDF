import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// `QUALITY_BAR` 3.3 and S9: anti-jitter, asserted by replaying pointer paths and reading the
/// decision log.
///
/// The scene is two equal-priority endpoints 16 page points apart, at page `y = 200`. Their
/// perpendicular bisector is `x = 200`. Sixteen apart is not arbitrary: the documented release
/// rule is "the cursor has moved more than `hysteresisPixels` past the point where the two
/// candidates were equally good", and the distance difference between two points 2h apart
/// saturates at 2h once the cursor is outside both — so a separation of exactly 2 * 4 = 8 could
/// never release the held candidate at all. Sixteen puts the release at `x = 204`, exactly four
/// view points past the midline at zoom 1.
@Suite("Snap stability (QUALITY_BAR 3.3, S9)")
struct SnapStabilityTests {

    static let leftX = 192.0
    static let rightX = 208.0
    static let midlineX = 200.0
    static let y = 200.0

    static func scene() throws -> SnapScene {
        let page = try SnapScene.letterPage()
        return try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.point(id: 1, PDFPoint(x: leftX, y: y)),
                SnapScene.point(id: 2, PDFPoint(x: rightX, y: y))
            ]
        )
    }

    static var settings: SnapSettings {
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint]
        return settings
    }

    @Test("A monotone traverse across the bisector produces exactly one switch, past the band")
    func monotoneTraverse() throws {
        let scene = try Self.scene()
        let positions = stride(from: Self.leftX, through: Self.rightX, by: 0.05)
            .map { PDFPoint(x: $0, y: Self.y) }
        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: scene.page, zoom: 1.0),
            settings: Self.settings
        )

        #expect(run.switchCount == 1)
        let switchIndex = try #require(run.switchIndices.first)
        let switchX = positions[switchIndex].x

        // The switch must happen strictly after the midline plus the hysteresis band, and must
        // not be deferred beyond it by more than one sample.
        #expect(switchX > Self.midlineX + SnapSettings.specHysteresisPixels)
        #expect(switchX <= Self.midlineX + SnapSettings.specHysteresisPixels + 0.05)

        #expect(run.resolutions.first?.winner?.primitiveID == 1)
        #expect(run.resolutions.last?.winner?.primitiveID == 2)
    }

    @Test(
        "Dither inside the hysteresis band produces zero switches",
        arguments: [2.0, 3.9]
    )
    func ditherInsideBand(amplitude: Double) throws {
        let scene = try Self.scene()
        // Acquire the left candidate first, then dither about the midline.
        var positions = [PDFPoint(x: Self.leftX, y: Self.y)]
        let dither = SnapPointerPath.dither(
            name: "dither-\(amplitude)",
            centre: CGPoint(x: Self.midlineX, y: Self.y),
            direction: CGVector(dx: 1, dy: 0),
            amplitudeViewPoints: amplitude,
            sampleCount: 200,
            zoom: 1.0
        )
        positions += dither.samples.map { PDFPoint(x: Double($0.viewPoint.x), y: Self.y) }

        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: scene.page, zoom: 1.0),
            settings: Self.settings
        )
        #expect(run.switchCount == 0)
        #expect(run.resolutions.allSatisfy { $0.winner?.primitiveID == 1 })
    }

    @Test("Dither outside the band may switch, but never more than it crosses")
    func ditherOutsideBand() throws {
        let scene = try Self.scene()
        var positions = [PDFPoint(x: Self.leftX, y: Self.y)]
        let dither = SnapPointerPath.dither(
            name: "dither-wide",
            centre: CGPoint(x: Self.midlineX, y: Self.y),
            direction: CGVector(dx: 1, dy: 0),
            amplitudeViewPoints: 7.0,
            sampleCount: 200,
            zoom: 1.0
        )
        positions += dither.samples.map { PDFPoint(x: Double($0.viewPoint.x), y: Self.y) }

        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: scene.page, zoom: 1.0),
            settings: Self.settings
        )

        // A full crossing is a sample that is more than 4 view points past the midline on the
        // opposite side from the last such sample. The switch count may not exceed it.
        var crossings = 0
        var side = -1
        for position in positions {
            let offset = position.x - Self.midlineX
            let newSide = offset > SnapSettings.specHysteresisPixels
                ? 1
                : (offset < -SnapSettings.specHysteresisPixels ? -1 : side)
            if newSide != side { crossings += 1 }
            side = newSide
        }
        #expect(run.switchCount <= crossings)
        #expect(run.switchCount > 0, "a +/-7 point dither must be able to switch at all")
    }

    @Test("A held candidate is released once it leaves tolerance + hysteresis")
    func releaseOnLeavingBand() throws {
        let page = try SnapScene.letterPage()
        // One lone endpoint: nothing can be "clearly better", so only rule 1 can release it.
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.point(id: 1, PDFPoint(x: 200, y: 200))]
        )
        let positions = stride(from: 200.0, through: 220.0, by: 0.05)
            .map { PDFPoint(x: $0, y: 200) }
        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: page, zoom: 1.0),
            settings: Self.settings
        )

        let lastHeld = try #require(
            run.resolutions.lastIndex(where: { $0.winner != nil })
        )
        let distance = positions[lastHeld].x - 200
        // Tolerance 10 + hysteresis 4 = 14 page points at zoom 1.
        #expect(distance > 10)
        #expect(distance <= 14 + 1e-9)
        #expect(run.resolutions.last?.winner == nil)
        // While held beyond the plain tolerance the candidate is flagged, so the UI can show it.
        #expect(run.resolutions[lastHeld].isHeldByHysteresis)
    }

    @Test("Tab visits every candidate in a cluster of eight exactly once per cycle")
    func tabCyclesEveryCandidateOnce() throws {
        let page = try SnapScene.letterPage()
        let centre = PDFPoint(x: 300, y: 300)
        let primitives = (0..<8).map { i -> SnapPrimitive in
            let angle = Double(i) * Double.pi / 4
            return SnapScene.point(
                id: UInt64(10 + i),
                PDFPoint(
                    x: centre.x + 3 * Foundation.cos(angle),
                    y: centre.y + 3 * Foundation.sin(angle)
                )
            )
        }
        let scene = try SnapScene.withVectorContent(page: page, primitives: primitives)

        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1.0)
        let event = SnapPointerEvent(
            viewPoint: try SnapReplay.viewPoint(centre, page: page, layout: layout),
            layout: layout
        )
        let query = SnapQuery(event: event, settings: Self.settings)

        var visited: [UInt64] = []
        for _ in 0..<8 {
            let resolution = try engine.resolve(query, in: scene.index)
            visited.append(try #require(resolution.winner?.primitiveID))
            #expect(resolution.alternatives.count == 7)
            engine.apply(.cycleForward)
        }
        #expect(Set(visited).count == 8, "every candidate visited exactly once: \(visited)")

        // A full cycle returns to the start, and the order is stable.
        var second: [UInt64] = []
        for _ in 0..<8 {
            let resolution = try engine.resolve(query, in: scene.index)
            second.append(try #require(resolution.winner?.primitiveID))
            engine.apply(.cycleForward)
        }
        #expect(visited == second)

        // Shift-Tab steps back through the same order.
        engine.apply(.cycleBackward)
        let back = try engine.resolve(query, in: scene.index)
        #expect(back.winner?.primitiveID == visited[7])
    }

    @Test("A zoom change with the cursor stationary is deterministic and reported")
    func zoomChangeMidPath() throws {
        let scene = try Self.scene()
        let page = scene.page
        var engine = SnapEngine()
        var tolerances: [Double] = []
        var winners: [UInt64?] = []

        for zoom in [1.0, 0.25, 1.0, 4.0, 1.0] {
            let layout = SnapReplay.layout(zoom: zoom)
            let event = SnapPointerEvent(
                viewPoint: try SnapReplay.viewPoint(
                    PDFPoint(x: 198, y: Self.y), page: page, layout: layout
                ),
                layout: layout
            )
            let resolution = try engine.resolve(
                SnapQuery(event: event, settings: Self.settings), in: scene.index
            )
            tolerances.append(resolution.tolerancePagePoints)
            winners.append(resolution.winner?.primitiveID)
        }
        #expect(tolerances == [10, 40, 10, 2.5, 10])
        // At zoom 4 the radius is 2.5 page points and neither endpoint (6 and 10 away) is in
        // range; at every other zoom the left endpoint wins.
        #expect(winners == [1, 1, 1, nil, 1])
    }

    // MARK: - Cursor-following candidates (CR-38, CR-50)

    /// A double-line wall: two parallel segments `separation` pt apart, the lower at y = 100.
    static func doubleLineWall(separation: Double = 2) throws -> SnapScene {
        let page = try SnapScene.letterPage()
        return try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.segment(id: 1, PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)),
                SnapScene.segment(
                    id: 2, PDFPoint(x: 100, y: 100 + separation), PDFPoint(x: 300, y: 100 + separation)
                )
            ]
        )
    }

    static var nearestOnly: SnapSettings {
        var settings = SnapSettings.default
        settings.enabledKinds = [.nearestPointOnSegment]
        return settings
    }

    @Test("A double-line wall does not flip between its lines on every event (CR-38)")
    func doubleLineWallIsHeld() throws {
        let scene = try Self.doubleLineWall()
        // Along the wall, dithering 0.1 pt either side of the midline y = 101.
        let positions = (0..<200).map { i in
            PDFPoint(x: 150 + Double(i) * 0.5, y: i % 2 == 0 ? 100.9 : 101.1)
        }
        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: scene.page, zoom: 1.0),
            settings: Self.nearestOnly
        )
        let winners = run.resolutions.map { $0.winner?.primitiveID }
        var flips = 0
        for i in 1..<winners.count where winners[i] != winners[i - 1] { flips += 1 }
        // Old output: 199 flips — the nearest point's key quantised its position, which was
        // new at every event, so the held key never matched and nothing was ever held.
        #expect(flips == 0, "\(flips) flips" as Comment)
        #expect(winners.allSatisfy { $0 == 1 })
        // The flag means "would have lost without the credit": true on the events where the
        // upper line is the nearer one, false where the lower line wins on its own.
        for (i, resolution) in run.resolutions.enumerated() {
            #expect(resolution.isHeldByHysteresis == (i % 2 == 1), "event \(i)" as Comment)
        }
    }

    @Test("Along a double-line wall the held line is released only when the other is clearly better (CR-38)")
    func doubleLineWallReleasesPastTheBand() throws {
        // Ten apart, so the distance difference can reach the release margin — two lines
        // closer than twice the band never release each other by rule 2, only by leaving the
        // held radius, which is the documented rule.
        let scene = try Self.doubleLineWall(separation: 10)
        // From the lower line up past the upper one: y from 100 to 112 at x = 200.
        let positions = stride(from: 100.0, through: 112.0, by: 0.05).map { PDFPoint(x: 200, y: $0) }
        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: scene.page, zoom: 1.0),
            settings: Self.nearestOnly
        )
        let winners = run.resolutions.map { $0.winner?.primitiveID }
        #expect(winners.first == 1)
        #expect(winners.last == 2)
        let switchAt = try #require(winners.firstIndex { $0 == 2 })
        // Equal at y = 105; released once the cursor is 4 view points past that, y = 109 —
        // the same rule the endpoint traverse above is written against.
        let y = positions[switchAt].y
        #expect(y > 109 - 1e-9 && y <= 109 + 0.05 + 1e-9, "switched at y = \(y)" as Comment)
        var flips = 0
        for i in 1..<winners.count where winners[i] != winners[i - 1] { flips += 1 }
        // Old output: one flip at y = 105.05 — no hysteresis at all for a cursor-following kind.
        #expect(flips == 1)
    }

    @Test("Tab's choice survives sub-pixel motion along an edge (CR-50)")
    func tabSurvivesSubPixelMotion() throws {
        let scene = try Self.doubleLineWall()
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1.0)
        func resolve(_ point: PDFPoint) throws -> SnapResolution {
            try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: try SnapReplay.viewPoint(point, page: scene.page, layout: layout),
                        layout: layout
                    ),
                    settings: Self.nearestOnly
                ),
                in: scene.index
            )
        }
        #expect(try resolve(PDFPoint(x: 200, y: 100.9)).winner?.primitiveID == 1)
        engine.apply(.cycleForward)
        let cycled = try resolve(PDFPoint(x: 200, y: 100.9))
        #expect(cycled.winner?.primitiveID == 2)
        #expect(cycled.cycleIndex == 1)

        let moved = try resolve(PDFPoint(x: 200.001, y: 100.9))
        // Old output: primitive 1, cycle index 0 — the ranked list's signature hashed the two
        // nearest points' positions, which had moved by a thousandth of a point, so the cycle
        // reset and the user's Tab was undone.
        #expect(moved.winner?.primitiveID == 2)
        #expect(moved.cycleIndex == 1)
    }
}
