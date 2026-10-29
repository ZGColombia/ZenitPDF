import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// S23's snap half, proven at the engine seam: a primitive on a hidden layer must not be a
/// snap candidate. The renderer half (not drawn) is policed by the extraction filter tests;
/// this suite polices "not snappable" where snapping is actually decided — the index.
@Suite("Hidden layers are not snappable")
struct SnapLayerVisibilityTests {

    private static func primitive(_ id: UInt64, x: Double, layerID: String?) -> VectorPrimitive {
        VectorPrimitive(
            id: id,
            parentID: nil,
            kind: .lineSegment,
            geometry: .line(VectorLine(start: CGPoint(x: x, y: 100), end: CGPoint(x: x + 50, y: 100))),
            bounds: VectorBounds(minX: x, minY: 100, maxX: x + 50, maxY: 100),
            sourceObjectID: id,
            subpathIndex: 0,
            nestingDepth: 0,
            paint: .stroked,
            strokeWidth: 1,
            strokeIsDashed: false,
            clipRelation: .unclipped,
            clipBounds: nil,
            confidence: 1,
            layerID: layerID
        )
    }

    private static func page() throws -> PageDescriptor {
        let box = PDFRect(x: 0, y: 0, width: 612, height: 792)
        return PageDescriptor(
            id: PageID(UUID(uuidString: "00000000-0000-4000-8000-00000000AA01")!),
            documentID: DocumentID(UUID(uuidString: "00000000-0000-4000-8000-00000000AA02")!),
            index: 0,
            label: "1",
            boxes: PageBoxes(media: box, crop: box)
        )
    }

    @Test("A hidden layer's primitives are absent from the vector layer; visible and unlayered stay")
    func hiddenLayerIsExcluded() throws {
        let primitives = [
            Self.primitive(1, x: 100, layerID: "Grid"),
            Self.primitive(2, x: 200, layerID: "Walls"),
            Self.primitive(3, x: 300, layerID: nil)
        ]
        let extraction = SnapIndexTests.extraction(primitives: primitives)
        let builder = SnapIndexBuilder()

        // Non-vacuity: with nothing hidden, all three are snappable.
        let unfiltered = try builder.build(page: try Self.page(), extraction: extraction)
        let allLayerIDs = unfiltered.allEntries(in: .vector).map(\.primitive.layerID)
        #expect(allLayerIDs.contains("Grid"))
        #expect(allLayerIDs.contains("Walls"))
        #expect(allLayerIDs.contains(nil))

        // Hide Grid: its primitive disappears from the snap candidates; nothing else moves.
        let filtered = try builder.build(
            page: try Self.page(),
            extraction: extraction,
            hiddenLayerIDs: ["Grid"]
        )
        let entries = filtered.allEntries(in: .vector)
        #expect(entries.count == 2)
        #expect(!entries.contains { $0.primitive.layerID == "Grid" })
        #expect(entries.contains { $0.primitive.layerID == "Walls" })
        #expect(entries.contains { $0.primitive.layerID == nil }, "unlayered content is never filtered")
    }

    @Test("Hiding every layered primitive downgrades availability rather than lying")
    func allHiddenIsHonest() throws {
        let primitives = [
            Self.primitive(1, x: 100, layerID: "Grid"),
            Self.primitive(2, x: 200, layerID: "Grid")
        ]
        let extraction = SnapIndexTests.extraction(primitives: primitives)
        let index = try SnapIndexBuilder().build(
            page: try Self.page(),
            extraction: extraction,
            hiddenLayerIDs: ["Grid"]
        )
        #expect(index.allEntries(in: .vector).isEmpty)
        #expect(!index.availability.allowsVectorCandidates,
                "an index with zero snappable entries must not report Vector Snap on")
    }
}
