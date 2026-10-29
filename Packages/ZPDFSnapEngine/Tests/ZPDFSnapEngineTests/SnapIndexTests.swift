import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFVectorExtraction

/// The index: incremental markup and boundary updates, availability honesty, the vector-layer
/// cache, and the typed refusals.
@Suite("Snap index")
struct SnapIndexTests {

    static func markup(_ suffix: String, at points: [PDFPoint]) -> SnapMarkupGeometry {
        SnapMarkupGeometry(
            id: MarkupID(
                UUID(uuidString: "00000000-0000-4000-8000-0000000000\(suffix)") ?? UUID()
            ),
            geometry: [.polyline(points: points, isClosed: false)],
            layerID: "takeoff"
        )
    }


    /// A statistics block for a hand-built extraction. Every field is zero except the ones the
    /// test actually sets, because nothing in the snap engine reads them.
    static func statistics(primitiveCount: Int) -> VectorExtractionStatistics {
        VectorExtractionStatistics(
            operatorCount: 0,
            primitiveCount: primitiveCount,
            filteredCount: 0,
            paintedPathCount: 0,
            subpathCount: 0,
            formInvocationCount: 0,
            maximumNestingDepthReached: 0,
            rasterRegionCount: 0,
            inlineImageCount: 0,
            malformedOperandCount: 0,
            contentBytesCompleted: 0,
            contentBytesEntered: 0,
            elapsedNanoseconds: 0,
            estimatedMemoryBytes: 0
        )
    }

