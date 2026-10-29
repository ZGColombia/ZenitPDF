import CoreGraphics
import Foundation
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// One axis-aligned stroked edge, with the exact rectangle of paper it inks.
///
/// Every coordinate is an even integer and every stroke width is an even integer, which
/// is not decoration: at any integer render scale the painted ribbon then lands on whole
/// pixel boundaries, so there is no antialiasing anywhere and the difference regions
/// have exact, closed-form bounds a test can assert on rather than approximate.
struct RevisionEdge: Sendable, Hashable {
    let identifier: String
    let x0: Double
    let y0: Double
    let x1: Double
    let y1: Double
    let width: Double

    init(_ identifier: String, from start: (Double, Double), to end: (Double, Double), width: Double = 4) {
        self.identifier = identifier
        self.x0 = start.0
        self.y0 = start.1
        self.x1 = end.0
        self.y1 = end.1
        self.width = width
    }

    var isHorizontal: Bool { y0 == y1 }

    /// The exact page-space rectangle the butt-capped stroke covers.
    var inkRect: CGRect {
        let half = width / 2
        if isHorizontal {
            let minX = Swift.min(x0, x1)
            let maxX = Swift.max(x0, x1)
            return CGRect(x: minX, y: y0 - half, width: maxX - minX, height: width)
        } else {
            let minY = Swift.min(y0, y1)
            let maxY = Swift.max(y0, y1)
            return CGRect(x: x0 - half, y: minY, width: width, height: maxY - minY)
        }
    }

    func translated(dx: Double, dy: Double, identifier: String? = nil) -> RevisionEdge {
        RevisionEdge(
            identifier ?? self.identifier,
            from: (x0 + dx, y0 + dy),
            to: (x1 + dx, y1 + dy),
            width: width
        )
    }
}

/// A one-page PDF written byte by byte from a list of edges.
///
/// `ZPDFTestingSupport` keeps its writer internal, and a revision *variant* is not a
/// fixture — it is a derivative built for one test from a fixture's manifest. This
/// writer exists so the derivation is explicit and the bytes are boring: no compression,
/// no fonts, no resources, one uncompressed content stream.
enum RevisionPDFWriter {

    static func data(mediaBox: FixtureRect, edges: [RevisionEdge], rotation: Int = 0) -> Data {
        var content = ""
        for edge in edges {
            content += "\(number(edge.width)) w\n"
            content += "0 G\n"
            content += "\(number(edge.x0)) \(number(edge.y0)) m\n"
            content += "\(number(edge.x1)) \(number(edge.y1)) l\n"
            content += "S\n"
        }
        return data(mediaBox: mediaBox, content: content, rotation: rotation)
    }

    /// The same file around a caller's own content stream, for geometry the edge list
    /// cannot say — a `re` rectangle, a closed `h` polyline.
    static func data(mediaBox: FixtureRect, content: String, rotation: Int = 0) -> Data {
        let contentBytes = Array(content.utf8)

        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        let box = "[\(number(mediaBox.llx)) \(number(mediaBox.lly)) "
            + "\(number(mediaBox.urx)) \(number(mediaBox.ury))]"
        let rotationEntry = rotation == 0 ? "" : " /Rotate \(rotation)"
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox \(box)\(rotationEntry) "
                + "/Resources << >> /Contents 4 0 R >>"
        )

        var bytes = Array("%PDF-1.7\n".utf8)
        // The binary-marker comment must be raw high bytes, not their UTF-8 encoding.
        bytes.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(contentsOf: Array("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        offsets.append(bytes.count)
        bytes.append(contentsOf: Array("4 0 obj\n<< /Length \(contentBytes.count) >>\nstream\n".utf8))
        bytes.append(contentsOf: contentBytes)
        bytes.append(contentsOf: Array("\nendstream\nendobj\n".utf8))

        let xrefOffset = bytes.count
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        bytes.append(contentsOf: Array(xref.utf8))
        return Data(bytes)
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.6f", value)
    }
}

/// A baseline sheet and a revision of it, derived from a fixture in the corpus.
struct RevisionPair: Sendable {
    let mediaBox: FixtureRect
    let baselineEdges: [RevisionEdge]
    let revisedEdges: [RevisionEdge]
    let baselineURL: URL
    let revisedURL: URL
    let directory: URL

