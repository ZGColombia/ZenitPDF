import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// Snap (C2) fuzzing: hostile geometry and hostile pointer input must produce a
/// result or a typed error — never a crash, never a `NaN`, never unbounded work.
@Suite("Snap fuzz")
struct SnapFuzzTests {

    /// Coordinates chosen to break naive arithmetic: zero-length, enormous, denormal, and
    /// exactly on the boundary of the page box.
    static let hostileMagnitudes: [Double] = [
        0, 1e-300, 1e-9, 1, 612, 792, 1e6, 1e12, -1e12, -0.0
    ]

    @Test("Structure-aware geometry fuzzing never crashes and never emits a non-finite point")
    func geometryFuzz() throws {
        let page = try SnapScene.letterPage()
        var random = SnapDeterministicRandom(seed: "snap-geometry-fuzz")

        for iteration in 0..<300 {
            var primitives: [SnapPrimitive] = []
            let count = 1 + random.nextInt(below: 12)
            for i in 0..<count {
                primitives.append(
                    Self.randomPrimitive(id: UInt64(i + 1), using: &random)
                )
            }
            // A hostile ring: many vertices, many of them duplicated.
            if iteration % 17 == 0 {
                var vertices: [PDFPoint] = []
                for j in 0..<2000 {
                    let value = Double(j % 7) * 13.0
                    vertices.append(PDFPoint(x: 100 + value, y: 100 + value))
                }
                if let ring = SnapScene.polyline(
                    id: UInt64(count + 1), vertices, isClosed: true
                ) {
                    primitives.append(ring)
                }
            }

            let scene = try SnapScene.withVectorContent(page: page, primitives: primitives)
            var engine = SnapEngine()

            for _ in 0..<12 {
                let cursor = PDFPoint(
                    x: random.nextUnitDouble() * 700 - 50,
                    y: random.nextUnitDouble() * 900 - 50
                )
                let zoom = [0.05, 0.25, 1.0, 4.0, 16.0, 64.0][random.nextInt(below: 6)]
                let layout = SnapReplay.layout(zoom: zoom)
                let anchor = random.nextUnitDouble() < 0.5
                    ? PDFPoint(x: random.nextUnitDouble() * 600, y: random.nextUnitDouble() * 700)
                    : nil
                let modifiers: SnapModifiers = random.nextUnitDouble() < 0.2 ? .shift : .none

                let resolution = try engine.resolve(
                    SnapQuery(
                        event: SnapPointerEvent(
                            viewPoint: try SnapReplay.viewPoint(
                                cursor, page: page, layout: layout
                            ),
                            layout: layout,
                            modifiers: modifiers,
                            anchorPagePoint: anchor
                        )
                    ),
                    in: scene.index
                )

                #expect(resolution.resolvedPagePoint.isFinite)
                #expect(resolution.rawPagePoint.isFinite)
                #expect(resolution.tolerancePagePoints.isFinite)
                for candidate in [resolution.winner].compactMap({ $0 }) + resolution.alternatives {
                    #expect(candidate.position.isFinite)
                    #expect(candidate.score.isFinite)
                    #expect(candidate.screenDistancePixels.isFinite)
                    #expect(candidate.screenDistancePixels >= 0)
                    // Every emitted candidate is inside the radius plus the hysteresis band,
                    // never further: a candidate outside it is a snap the user cannot explain.
                    let band = resolution.tolerancePagePoints + resolution.hysteresisPagePoints
                    #expect(
                        candidate.position.distance(to: resolution.rawPagePoint) <= band + 1e-9
                    )
                }
                #expect(resolution.alternatives.count <= SnapIndexLimits.standard.maximumRankedAlternatives)
            }
        }
    }

    @Test("Non-finite and absurd pointer input is refused, not absorbed")
    func hostilePointerInput() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.point(id: 1, PDFPoint(x: 300, y: 300))]
        )
        var engine = SnapEngine()

        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: SnapEngineError.self) {
                _ = try engine.resolve(
                    SnapQuery(
                        event: SnapPointerEvent(
                            viewPoint: CGPoint(x: value, y: 0),
                            layout: SnapReplay.layout(zoom: 1)
                        )
                    ),
                    in: scene.index
                )
            }
        }

        // A zoom outside the supported range is refused by the layout contract, not clamped
        // into silence.
        for zoom in [0.0, -1.0, 1e9] {
            #expect(throws: (any Error).self) {
                let layout = PageViewLayout(
                    anchor: .zero, zoom: zoom, backingScale: 2, isViewFlipped: false
                )
                _ = try engine.resolve(
                    SnapQuery(event: SnapPointerEvent(viewPoint: .zero, layout: layout)),
                    in: scene.index
                )
            }
        }

        // A cursor a million points off the page is a valid query with no answer.
        let layout = SnapReplay.layout(zoom: 1)
        let far = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: CGPoint(x: 1e9, y: -1e9), layout: layout
                )
            ),
            in: scene.index
        )
        #expect(far.winner == nil)
        #expect(far.resolvedPagePoint.isFinite)
    }

    @Test("Extreme coordinate magnitudes never produce a non-finite bound or score")
    func extremeMagnitudes() throws {
        let page = try SnapScene.letterPage()
        var primitives: [SnapPrimitive] = []
        var id: UInt64 = 1
        for a in Self.hostileMagnitudes {
            for b in Self.hostileMagnitudes {
                primitives.append(
                    SnapScene.segment(id: id, PDFPoint(x: a, y: b), PDFPoint(x: b, y: a))
                )
                id += 1
            }
        }
        let scene = try SnapScene.withVectorContent(page: page, primitives: primitives)
        for entry in scene.index.allEntries(in: .vector) {
            #expect(entry.bounds.isFinite)
        }

        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        for point in [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 612, y: 792),
            PDFPoint(x: 1e-300, y: 1e-300), PDFPoint(x: 306, y: 396)
        ] {
            let resolution = try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: try SnapReplay.viewPoint(point, page: page, layout: layout),
                        layout: layout
                    )
                ),
                in: scene.index
            )
            #expect(resolution.resolvedPagePoint.isFinite)
            #expect(resolution.winner?.score.isFinite ?? true)
        }
    }

    @Test("A markup with an absurd vertex count is refused by a typed error, not indexed")
    func hostileMarkupIsBounded() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withoutVectorContent(page: page).index
        let limits = SnapIndexLimits.standard
        let vertices = (0...limits.maximumRingVertices + 1).map {
            PDFPoint(x: Double($0 % 600), y: Double($0 % 700))
        }
        #expect(throws: SnapEngineError.self) {
            try index.upsert(
                markup: SnapMarkupGeometry(
                    id: MarkupID(
                        UUID(uuidString: "00000000-0000-4000-8000-0000000000FF") ?? UUID()
                    ),
                    geometry: [.polyline(points: vertices, isClosed: true)],
                    layerID: nil
                )
            )
        }
        #expect(index.markupPrimitiveCount == 0)
    }

    @Test("Hostile PDF fixtures either extract or fail with a typed error; neither crashes")
    func hostileFixturesDoNotCrash() async throws {
        let hostile: [FixtureKind] = [
            .hugeMalformedOperatorStream,
            .deeplyNestedForms,
            .clippedContent,
            .tenThousandSegments
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-snap-fuzz", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for kind in hostile {
            let handle = try ZPDFFixtures.make(kind, in: directory)
            let extractor = VectorExtractor()
            do {
                let extraction = try await extractor.extract(documentAt: handle.url, pageIndex: 0)
                let page = try SnapScene.letterPage(
                    media: PDFRect(
                        x: handle.manifest.pages[0].mediaBox.llx,
                        y: handle.manifest.pages[0].mediaBox.lly,
                        width: handle.manifest.pages[0].mediaBox.urx
                            - handle.manifest.pages[0].mediaBox.llx,
                        height: handle.manifest.pages[0].mediaBox.ury
                            - handle.manifest.pages[0].mediaBox.lly
                    )
                )
                let index = try SnapIndexBuilder().build(page: page, extraction: extraction)

                // Whatever came out, every bound is finite and the index answers queries.
                for entry in index.allEntries(in: .vector) {
                    #expect(entry.bounds.isFinite)
                    #expect(entry.primitive.isConsistent)
                }

                var engine = SnapEngine()
                let layout = SnapReplay.layout(zoom: 1)
                var random = SnapDeterministicRandom(seed: "hostile-\(kind.rawValue)")
                for _ in 0..<40 {
                    let cursor = PDFPoint(
                        x: random.nextUnitDouble() * 612,
                        y: random.nextUnitDouble() * 792
                    )
                    let resolution = try engine.resolve(
                        SnapQuery(
                            event: SnapPointerEvent(
                                viewPoint: try SnapReplay.viewPoint(
                                    cursor, page: page, layout: layout
                                ),
                                layout: layout
                            )
                        ),
                        in: index
                    )
                    #expect(resolution.resolvedPagePoint.isFinite)
                }
            } catch let error as VectorExtractionError {
                // A typed refusal is a pass: the contract is "a result or a typed error".
                _ = error
            }
        }
    }

    // MARK: - Generators

    static func randomPrimitive(
        id: UInt64, using random: inout SnapDeterministicRandom
    ) -> SnapPrimitive {
        func coordinate() -> Double {
            let choice = random.nextInt(below: 10)
            if choice == 0 { return 0 }
            if choice == 1 { return 1e-300 }
            if choice == 2 { return -50 }
            if choice == 3 { return 1e6 }
            return random.nextUnitDouble() * 612
        }
        func point() -> PDFPoint { PDFPoint(x: coordinate(), y: coordinate()) }

        switch random.nextInt(below: 5) {
        case 0:
            return SnapScene.point(id: id, point())
        case 1:
            // Deliberately allowed to be degenerate: start == end.
            return SnapScene.segment(id: id, point(), random.nextInt(below: 4) == 0
                ? PDFPoint(x: 0, y: 0)
                : point())
        case 2:
            let centre = point()
            let radius = [0.0, 1e-300, 1.0, 1e6][random.nextInt(below: 4)]
            return SnapScene.circle(id: id, center: centre, radius: radius)
        case 3:
            let vertices = (0...(2 + random.nextInt(below: 8))).map { _ in point() }
            return SnapScene.polyline(id: id, vertices, isClosed: random.nextInt(below: 2) == 0)
                ?? SnapScene.point(id: id, point())
        default:
            return SnapScene.cubic(id: id, point(), point(), point(), point())
                ?? SnapScene.point(id: id, point())
        }
    }
}
