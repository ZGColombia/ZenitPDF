import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction
@testable import ZPDFRasterAnalysis

/// NL-AUTO-14 benchmark, the report's acceptance: a 300 dpi scan of a vector plan traces its rooms
/// within 1 % of the vector trace, and symbol recall is at least 90 % with every result a
/// proposal marked from the scan.
///
/// The plan (page points): a 400 × 250 building with double-line walls 5 pt thick, one partition
/// at x = 200…205, so room A is 5…200 × 5…245 inside the faces: 195 × 240 =
/// 46 800 pt² by hand — the vector trace's area, and the number the scan must hit within 1 %.
@Suite("Scanned sheets — trace and count benchmark", .serialized)
struct ScanAutomationBenchmarkTests {

    typealias Line = (CGPoint, CGPoint)

    static let pageSize = CGSize(width: 420, height: 270)

    static func plan() -> [Line] {
        func l(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Line { (CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)) }
        return [
            // Outer face, then inner face.
            l(0, 0, 400, 0), l(400, 0, 400, 250), l(400, 250, 0, 250), l(0, 250, 0, 0),
            l(5, 5, 395, 5), l(395, 5, 395, 245), l(395, 245, 5, 245), l(5, 245, 5, 5),
            // Partition faces, from inner face to inner face, closed at both ends.
            l(200, 5, 200, 245), l(205, 5, 205, 245),
        ].map { (CGPoint(x: $0.0.x + 10, y: $0.0.y + 10), CGPoint(x: $0.1.x + 10, y: $0.1.y + 10)) }
    }

    static func vectorPrimitives(_ lines: [Line]) -> [VectorPrimitive] {
        lines.enumerated().map { index, line in
            VectorPrimitive(id: UInt64(index + 1), parentID: nil, kind: .lineSegment, geometry: .line(VectorLine(start: line.0, end: line.1)),
                            bounds: VectorBounds(minX: min(line.0.x, line.1.x), minY: min(line.0.y, line.1.y), maxX: max(line.0.x, line.1.x), maxY: max(line.0.y, line.1.y)),
                            sourceObjectID: UInt64(index + 1), subpathIndex: 0, nestingDepth: 0, paint: .stroked, strokeWidth: 0.5,
                            strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: nil)
        }
    }