    func edge(_ identifier: String, inBaseline: Bool = true) -> RevisionEdge? {
        (inBaseline ? baselineEdges : revisedEdges).first { $0.identifier == identifier }
    }
}

/// Builds revision pairs out of the `geo-l-shape` fixture's manifest.
///
/// The base drawing is the fixture's own six-vertex ring, on the fixture's own page,
/// with each edge shortened by ``cornerInset`` at both ends so the six edges are
/// disjoint. Disjointness is what makes the expected difference regions exact: a change
/// to one edge cannot borrow or lose pixels from a neighbour, so the region a test
/// predicts is the region the engine must find, to the pixel.
enum RevisionCorpus {

    /// How much is trimmed from each end of each fixture edge. 16 pt leaves a 14 pt gap
    /// between the ink of two adjacent edges — wide enough that the grouping dilation
    /// cannot bridge it at any scale this suite renders at.
    static let cornerInset: Double = 16
    static let strokeWidth: Double = 4

    /// The six edges of the `geo-l-shape` fixture ring, inset and made disjoint.
    static func baselineEdges() throws -> [RevisionEdge] {
        let manifest = try ZPDFFixtures.manifest(for: .lShape)
        guard let ring = manifest.paths.first(where: { $0.id == "l-shape" }) else {
            throw RevisionCorpusError.fixturePathMissing("l-shape")
        }
        let points = ring.points
        guard points.count == 6 else { throw RevisionCorpusError.unexpectedVertexCount(points.count) }

        var edges: [RevisionEdge] = []
        for index in 0..<points.count {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let inset = insetSegment(a: a, b: b, by: cornerInset)
            edges.append(
                RevisionEdge(
                    "e\(index)",
                    from: (inset.0.x, inset.0.y),
                    to: (inset.1.x, inset.1.y),
                    width: strokeWidth
                )
            )
        }
        return edges
    }

    static func mediaBox() throws -> FixtureRect {
        let manifest = try ZPDFFixtures.manifest(for: .lShape)
        guard let page = manifest.pages.first else { throw RevisionCorpusError.fixturePathMissing("page") }
        return page.mediaBox
    }

    /// The edge the mutation tests move, and the vector by which they move it.
    static let movedEdgeIdentifier = "e2"
    static let moveDelta = (dx: 0.0, dy: 40.0)
    /// The edge the deletion tests remove.
    static let deletedEdgeIdentifier = "e4"
    /// The edge the addition tests introduce: far from every fixture edge.
    static let addedEdge = RevisionEdge("added", from: (300, 600), to: (400, 600), width: strokeWidth)

    enum Mutation: Sendable, CaseIterable {
        case none
        case movedEdge
        case addedEdge
        case deletedEdge
        case all
    }

    static func revisedEdges(_ mutation: Mutation, from baseline: [RevisionEdge]) -> [RevisionEdge] {
        var edges = baseline
        switch mutation {
        case .none:
            return edges
        case .movedEdge:
            edges = edges.map {
                $0.identifier == movedEdgeIdentifier
                    ? $0.translated(dx: moveDelta.dx, dy: moveDelta.dy) : $0
            }
        case .addedEdge:
            edges.append(addedEdge)
        case .deletedEdge:
            edges.removeAll { $0.identifier == deletedEdgeIdentifier }
        case .all:
            edges = edges.map {
                $0.identifier == movedEdgeIdentifier
                    ? $0.translated(dx: moveDelta.dx, dy: moveDelta.dy) : $0
            }
            edges.removeAll { $0.identifier == deletedEdgeIdentifier }
            edges.append(addedEdge)
        }
        return edges
    }

    /// Writes a baseline/revision pair to a fresh temporary directory.
    static func make(_ mutation: Mutation, rotation: Int = 0) throws -> RevisionPair {
        let box = try mediaBox()
        let baseline = try baselineEdges()
        let revised = revisedEdges(mutation, from: baseline)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baselineURL = directory.appendingPathComponent("baseline.pdf")
        let revisedURL = directory.appendingPathComponent("revised.pdf")
        try RevisionPDFWriter.data(mediaBox: box, edges: baseline, rotation: rotation)
            .write(to: baselineURL, options: .atomic)
        try RevisionPDFWriter.data(mediaBox: box, edges: revised, rotation: rotation)
            .write(to: revisedURL, options: .atomic)
        return RevisionPair(
            mediaBox: box,
            baselineEdges: baseline,
            revisedEdges: revised,
            baselineURL: baselineURL,
            revisedURL: revisedURL,
            directory: directory
        )
    }