    static func lineSegment(_ i: Int) -> VectorPrimitive {
        let x = Double(i)
        let bounds = VectorBounds(minX: x, minY: 0, maxX: x + 1, maxY: 1)
        let line = VectorLine(start: CGPoint(x: x, y: 0), end: CGPoint(x: x + 1, y: 1))
        return VectorPrimitive(
            id: UInt64(i + 1),
            parentID: nil,
            kind: .lineSegment,
            geometry: .line(line),
            bounds: bounds,
            sourceObjectID: UInt64(i + 1),
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

    static func extraction(
        digest: String = "sha",
        page: Int = 0,
        version: Int = 1,
        primitives: [VectorPrimitive] = [],
        availability: VectorAvailability = .available
    ) -> VectorPageExtraction {
        VectorPageExtraction(
            cacheKey: VectorCacheKey(
                documentDigest: digest,
                pageIndex: page,
                extractorVersion: version,
                configurationFingerprint: 0
            ),
            availability: availability,
            partialReasons: [],
            primitives: primitives,
            rasterRegions: [],
            filterDecisions: [],
            pageTransform: VectorPageTransform(
                convention: .pdfUserSpace,
                mediaBox: VectorBounds(minX: 0, minY: 0, maxX: 612, maxY: 792),
                cropBox: VectorBounds(minX: 0, minY: 0, maxX: 612, maxY: 792),
                rotation: 0
            ),
            statistics: statistics(primitiveCount: primitives.count)
        )
    }

    static func vectorScene() throws -> SnapScene {
        let page = try SnapScene.letterPage()
        let primitives = (0..<200).map { i in
            SnapScene.segment(
                id: UInt64(1000 + i),
                PDFPoint(x: Double(i) * 3, y: 100),
                PDFPoint(x: Double(i) * 3 + 2, y: 100)
            )
        }
        return try SnapScene.withVectorContent(page: page, primitives: primitives)
    }

    @Test("Adding, moving and removing a markup never touches the vector layer")
    func markupUpdatesAreIncremental() throws {
        let scene = try Self.vectorScene()
        var index = scene.index
        let vectorBefore = index.allEntries(in: .vector)
        #expect(vectorBefore.count == 200)

        let first = Self.markup("11", at: [PDFPoint(x: 300, y: 300), PDFPoint(x: 360, y: 300)])
        try index.upsert(markup: first)
        #expect(index.markupPrimitiveCount == 1)
        #expect(index.allEntries(in: .vector) == vectorBefore)

        // A move is an upsert with new geometry: the entry count is unchanged, the position is
        // not, and the vector layer is byte-identical.
        let moved = SnapMarkupGeometry(
            id: first.id,
            geometry: [.polyline(points: [PDFPoint(x: 320, y: 320), PDFPoint(x: 380, y: 320)],
                                 isClosed: false)],
            layerID: first.layerID
        )
        try index.upsert(markup: moved)
        #expect(index.markupPrimitiveCount == 1)
        #expect(index.allEntries(in: .vector) == vectorBefore)
        let entry = try #require(index.allEntries(in: .markup).first)
        #expect(entry.bounds.minY == 320)

        try index.remove(markupID: first.id)
        #expect(index.markupPrimitiveCount == 0)
        #expect(index.allEntries(in: .vector) == vectorBefore)
    }

    @Test("A moved markup is findable at its new position and not at its old one")
    func movedMarkupIsQueryable() throws {
        let page = try SnapScene.letterPage()
        var scene = try SnapScene.withoutVectorContent(page: page)
        var index = scene.index
        let markup = Self.markup("12", at: [PDFPoint(x: 200, y: 200), PDFPoint(x: 240, y: 200)])
        try index.upsert(markup: markup)

        var settings = SnapSettings.default
        settings.enabledKinds = [.markupVertex]
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)

        func winner(at point: PDFPoint) throws -> SnapCandidate? {
            try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: try SnapReplay.viewPoint(point, page: page, layout: layout),
                        layout: layout
                    ),
                    settings: settings
                ),
                in: index
            ).winner
        }

        #expect(try winner(at: PDFPoint(x: 201, y: 201)) != nil)
        engine.reset()

        try index.upsert(
            markup: SnapMarkupGeometry(
                id: markup.id,
                geometry: [.polyline(points: [PDFPoint(x: 400, y: 400), PDFPoint(x: 440, y: 400)],
                                     isClosed: false)],
                layerID: markup.layerID
            )
        )
        #expect(try winner(at: PDFPoint(x: 201, y: 201)) == nil)
        engine.reset()
        #expect(try winner(at: PDFPoint(x: 401, y: 401)) != nil)
        scene = SnapScene(page: page, index: index)
        #expect(scene.index.markupPrimitiveCount == 1)
    }

    @Test("Hundreds of markup updates compact without changing the answer")
    func compactionPreservesAnswers() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withoutVectorContent(page: page).index

        // More upserts than the layer's pending threshold, so at least one compaction happens.
        for i in 0..<400 {
            let suffix = String(format: "%02X", i % 256)
            try index.upsert(
                markup: SnapMarkupGeometry(
                    id: MarkupID(
                        UUID(uuidString: "00000000-0000-4000-8000-00000000\(suffix)\(String(format: "%02X", i / 256))")
                            ?? UUID()
                    ),
                    geometry: [.point(PDFPoint(x: Double(i % 500) + 50, y: 600))],
                    layerID: nil
                )
            )
        }
        #expect(index.markupPrimitiveCount == 400)

        // Every entry is still reachable through the tree, and identifiers are unique.
        let entries = index.allEntries(in: .markup)
        #expect(entries.count == 400)
        #expect(Set(entries.map(\.id)).count == 400)

        var found = 0
        for entry in entries {
            let hits = index.entries(intersecting: entry.bounds.insetBy(0.5))
            if hits.contains(where: { $0.id == entry.id }) { found += 1 }
        }
        #expect(found == 400)
    }

    @Test("Boundaries are their own layer and update independently")
    func boundaryUpdates() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withoutVectorContent(page: page).index
        try index.upsert(
            boundary: SnapBoundary(
                id: "zone-a",
                category: .zone,
                geometry: [
                    .polyline(
                        points: [
                            PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100),
                            PDFPoint(x: 200, y: 200)
                        ],
                        isClosed: true
                    )
                ]
            )
        )
        #expect(index.boundaryPrimitiveCount == 1)
        let entry = try #require(index.allEntries(in: .boundary).first)
        #expect(entry.source == .zoneBoundary)
        #expect(entry.kindSet.vertex == .zoneBoundary)

        index.remove(boundaryID: "zone-a")
        #expect(index.boundaryPrimitiveCount == 0)
    }

    @Test("A calibration point outranks everything except an explicit markup vertex")
    func calibrationPriority() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withVectorContent(
            page: page,
            primitives: [SnapScene.point(id: 1, PDFPoint(x: 200, y: 200))]
        ).index
        try index.upsert(
            boundary: SnapBoundary(
                id: "cal-1",
                category: .calibrationPoint,
                geometry: [.point(PDFPoint(x: 202, y: 200))]
            )
        )

        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        let resolution = try engine.resolve(
            SnapQuery(
                event: SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(
                        PDFPoint(x: 201, y: 200), page: page, layout: layout
                    ),
                    layout: layout
                )
            ),
            in: index
        )
        // Endpoint is priority 3, calibration point is priority 1: three units of score against
        // one page point of distance, which is worth half a unit. Calibration wins.
        #expect(resolution.winner?.kind == .calibrationPoint)
    }

    // MARK: - Availability

    @Test("A page with no vector content reports unavailable(.noVectorContent)")
    func scannedPageAvailability() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withoutVectorContent(page: page)
        #expect(scene.index.availability == .unavailable(.noVectorContent))
        #expect(!scene.index.availability.allowsVectorCandidates)
        #expect(scene.index.availability.messageKey == "snap.vector.unavailable.noVectorContent")
    }

    @Test("Grid and markup snap keep working on a page with no vector content")
    func scannedPageStillSnaps() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withoutVectorContent(page: page).index
        try index.upsert(
            markup: Self.markup("21", at: [PDFPoint(x: 300, y: 300), PDFPoint(x: 340, y: 300)])
        )

        var settings = SnapSettings.default
        settings.gridSpacingPoints = 50
        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)

        func resolve(_ point: PDFPoint) throws -> SnapResolution {
            engine.reset()
            return try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: try SnapReplay.viewPoint(point, page: page, layout: layout),
                        layout: layout
                    ),
                    settings: settings
                ),
                in: index
            )
        }

        let atMarkup = try resolve(PDFPoint(x: 302, y: 301))
        #expect(atMarkup.winner?.kind == .markupVertex)

        let atGrid = try resolve(PDFPoint(x: 148, y: 452))
        #expect(atGrid.winner?.kind == .grid)
        #expect(atGrid.winner?.position == PDFPoint(x: 150, y: 450))
    }

    @Test("No vector candidate is ever emitted for a page reported unavailable")
    func noVectorCandidateOnScannedPage() throws {
        let page = try SnapScene.letterPage()
        // Vector entries are installed and then the availability is set to unavailable, which
        // is the adversarial case S14 is really about: geometry present, availability says no.
        var index = try SnapScene.withVectorContent(
            page: page,
            primitives: (0..<40).map {
                SnapScene.point(id: UInt64(1 + $0), PDFPoint(x: 200 + Double($0), y: 300))
            }
        ).index
        try index.installVectorEntries(
            index.allEntries(in: .vector),
            availability: .unavailable(.onlyFilteredGeometry(filteredCount: 40))
        )

        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 1)
        for x in stride(from: 195.0, through: 245.0, by: 0.5) {
            let resolution = try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: try SnapReplay.viewPoint(
                            PDFPoint(x: x, y: 300), page: page, layout: layout
                        ),
                        layout: layout
                    )
                ),
                in: index
            )
            let emitted = ([resolution.winner].compactMap { $0 } + resolution.alternatives)
            #expect(emitted.allSatisfy { !$0.kind.requiresVectorContent })
        }
    }

    @Test("A building index is usable and reports itself as building")
    func buildingState() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapIndexBuilder().build(
            page: page,
            extraction: nil,
            availability: .building,
            markups: [Self.markup("31", at: [PDFPoint(x: 200, y: 200), PDFPoint(x: 260, y: 200)])]
        )
        #expect(index.availability == .building)
        #expect(!index.availability.allowsVectorCandidates)
        #expect(index.markupPrimitiveCount == 1)

        try index.installVectorEntries(
            [
                SnapIndexEntry(
                    primitive: SnapScene.point(id: 1, PDFPoint(x: 400, y: 400)),
                    source: .pdfPathObject,
                    ownerID: nil,
                    kindSet: .pdfVector
                )
            ],
            availability: .available
        )
        #expect(index.availability == .available)
        #expect(index.availability.allowsVectorCandidates)
    }

    @Test("An extraction that yields nothing bridgeable is not reported as available")
    func emptyExtractionIsNotAvailable() throws {
        let page = try SnapScene.letterPage()
        let index = try SnapIndexBuilder().build(page: page, extraction: Self.extraction())
        #expect(index.availability == SnapIndexAvailability.unavailable(.noVectorContent))
    }

    // MARK: - Hidden layers on every build path (CR-44)

    static func layered(_ id: UInt64, x: Double, layerID: String?) -> VectorPrimitive {
        VectorPrimitive(
            id: id, parentID: nil, kind: .lineSegment,
            geometry: .line(VectorLine(start: CGPoint(x: x, y: 100), end: CGPoint(x: x + 50, y: 100))),
            bounds: VectorBounds(minX: x, minY: 100, maxX: x + 50, maxY: 100),
            sourceObjectID: id, subpathIndex: 0, nestingDepth: 0, paint: .stroked, strokeWidth: 1,
            strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: layerID
        )
    }

    // MARK: - Identifier collisions across owners (CR-49)

    static func owned(_ ownerID: String, id: UInt64, x: Double) -> SnapIndexEntry {
        let point = PDFPoint(x: x, y: 100)
        return SnapIndexEntry(
            primitive: SnapPrimitive(
                id: id, bounds: PDFRect(origin: point, size: .zero), kind: .point, geometry: .point(point),
                sourceObjectID: nil, confidence: 1, layerID: nil
            ),
            source: .zenitMarkup, ownerID: ownerID, kindSet: .zenitMarkup
        )
    }

    @Test("Two owners whose entries share an identifier never hide each other (CR-49)")
    func collidingIdentifiersAcrossOwners() throws {
        let shared: UInt64 = 0x4d41_524b_0000_0001
        var layer = try SnapLayer(entries: [Self.owned("A", id: shared, x: 100)])
        layer.upsert(ownerID: "B", entries: [Self.owned("B", id: shared, x: 200)])
        #expect(layer.count == 2)
        let bID = try #require(layer.allEntries.first { $0.ownerID == "B" }?.id)
        #expect(bID != shared, "B's entry is given the next free identifier")

        layer.compact()
        layer.removeOwner("A")
        // Old output: after the compaction both entries sat in `committed` under the same
        // identifier; the tombstone for A hid B as well — `allEntries` was empty and a query
        // at x = 200 found nothing.
        #expect(layer.allEntries.map(\.ownerID) == ["B"])
        var hits: [SnapIndexEntry] = []
        layer.query(PDFRect(x: 190, y: 90, width: 20, height: 20), into: &hits)
        #expect(hits.map(\.ownerID) == ["B"])

        // A second compaction keeps B; and re-upserting B keeps its identifier.
        layer.compact()
        #expect(layer.allEntries.map(\.ownerID) == ["B"])
        layer.upsert(ownerID: "B", entries: [Self.owned("B", id: shared, x: 210)])
        #expect(layer.allEntries.map(\.id) == [shared], "the tombstoned identifier is free again for its owner")
    }

    @Test("Two markups whose content hashes collide stay independently snappable (CR-49)")
    func collidingMarkupIdentifiers() throws {
        // Markup identifiers are 32-bit content hashes of the owner's UUID string, so a
        // collision is a birthday problem: a few dozen pairs among 600 000 UUIDs. The UUIDs
        // come from a fixed linear congruential generator — sequential ones differ only in
        // their last characters, which FNV-1a's low word keeps apart — and FNV-1a is fixed,
        // so the pair found here is the same in every run.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextUUID() -> UUID {
            var bytes: [UInt8] = []
            for _ in 0..<2 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                var word = seed
                for _ in 0..<8 {
                    bytes.append(UInt8(truncatingIfNeeded: word))
                    word >>= 8
                }
            }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        var seen: [UInt64: UUID] = [:]
        var pair: (UUID, UUID)?
        for _ in 0..<600_000 {
            let uuid = nextUUID()
            let id = SnapIdentifier.make(domain: .markup, ownerID: uuid.uuidString, component: 0)
            if let other = seen[id] {
                pair = (other, uuid)
                break
            }
            seen[id] = uuid
        }
        let (first, second) = try #require(pair, "no collision among 600 000 owners" as Comment)

        func markup(_ uuid: UUID, at x: Double) -> SnapMarkupGeometry {
            SnapMarkupGeometry(id: MarkupID(uuid), geometry: [.point(PDFPoint(x: x, y: 300))], layerID: nil)
        }
        let page = try SnapScene.letterPage()
        // Both routes a colliding pair takes into the markup layer: the second one upserted into
        // the pending buffer, and both committed together (what a compaction leaves; the forced
        // `compactMutableLayers` it used to call had no production caller and was deleted, T-076 —
        // the layer-level compaction is `collidingIdentifiersAcrossOwners`).
        let pendingRoute: SnapIndex = try {
            var index = try SnapIndexBuilder().build(page: page, extraction: nil, markups: [markup(first, at: 100)])
            try index.upsert(markup: markup(second, at: 200))
            return index
        }()
        let committedRoute = try SnapIndexBuilder().build(
            page: page, extraction: nil, markups: [markup(first, at: 100), markup(second, at: 200)]
        )
        for var index in [pendingRoute, committedRoute] {
            index.remove(markupID: MarkupID(first))

            // Old output: the second markup vanished with the first — no entry, no candidate.
            #expect(index.markupPrimitiveCount == 1)
            #expect(index.allEntries(in: .markup).map(\.ownerID) == [second.uuidString])
            let resolution = try SnapShapeCandidateTests.resolve(index, page: page, at: PDFPoint(x: 201, y: 301))
            #expect(resolution.winner?.kind == .markupVertex)
            #expect(resolution.winner?.position == PDFPoint(x: 200, y: 300))
        }
    }

    // MARK: - Refusals

    @Test("Invalid settings and non-finite input produce typed errors, never a trap")
    func typedRefusals() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withoutVectorContent(page: page)
        var engine = SnapEngine()

        var bad = SnapSettings.default
        bad.minimumPixels = 0
        #expect(throws: SnapEngineError.self) {
            _ = try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: .zero, layout: SnapReplay.layout(zoom: 1)
                    ),
                    settings: bad
                ),
                in: scene.index
            )
        }

        #expect(throws: SnapEngineError.self) {
            _ = try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: CGPoint(x: Double.nan, y: 0),
                        layout: SnapReplay.layout(zoom: 1)
                    )
                ),
                in: scene.index
            )
        }

        var badWeights = SnapScoringWeights.standard
        badWeights.screenDistancePerViewPoint = 0
        #expect(throws: SnapEngineError.self) {
            _ = try engine.resolve(
                SnapQuery(
                    event: SnapPointerEvent(
                        viewPoint: .zero, layout: SnapReplay.layout(zoom: 1)
                    ),
                    weights: badWeights
                ),
                in: scene.index
            )
        }
    }

    @Test("A primitive whose kind disagrees with its geometry is rejected, not snapped to")
    func inconsistentPrimitiveRejected() throws {
        let page = try SnapScene.letterPage()
        var index = try SnapScene.withoutVectorContent(page: page).index
        let inconsistent = SnapPrimitive(
            id: 1,
            bounds: PDFRect(x: 0, y: 0, width: 1, height: 1),
            kind: .circle,
            geometry: .point(PDFPoint(x: 0, y: 0)),
            sourceObjectID: nil,
            confidence: 1,
            layerID: nil
        )
        #expect(throws: SnapEngineError.self) {
            try index.installVectorEntries([
                SnapIndexEntry(
                    primitive: inconsistent, source: .pdfPathObject,
                    ownerID: nil, kindSet: .pdfVector
                )
            ])
        }
    }

    @Test("An index build is cancellable")
    func buildIsCancellable() throws {
        let page = try SnapScene.letterPage()
        let primitives = (0..<5000).map(Self.lineSegment)
        let extraction = Self.extraction(primitives: primitives)

        #expect(throws: SnapEngineError.cancelled) {
            _ = try SnapIndexBuilder().build(
                page: page,
                extraction: extraction,
                cancellation: SnapCancellation(checkInterval: 16) { true }
            )
        }

        // The same build with no cancellation completes.
        let index = try SnapIndexBuilder().build(page: page, extraction: extraction)
        #expect(index.vectorPrimitiveCount == 5000)
    }
}
