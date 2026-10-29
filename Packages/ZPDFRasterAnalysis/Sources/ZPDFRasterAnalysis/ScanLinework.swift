import CoreGraphics
import Foundation
import ZPDFVectorExtraction

/// Straight linework recovered from a scanned sheet (NL-AUTO-14, track a): horizontal and
/// vertical strokes, as proxy primitives the region tracer walks like vector lines.
///
/// # How
///
/// Dark pixels (below ``Options/threshold``) are read row by row into runs; a run at least
/// ``Options/minimumRunPoints`` long is a piece of a horizontal stroke, and runs that overlap on
/// consecutive rows are one stroke (a *band*). A thin band becomes one segment along its middle;
/// a thick band — a filled (poché) wall — becomes its two long edges, so a room traced inside it
/// is measured to the wall's face, as on a vector drawing. Columns give the vertical strokes the
/// same way. Short runs — lettering, hatching dots — never reach the length and stay out.
///
/// # What it is not
///
/// Only horizontal and vertical strokes are recovered; a sloped wall on a scan is not, and a
/// room bounded by one does not trace (the tracer says it could not close it). Every primitive
/// carries confidence 0.4 and the layer "scan", so nothing downstream can mistake it for the
/// drawing's own vector geometry, and nothing here is a snap target (spec 17.3).
public enum ScanLinework {

    public static let layerID = "scan"
    public static let confidence: Float = 0.4

    public struct Options: Sendable, Hashable {
        /// A pixel darker than this is ink.
        public var threshold: UInt8
        /// The shortest stroke kept, in page points.
        public var minimumRunPoints: Double
        /// A band thicker than this is a filled wall, and gives its two edges.
        public var maximumLineThicknessPoints: Double
        /// Two runs on neighbouring rows belong to one band when they overlap by this share.
        public var overlapShare: Double

        public init(threshold: UInt8 = 128, minimumRunPoints: Double = 10, maximumLineThicknessPoints: Double = 1.8, overlapShare: Double = 0.7) {
            self.threshold = threshold
            self.minimumRunPoints = minimumRunPoints
            self.maximumLineThicknessPoints = maximumLineThicknessPoints
            self.overlapShare = overlapShare
        }

        public static let standard = Options()
    }

    /// One recovered stroke, in page space.
    public struct Stroke: Sendable, Hashable {
        public let start: CGPoint
        public let end: CGPoint
        public let thicknessPoints: Double
    }

    /// Every horizontal and vertical stroke of the picture, in page space.
    public static func strokes(in raster: GrayRaster, options: Options = .standard) -> [Stroke] {
        let ppp = raster.pointsPerPixel
        let minimumRun = max(2, Int((options.minimumRunPoints / ppp).rounded(.up)))
        let maximumThin = max(1, Int((options.maximumLineThicknessPoints / ppp).rounded()))
        var strokes: [Stroke] = []
        // Horizontal: rows as lines, x along the run.
        for band in bands(length: raster.height, span: raster.width, minimumRun: minimumRun, overlapShare: options.overlapShare,
                          dark: { line, position in raster[position, line] < options.threshold }) {
            strokes.append(contentsOf: segments(of: band, maximumThin: maximumThin, horizontal: true, raster: raster))
        }
        // Vertical: columns as lines, y along the run.
        for band in bands(length: raster.width, span: raster.height, minimumRun: minimumRun, overlapShare: options.overlapShare,
                          dark: { line, position in raster[line, position] < options.threshold }) {
            strokes.append(contentsOf: segments(of: band, maximumThin: maximumThin, horizontal: false, raster: raster))
        }
        return strokes
    }

    /// A band: runs `[from, to)` along the line direction, across lines `first...last`.
    struct Band {
        var from: Int
        var to: Int
        var first: Int
        var last: Int
    }

    static func bands(length: Int, span: Int, minimumRun: Int, overlapShare: Double, dark: (Int, Int) -> Bool) -> [Band] {
        var finished: [Band] = []
        var active: [Band] = []
        for line in 0..<length {
            var runs: [(Int, Int)] = []
            var position = 0
            while position < span {
                if dark(line, position) {
                    let start = position
                    while position < span, dark(line, position) { position += 1 }
                    if position - start >= minimumRun { runs.append((start, position)) }
                } else {
                    position += 1
                }
            }
            var next: [Band] = []
            var used = Set<Int>()
            for run in runs {
                if let index = active.indices.first(where: { index in
                    guard !used.contains(index) else { return false }
                    let band = active[index]
                    let overlap = min(band.to, run.1) - max(band.from, run.0)
                    return Double(overlap) >= overlapShare * Double(min(band.to - band.from, run.1 - run.0))
                }) {
                    used.insert(index)
                    var band = active[index]
                    band.from = min(band.from, run.0)
                    band.to = max(band.to, run.1)
                    band.last = line
                    next.append(band)
                } else {
                    next.append(Band(from: run.0, to: run.1, first: line, last: line))
                }
            }
            for index in active.indices where !used.contains(index) { finished.append(active[index]) }
            active = next
        }
        finished.append(contentsOf: active)
        return finished
    }

    static func segments(of band: Band, maximumThin: Int, horizontal: Bool, raster: GrayRaster) -> [Stroke] {
        let thickness = band.last - band.first + 1
        let ppp = raster.pointsPerPixel
        func point(along: Double, across: Double) -> CGPoint {
            horizontal ? raster.pagePoint(x: along, y: across) : raster.pagePoint(x: across, y: along)
        }
        if thickness <= maximumThin {
            let middle = Double(band.first) + Double(thickness) / 2
            return [Stroke(start: point(along: Double(band.from), across: middle), end: point(along: Double(band.to), across: middle),
                           thicknessPoints: Double(thickness) * ppp)]
        }
        // A filled band: its two long edges.
        return [
            Stroke(start: point(along: Double(band.from), across: Double(band.first)), end: point(along: Double(band.to), across: Double(band.first)), thicknessPoints: ppp),
            Stroke(start: point(along: Double(band.from), across: Double(band.last + 1)), end: point(along: Double(band.to), across: Double(band.last + 1)), thicknessPoints: ppp),
        ]
    }

    /// The strokes as proxy primitives for the region tracer: line segments, confidence 0.4,
    /// layer "scan", ids from `firstID` up.
    public static func primitives(in raster: GrayRaster, options: Options = .standard, firstID: UInt64 = 1 << 40) -> [VectorPrimitive] {
        strokes(in: raster, options: options).enumerated().map { index, stroke in
            let id = firstID + UInt64(index)
            return VectorPrimitive(
                id: id, parentID: nil, kind: .lineSegment,
                geometry: .line(VectorLine(start: stroke.start, end: stroke.end)),
                bounds: VectorBounds(minX: min(stroke.start.x, stroke.end.x), minY: min(stroke.start.y, stroke.end.y),
                                     maxX: max(stroke.start.x, stroke.end.x), maxY: max(stroke.start.y, stroke.end.y)),
                sourceObjectID: id, subpathIndex: 0, nestingDepth: 0, paint: .stroked,
                strokeWidth: stroke.thicknessPoints, strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil,
                confidence: confidence, layerID: layerID)
        }
    }
}
