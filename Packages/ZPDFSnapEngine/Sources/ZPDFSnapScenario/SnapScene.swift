import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine

/// A page and an index, built from geometry written out in the test itself rather than parsed
/// from a PDF.
///
/// Fixture-driven tests answer "does the engine agree with the corpus"; scene-driven tests answer
/// "does the engine agree with a closed form". Both are needed, and only the second can be run
/// from a standalone process with no file system, which is what the 20-process determinism run
/// of `QUALITY_BAR` 3.4 requires.
public struct SnapScene: Sendable {

    public let page: PageDescriptor
    public let index: SnapIndex

    public init(page: PageDescriptor, index: SnapIndex) {
        self.page = page
        self.index = index
    }

    /// A Letter page with a fixed identity, so two processes describe the same page.
    ///
    /// The identifiers are constant UUIDs, not `UUID()`: a freshly minted identifier would make
    /// every run's decision log different for a reason that has nothing to do with snapping.
    public static func letterPage(
        rotation: PageRotation = .degrees0,
        media: PDFRect = PDFRect(x: 0, y: 0, width: 612, height: 792),
        crop: PDFRect? = nil
    ) throws -> PageDescriptor {
        let documentID = DocumentID(
            UUID(uuidString: "00000000-0000-4000-8000-00000000D0C1") ?? UUID()
        )
        let pageID = PageID(
            UUID(uuidString: "00000000-0000-4000-8000-0000000000A1") ?? UUID()
        )
        return PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(media: media, crop: crop ?? media),
            rotation: rotation
        )
    }

    /// A scene whose only geometry is a set of boundaries and markups: no vector layer, so
    /// `availability` is `unavailable(.noVectorContent)` exactly as a scanned page reports.
    public static func withoutVectorContent(
        page: PageDescriptor,
        markups: [SnapMarkupGeometry] = [],
        boundaries: [SnapBoundary] = []
    ) throws -> SnapScene {
        let index = try SnapIndexBuilder().build(
            page: page,
            extraction: nil,
            availability: .unavailable(.noVectorContent),
            markups: markups,
            boundaries: boundaries
        )
        return SnapScene(page: page, index: index)
    }

    /// A scene with a synthetic vector layer: the geometry is handed in directly, standing in
    /// for what `ZPDFVectorExtraction` would have produced.
    public static func withVectorContent(
        page: PageDescriptor,
        primitives: [SnapPrimitive],
        markups: [SnapMarkupGeometry] = [],
        boundaries: [SnapBoundary] = [],
        limits: SnapIndexLimits = .standard
    ) throws -> SnapScene {
        var index = try SnapIndexBuilder(limits: limits).build(
            page: page,
            extraction: nil,
            availability: primitives.isEmpty
                ? .unavailable(.noVectorContent)
                : .available,
            markups: markups,
            boundaries: boundaries
        )
        try index.installSyntheticVectorPrimitives(primitives)
        return SnapScene(page: page, index: index)
    }

    /// A primitive from a segment, with an identifier the caller controls.
    public static func segment(
        id: UInt64,
        _ start: PDFPoint,
        _ end: PDFPoint,
        confidence: Float = 1.0,
        layerID: String? = nil
    ) -> SnapPrimitive {
        let geometry = PrimitiveGeometry.segment(SegmentGeometry(start: start, end: end))
        return SnapPrimitive(
            id: id,
            bounds: PDFRect(corner: start, opposite: end),
            kind: .segment,
            geometry: geometry,
            sourceObjectID: id,
            confidence: confidence,
            layerID: layerID
        )
    }

    public static func polyline(
        id: UInt64,
        _ points: [PDFPoint],
        isClosed: Bool,
        confidence: Float = 1.0,
        layerID: String? = nil
    ) -> SnapPrimitive? {
        guard let bounds = PDFRect.boundingBox(of: points) else { return nil }
        return SnapPrimitive(
            id: id,
            bounds: bounds,
            kind: .polyline,
            geometry: .polyline(points: points, isClosed: isClosed),
            sourceObjectID: id,
            confidence: confidence,
            layerID: layerID
        )
    }

    public static func circle(
        id: UInt64,
        center: PDFPoint,
        radius: Double,
        confidence: Float = 1.0,
        layerID: String? = nil
    ) -> SnapPrimitive {
        let geometry = CircleGeometry(center: center, radius: radius)
        return SnapPrimitive(
            id: id,
            bounds: geometry.bounds,
            kind: .circle,
            geometry: .circle(geometry),
            sourceObjectID: id,
            confidence: confidence,
            layerID: layerID
        )
    }

    public static func cubic(
        id: UInt64,
        _ p0: PDFPoint, _ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint,
        confidence: Float = 1.0,
        layerID: String? = nil
    ) -> SnapPrimitive? {
        guard let bounds = PDFRect.boundingBox(of: [p0, p1, p2, p3]) else { return nil }
        return SnapPrimitive(
            id: id,
            bounds: bounds,
            kind: .cubicCurve,
            geometry: .cubicCurve(start: p0, control1: p1, control2: p2, end: p3),
            sourceObjectID: id,
            confidence: confidence,
            layerID: layerID
        )
    }
}

extension SnapIndex {
    /// Installs synthetic primitives as the vector layer, for tests and the determinism driver.
    ///
    /// This lives in the scenario target rather than the engine so that a shipping build has no
    /// way to put geometry into the vector layer that did not come from the extractor.
    public mutating func installSyntheticVectorPrimitives(_ primitives: [SnapPrimitive]) throws {
        let entries = primitives.map {
            SnapIndexEntry(
                primitive: $0,
                source: .pdfPathObject,
                ownerID: nil,
                kindSet: $0.kind == .polyline || $0.kind == .rectangle
                    ? .pdfVectorShape
                    : .pdfVector
            )
        }
        try installVectorEntries(entries)
    }
}
