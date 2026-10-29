import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// The one scenario the determinism run of `QUALITY_BAR` 3.4 replays.
///
/// It is defined once, here, and used by both the in-process repeat test and the
/// `zpdf-snap-decision-log` executable that the 20-process test spawns, so the two cannot
/// drift apart and quietly stop comparing the same thing.
public enum SnapDeterminismScenario {

    /// A crowded little scene: two crossing lines, a circle, a cubic, a closed polygon, a
    /// markup polyline and a zone boundary. Every snap kind in the priority table that does not
    /// need an in-progress point is reachable somewhere along the path.
    public static func makeScene(insertionSeed: UInt64 = 0) throws -> SnapScene {
        let page = try SnapScene.letterPage()

        var primitives: [SnapPrimitive] = [
            SnapScene.segment(id: 101, PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 300)),
            SnapScene.segment(id: 102, PDFPoint(x: 100, y: 300), PDFPoint(x: 300, y: 100)),
            SnapScene.segment(id: 103, PDFPoint(x: 150, y: 200), PDFPoint(x: 260, y: 200)),
            SnapScene.circle(id: 104, center: PDFPoint(x: 200, y: 200), radius: 40),
            SnapScene.segment(id: 107, PDFPoint(x: 120, y: 260), PDFPoint(x: 280, y: 140))
        ]
        if let ring = SnapScene.polyline(
            id: 105,
            [
                PDFPoint(x: 140, y: 140), PDFPoint(x: 260, y: 140),
                PDFPoint(x: 260, y: 260), PDFPoint(x: 140, y: 260)
            ],
            isClosed: true
        ) {
            primitives.append(ring)
        }
        if let curve = SnapScene.cubic(
            id: 106,
            PDFPoint(x: 120, y: 120),
            PDFPoint(x: 160, y: 300),
            PDFPoint(x: 240, y: 100),
            PDFPoint(x: 280, y: 280)
        ) {
            primitives.append(curve)
        }

        var markups: [SnapMarkupGeometry] = [
            SnapMarkupGeometry(
                id: MarkupID(
                    UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID()
                ),
                geometry: [
                    .polyline(
                        points: [
                            PDFPoint(x: 180, y: 170), PDFPoint(x: 230, y: 170),
                            PDFPoint(x: 230, y: 230)
                        ],
                        isClosed: false
                    )
                ],
                layerID: "takeoff"
            ),
            SnapMarkupGeometry(
                id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000002") ?? UUID()),
                geometry: [.point(PDFPoint(x: 210, y: 210))],
                layerID: "takeoff"
            )
        ]

        var boundaries: [SnapBoundary] = [
            SnapBoundary(
                id: "zone-north",
                category: .zone,
                geometry: [
                    .polyline(
                        points: [
                            PDFPoint(x: 90, y: 90), PDFPoint(x: 320, y: 90),
                            PDFPoint(x: 320, y: 320), PDFPoint(x: 90, y: 320)
                        ],
                        isClosed: true
                    )
                ]
            ),
            SnapBoundary(
                id: "calibration-a",
                category: .calibrationPoint,
                geometry: [.point(PDFPoint(x: 245, y: 245))]
            )
        ]

        // The insertion seed shuffles the order the markups and boundaries are handed to the
        // builder. The resulting index must be identical: entry identifiers are content-derived
        // and every ordering in the engine is a total order, so insertion order is not
        // observable. A test that shuffles and compares is the cheap in-process proxy for the
        // 20-process run.
        if insertionSeed != 0 {
            var random = SnapDeterministicRandom(seed: insertionSeed)
            markups.shuffleDeterministically(using: &random)
            boundaries.shuffleDeterministically(using: &random)
            primitives.shuffleDeterministically(using: &random)
        }

        return try SnapScene.withVectorContent(
            page: page,
            primitives: primitives,
            markups: markups,
            boundaries: boundaries
        )
    }

    /// The replayed path: a diagonal traverse straight through the crossing point, a dither,
    /// a zoom change with the cursor stationary, and a run at 5 % and 6400 %.
    public static func makePath() -> SnapPointerPath {
        var samples: [SnapPointerPath.Sample] = []

        // At zoom 1 with the page anchored at the origin and an unflipped view, view point
        // (x, y) is page point (x, y): the traverse below is therefore written directly in page
        // coordinates and crosses (200, 200), where lines 101 and 102 intersect.
        samples += SnapPointerPath.traverse(
            name: "diagonal", from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 250),
            steps: 120, zoom: 1.0
        ).samples

        samples += SnapPointerPath.dither(
            name: "dither-near-crossing",
            centre: CGPoint(x: 200, y: 205),
            direction: CGVector(dx: 1, dy: 0),
            amplitudeViewPoints: 3.9,
            sampleCount: 200,
            zoom: 1.0
        ).samples

        for zoom in [0.05, 0.25, 4.0, 16.0, 64.0] {
            samples.append(
                SnapPointerPath.Sample(
                    viewPoint: CGPoint(x: 200 * zoom, y: 200 * zoom),
                    zoom: zoom
                )
            )
            samples.append(
                SnapPointerPath.Sample(
                    viewPoint: CGPoint(x: 202 * zoom, y: 197 * zoom),
                    zoom: zoom,
                    backingScale: 1.0
                )
            )
        }

        // `approach` works in view points. At zoom 2 with the page anchored at the origin, the
        // calibration point and ring corner cluster at page (245, 245) is view (490, 490); the
        // target used to be written in page units and ended at page (122.5, 122.5), nowhere near
        // the cluster it names (BH-668).
        let clusterZoom = 2.0
        samples += SnapPointerPath.approach(
            name: "cluster", target: CGPoint(x: 245 * clusterZoom, y: 245 * clusterZoom),
            startDistance: 40, steps: 60, zoom: clusterZoom
        ).samples

        return SnapPointerPath(name: "determinism", samples: samples)
    }

    /// Replays the path and returns the decision log.
    public static func decisionLog(insertionSeed: UInt64 = 0) throws -> [String] {
        let scene = try makeScene(insertionSeed: insertionSeed)
        let path = makePath()
        var engine = SnapEngine()
        var settings = SnapSettings.default
        settings.gridSpacingPoints = 25
        settings.angleIncrementDegrees = 15

        var log: [String] = []
        log.reserveCapacity(path.samples.count)
        for event in try path.events(anchorPagePoint: PDFPoint(x: 130, y: 130)) {
            let resolution = try engine.resolve(
                SnapQuery(event: event, settings: settings),
                in: scene.index
            )
            log.append(resolution.decision.logLine)
        }
        return log
    }
}

extension Array {
    /// Fisher-Yates with a caller-supplied deterministic generator.
    mutating func shuffleDeterministically(using random: inout SnapDeterministicRandom) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = random.nextInt(below: i + 1)
            if i != j { swapAt(i, j) }
        }
    }
}
