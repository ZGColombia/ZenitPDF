import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// Regressions in the replay tooling and the synthetic install path (BH-218/670,
/// BH-219/672, BH-664, BH-668, BH-669, BH-671).
@Suite("Scenario and install regressions")
struct ScenarioRegressionTests {

    static func settings(_ kinds: Set<SnapKind>) -> SnapSettings {
        var settings = SnapSettings.default
        settings.enabledKinds = kinds
        return settings
    }

    // MARK: - BH-218 / BH-670

    @Test("A cursor-following winner held along one segment is not a switch per event (BH-218)")
    func followingWinnerIsOneDecision() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [SnapScene.segment(id: 1, PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300))]
        )
        // 101 events along the segment, 3 view points above it.
        let positions = (0...100).map { PDFPoint(x: 150 + 2 * Double($0), y: 303) }
        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: page, zoom: 1),
            settings: Self.settings([.nearestPointOnSegment])
        )
        #expect(run.resolutions.allSatisfy { $0.winner?.primitiveID == 1 })
        // Old output: 100 — every event's new foot position was counted as a new winner.
        #expect(run.switchCount == 0)
        #expect(run.switchIndices.isEmpty)
    }

    @Test("Crossing from one wall line to the other is exactly one switch (BH-218)")
    func doubleLineWallSwitchesOnce() throws {
        // Lines at y = 300 and y = 316, walked diagonally so the feet move every event. Both
        // candidates are nearestPointOnSegment (priority 9), so the raw scores differ by
        // 0.5 x (d1 - d2) = 0.5 x ((y - 300) - (316 - y)) and the held lower line is released
        // when that exceeds the 4.0 margin: 2y - 616 > 8, y > 312. First sample past it: 312.25.
        // Old output: 56 switches — every event's new foot was counted.
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.segment(id: 1, PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300)),
                SnapScene.segment(id: 2, PDFPoint(x: 100, y: 316), PDFPoint(x: 400, y: 316))
            ]
        )
        let positions = stride(from: 301.0, through: 315.0, by: 0.25).map { PDFPoint(x: 150 + 4 * ($0 - 301), y: $0) }
        let run = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(pagePoints: positions, page: page, zoom: 1),
            settings: Self.settings([.nearestPointOnSegment])
        )
        #expect(run.switchCount == 1)
        let index = try #require(run.switchIndices.first)
        #expect(positions[index].y == 312.25)
        #expect(run.resolutions.first?.winner?.primitiveID == 1)
        #expect(run.resolutions.last?.winner?.primitiveID == 2)
    }

    // MARK: - BH-219 / BH-672 / BH-664

    @Test("Duplicate identifiers in a synthetic install are resolved as the extractor path resolves them (BH-219)")
    func duplicateIdentifiersAreResolved() throws {
        let page = try SnapScene.letterPage()
        let low = SnapScene.segment(id: 1, PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100))
        let high = SnapScene.segment(id: 1, PDFPoint(x: 100, y: 110), PDFPoint(x: 300, y: 110))

        for order in [[low, high], [high, low]] {
            let scene = try SnapScene.withVectorContent(page: page, primitives: order)
            let entries = scene.index.allEntries(in: .vector)
            // The builder's rule: probe upward in (id, minX, minY, ...) order. Both have id 1 and
            // minX 100; minY 100 < 110, so the lower segment keeps 1 and the upper becomes 2.
            // Old output: ids [1, 1] and vectorPrimitiveCount 1 (the count collapsed them).
            #expect(entries.map(\.id) == [1, 2])
            #expect(entries.last?.bounds.minY == 110)
            #expect(scene.index.vectorPrimitiveCount == 2)

            var engine = SnapEngine()
            let layout = SnapReplay.layout(zoom: 1)
            let near = try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: try SnapReplay.viewPoint(PDFPoint(x: 200, y: 111), page: page, layout: layout),
                        layout: layout
                    ),
                    settings: Self.settings([.nearestPointOnSegment])
                ),
                in: scene.index
            )
            #expect(near.winner?.primitiveID == 2)
        }
    }

    // MARK: - BH-671

    @Test("A synthetic ring over the vertex limit is refused like a markup ring (BH-671)")
    func oversizedRingIsRefused() throws {
        let page = try SnapScene.letterPage()
        let limit = SnapIndexLimits.standard.maximumRingVertices
        #expect(limit == 100_000)
        let points = (0...limit).map { i -> PDFPoint in
            let angle = Double(i) / Double(limit + 1) * 2 * Double.pi
            return PDFPoint(x: 300 + 200 * Foundation.cos(angle), y: 400 + 200 * Foundation.sin(angle))
        }
        let ring = try #require(SnapScene.polyline(id: 5, points, isClosed: true))
        // Old output: accepted and indexed.
        #expect(throws: SnapEngineError.indexTooLarge(count: limit + 1, limit: limit)) {
            _ = try SnapScene.withVectorContent(page: page, primitives: [ring])
        }
        let atLimit = try #require(SnapScene.polyline(id: 5, Array(points.prefix(limit)), isClosed: true))
        #expect(try SnapScene.withVectorContent(page: page, primitives: [atLimit]).index.vectorPrimitiveCount == 1)
    }

    // MARK: - BH-668

    @Test("The determinism path's cluster approach ends on the cluster it names (BH-668)")
    func clusterApproachEndsOnTheCluster() throws {
        let path = SnapDeterminismScenario.makePath()
        let last = try #require(path.samples.last)
        // Zoom 2, page anchored at the origin, unflipped: view = page x 2, so page (245, 245),
        // the calibration point, is view (490, 490). Old output: view (245, 245), page
        // (122.5, 122.5), on the far side of the scene.
        #expect(last.zoom == 2)
        #expect(last.viewPoint == CGPoint(x: 490, y: 490))

        // At the target the calibration point (priority 1) is 0 view points away and outranks
        // everything else in the scene within the 5-page-point radius.
        let log = try SnapDeterminismScenario.decisionLog()
        let fields = try #require(log.last).split(separator: " ")
        #expect(fields[1] == "calibrationPoint", "last line \(log.last ?? "")" as Comment)
    }

    // MARK: - BH-669

    @Test("A negative dither sample count gives an empty path instead of trapping (BH-669)")
    func negativeDitherIsEmpty() {
        // Old output: a fatal 'Range requires lowerBound <= upperBound' trap.
        let path = SnapPointerPath.dither(
            name: "negative", centre: .zero, direction: CGVector(dx: 1, dy: 0),
            amplitudeViewPoints: 1, sampleCount: -3, zoom: 1
        )
        #expect(path.samples.isEmpty)
    }
}