    /// A pair whose revision is the whole baseline drawing shifted by a known vector.
    ///
    /// The page box is unchanged, so page-box matching cannot find the offset — this is
    /// exactly the case the manual two-point mode exists for.
    static func makeTranslated(dx: Double, dy: Double) throws -> RevisionPair {
        let box = try mediaBox()
        let baseline = try baselineEdges()
        let revised = baseline.map { $0.translated(dx: dx, dy: dy) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baselineURL = directory.appendingPathComponent("baseline.pdf")
        let revisedURL = directory.appendingPathComponent("revised.pdf")
        try RevisionPDFWriter.data(mediaBox: box, edges: baseline).write(to: baselineURL, options: .atomic)
        try RevisionPDFWriter.data(mediaBox: box, edges: revised).write(to: revisedURL, options: .atomic)
        return RevisionPair(
            mediaBox: box,
            baselineEdges: baseline,
            revisedEdges: revised,
            baselineURL: baselineURL,
            revisedURL: revisedURL,
            directory: directory
        )
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private static func insetSegment(
        a: FixturePoint,
        b: FixturePoint,
        by amount: Double
    ) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 2 * amount else {
            return (CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y))
        }
        let ux = dx / length
        let uy = dy / length
        return (
            CGPoint(x: a.x + ux * amount, y: a.y + uy * amount),
            CGPoint(x: b.x - ux * amount, y: b.y - uy * amount)
        )
    }
}

enum RevisionCorpusError: Error, CustomStringConvertible {
    case fixturePathMissing(String)
    case unexpectedVertexCount(Int)

    var description: String {
        switch self {
        case let .fixturePathMissing(id): return "the fixture has no path \(id)"
        case let .unexpectedVertexCount(count): return "expected 6 ring vertices, got \(count)"
        }
    }
}

// MARK: - Comparison harness

/// Opens a revision pair through the real PDFKit-backed provider and compares it.
struct CompareHarness {
    let provider: PDFKitDocumentProvider
    let comparator: RevisionComparator
    let baseline: RevisionPageReference
    let revised: RevisionPageReference

    static func open(_ pair: RevisionPair, includeVector: Bool = true) async throws -> CompareHarness {
        let provider = PDFKitDocumentProvider()
        let baselineDocument = try await provider.open(fileAt: pair.baselineURL)
        let revisedDocument = try await provider.open(fileAt: pair.revisedURL)
        return CompareHarness(
            provider: provider,
            comparator: RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider)),
            baseline: RevisionPageReference(
                document: baselineDocument.handle,
                pageIndex: 0,
                box: .crop,
                fileURL: includeVector ? pair.baselineURL : nil,
                label: "baseline"
            ),
            revised: RevisionPageReference(
                document: revisedDocument.handle,
                pageIndex: 0,
                box: .crop,
                fileURL: includeVector ? pair.revisedURL : nil,
                label: "revised"
            )
        )
    }

    /// Compares the pair with the identity alignment, which is correct here: both sheets
    /// are written with the same media box.
    func compare(
        scale: Double,
        tolerance: RasterDiffTolerance = .strict,
        includesVectorSignal: Bool = true,
        vector: VectorDiffOptions = .standard
    ) async throws -> RevisionComparisonResult {
        try await comparator.compare(
            RevisionCompareRequest(
                baseline: baseline,
                revised: revised,
                renderScale: scale,
                alignment: .identity,
                raster: RasterDiffOptions(tolerance: tolerance),
                vector: vector,
                includesVectorSignal: includesVectorSignal
            )
        )
    }

    func close() async {
        await provider.closeAll()
    }
}

/// Compares two `CGRect` values for equality within `tolerance` on every edge.
func rectsAreEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: Double) -> Bool {
    abs(Double(lhs.minX - rhs.minX)) <= tolerance
        && abs(Double(lhs.minY - rhs.minY)) <= tolerance
        && abs(Double(lhs.maxX - rhs.maxX)) <= tolerance
        && abs(Double(lhs.maxY - rhs.maxY)) <= tolerance
}

func describe(_ rect: CGRect) -> String {
    "[\(rect.minX), \(rect.minY)] – [\(rect.maxX), \(rect.maxY)]"
}