    /// The plan as a scan: black lines 0.5 pt wide on white, at `dpi`.
    static func scan(_ lines: [Line], extra: (CGContext) -> Void = { _ in }, dpi: Double) throws -> GrayRaster {
        let scale = dpi / 72
        let width = Int((pageSize.width * scale).rounded()), height = Int((pageSize.height * scale).rounded())
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.5)
        for line in lines {
            context.move(to: line.0)
            context.addLine(to: line.1)
        }
        context.strokePath()
        extra(context)
        let image = try #require(context.makeImage())
        return try #require(GrayRaster(image: image, pageRegion: CGRect(origin: .zero, size: pageSize)))
    }

    @Test("A 300 dpi scan traces room A within 1 % of the vector trace (46 800 pt² by hand)")
    func traceWithinOnePercent() throws {
        let click = PDFPoint(x: 110, y: 135)
        guard case let .traced(vector) = RegionTracer.trace(RegionTracer.prepare(primitives: Self.vectorPrimitives(Self.plan())), click: click) else {
            Issue.record("the vector plan did not trace")
            return
        }
        #expect(abs(vector.area - 46_800) < 1e-6, "the vector trace is the hand value")

        let raster = try Self.scan(Self.plan(), dpi: 300)
        let primitives = ScanLinework.primitives(in: raster)
        #expect(primitives.allSatisfy { $0.confidence == ScanLinework.confidence && $0.layerID == ScanLinework.layerID })
        guard case let .traced(scanned) = RegionTracer.trace(RegionTracer.prepare(primitives: primitives), click: click) else {
            Issue.record("the scan did not trace")
            return
        }
        let error = abs(scanned.area - vector.area) / vector.area
        #expect(error < 0.01, "scan \(scanned.area) pt² vs vector \(vector.area) pt²: \(error * 100) %")
    }

    @Test("A filled (poché) wall gives its two faces, so the room is measured to the face")
    func filledWall() throws {
        // A 200 × 100 room whose walls are 6 pt solid bands.
        let raster = try Self.scan([], extra: { context in
            context.setFillColor(gray: 0, alpha: 1)
            for rect in [CGRect(x: 20, y: 20, width: 212, height: 6), CGRect(x: 20, y: 126, width: 212, height: 6),
                         CGRect(x: 20, y: 20, width: 6, height: 112), CGRect(x: 226, y: 20, width: 6, height: 112)] {
                context.fill(rect)
            }
        }, dpi: 300)
        guard case let .traced(room) = RegionTracer.trace(RegionTracer.prepare(primitives: ScanLinework.primitives(in: raster)), click: PDFPoint(x: 120, y: 75)) else {
            Issue.record("the filled-wall room did not trace")
            return
        }
        // Inside the faces: (226 − 26) × (126 − 26) = 200 × 100 = 20 000 pt².
        #expect(abs(room.area - 20_000) / 20_000 < 0.01, "\(room.area)")
    }

    /// A door symbol: a leaf line and its quarter-circle swing in a 24 pt box, drawn at `origin`.
    static func door(_ context: CGContext, at origin: CGPoint, turns: Int, mirrored: Bool) {
        context.saveGState()
        context.translateBy(x: origin.x + 12, y: origin.y + 12)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        if mirrored { context.scaleBy(x: -1, y: 1) }
        context.translateBy(x: -12, y: -12)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.8)
        context.move(to: CGPoint(x: 2, y: 2)); context.addLine(to: CGPoint(x: 2, y: 22))
        context.move(to: CGPoint(x: 2, y: 22)); context.addArc(center: CGPoint(x: 2, y: 2), radius: 20, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        context.move(to: CGPoint(x: 2, y: 2)); context.addLine(to: CGPoint(x: 22, y: 2))
        context.strokePath()
        context.restoreGState()
    }

    @Test("Twelve doors in four turns and mirrored: recall at least 90 %, no stray match on the walls or the text")
    func symbolRecall() throws {
        var placements: [(CGPoint, Int, Bool)] = []
        for index in 0..<12 {
            let x: Double = 30 + Double(index % 6) * 60
            let y: Double = 40 + Double(index / 6) * 120
            placements.append((CGPoint(x: x, y: y), index % 4, index % 3 == 0))
        }
        let raster = try Self.scan(Self.plan(), extra: { context in
            for placement in placements { Self.door(context, at: placement.0, turns: placement.1, mirrored: placement.2) }
            // Lettering the matcher must not take for a door.
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 300, y: 225, width: 40, height: 3))
        }, dpi: 150)
        // The person boxes the first door (24 pt square at its origin).
        let example = try #require(raster.crop(x: Int((placements[0].0.x) * 150 / 72), y: Int((Self.pageSize.height - placements[0].0.y - 24) * 150 / 72),
                                               width: Int(24 * 150 / 72), height: Int(24 * 150 / 72)))
        let matches = TemplateMatcher.matches(of: example, in: raster)
        let centres = placements.map { CGPoint(x: $0.0.x + 12, y: $0.0.y + 12) }
        let hits = centres.filter { centre in matches.contains { hypot($0.center.x - centre.x, $0.center.y - centre.y) < 4 } }
        let strays = matches.filter { match in !centres.contains { hypot(match.center.x - $0.x, match.center.y - $0.y) < 4 } }
        #expect(Double(hits.count) / Double(centres.count) >= 0.9, "recall \(hits.count)/\(centres.count)")
        #expect(strays.count <= 1, "strays: \(strays.map(\.center))")
        #expect(matches.allSatisfy { $0.score >= TemplateMatcher.Options.standard.threshold })
    }
}
