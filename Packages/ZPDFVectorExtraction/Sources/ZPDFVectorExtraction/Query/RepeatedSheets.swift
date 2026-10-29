import CoreGraphics
import Foundation

/// Repeated storeys (NL-AUTO-21): sheets whose linework is the same drawing, found so the person
/// can measure one and apply it ×N — the Quantity Ledger's Repeat × column — instead of measuring
/// every floor again.
///
/// Each sheet becomes a *signature*: its straight segments. Two sheets match when every point of
/// every segment of each lies within a tolerance of the other sheet's segments — a symmetric
/// Hausdorff bound between the two drawings, checked **exactly, segment by segment**, not at
/// sample points (S-099, second pass).
///
/// For one segment of sheet A:
/// 1. If sheet B has a segment whose two ends each lie within the tolerance of this segment's
///    two ends, every point of this segment lies within the tolerance of that one (the gap between
///    two segments is largest at an end), and the segment is covered. On sheets that really
///    repeat, this settles nearly every segment with one lookup.
/// 2. Otherwise the check gathers the segments of B that come near it, works out the stretch of
///    A's segment that lies within the tolerance of each (a line meets the stadium around a
///    segment in one interval), and requires those stretches to cover the segment end to end.
///
/// Then B is checked against A the same way.
///
/// A sampled check could not make that promise. Its sample step grew with the amount of
/// linework — 48 pt on a sheet of about a million points of line, 95 pt at twice that — so a
/// plain opening moved along a wall, or a wall run on to a cross wall on one sheet and stopped
/// short of it on the other, slipped between the samples and the sheets grouped. The signature
/// still counts its sample points, but only to tell a sheet with hardly any linework; they
/// decide nothing about the match.
///
/// # The tolerance belongs to the drawing, not to the paper
///
/// The default, ``defaultTolerancePoints``, is half a point (0.18 mm on the sheet) whatever the
/// paper size: enough for re-plot noise, and at 1:100 a wall moved by 18 mm already fails. The
/// previous default was half a percent of the sheet's diagonal — 14.6 pt on A1, which is 0.51 m
/// at 1:100 — so storeys whose partitions differed by a few hundred millimetres were offered as
/// "the same drawing" and a Repeat × multiplier was proposed for quantities that are not repeated
/// (S-099). A difference in a title block that is drawn as linework now keeps two sheets apart;
/// that errs on the side of measuring again, never on the side of a wrong multiplier. Text drawn
/// as PDF text is not linework and never enters a signature, and neither do curves: the check
/// covers straight line segments, which is what the prompt calls lines.
///
/// # Cost
///
/// Both steps read grids, not pairwise searches: a sheet's segment ends are hashed into cells
/// (``SheetIndex/ends``), and its segments into the cells along them (``SheetIndex/band``), each
/// built at most once per sheet and only when a comparison needs it. ``groups(_:tolerance:)``
/// keeps every group's first sheet prepared, so comparing a sheet with every group costs one pass
/// over its segments per group, not a rebuild of the group's grids.
public enum RepeatedSheetDetector {

    /// One sheet's linework: its segments and how many points a sampling of them yields.
    public struct Signature: Sendable, Hashable {
        /// How many points sampling the segments yields. It only tells a sheet with hardly any
        /// linework (fewer than 50 never matches); the match itself is decided on `segments`.
        ///
        /// T-068: the signature used to keep the sample points themselves, at least two per
        /// segment (about 2.2 MB for a 60 000-segment sheet, as much again as its segments) and
        /// held for every page until grouping finished, only for this count to be read.
        public let sampleCount: Int
        public let segments: [VectorLine]
        public let pageSize: CGSize

        public init(sampleCount: Int, segments: [VectorLine], pageSize: CGSize) {
            self.sampleCount = sampleCount
            self.segments = segments
            self.pageSize = pageSize
        }

        /// A signature of bare points: each point is its own zero-length segment and one sample.
        public init(points: [CGPoint], pageSize: CGSize) {
            self.init(sampleCount: points.count, segments: points.map { VectorLine(start: $0, end: $0) }, pageSize: pageSize)
        }
    }

    /// The sampling budget: the step grows with the linework so the count stays near it.
    public static let maximumPoints = 20_000

    /// The default match bound, in page points: re-plot noise, not layout (S-099).
    public static let defaultTolerancePoints = 0.5

    /// The largest coordinate magnitude a segment may have to take part (a billion points,
    /// 350 km): anything beyond is not drawing, and is ignored on both sides of a comparison
    /// alike, as is a segment with a non-finite coordinate.
    static let coordinateLimit = 1e9

    static func isUsable(_ line: VectorLine) -> Bool {
        abs(line.start.x) <= coordinateLimit && abs(line.start.y) <= coordinateLimit
            && abs(line.end.x) <= coordinateLimit && abs(line.end.y) <= coordinateLimit
    }

    /// A signature from segments, sampled every `step` points (endpoints always included): each
    /// usable segment counts `max(1, ⌈length / spacing⌉) + 1` samples. Only the count is kept.
    public static func signature(segments: [GeometryQuerySegment], pageSize: CGSize, step: Double = 4) -> Signature {
        let usable = segments.filter { isUsable($0.line) }
        let total = usable.reduce(0.0) { $0 + hypot($1.end.x - $1.start.x, $1.end.y - $1.start.y) }
        let spacing = max(step, total / Double(maximumPoints))
        var sampleCount = 0
        for segment in usable {
            let length = hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y)
            sampleCount += max(1, Int((length / spacing).rounded(.up))) + 1
        }
        return Signature(sampleCount: sampleCount, segments: segments.map(\.line), pageSize: pageSize)
    }

    public static func signature(page: VectorPageExtraction, pageSize: CGSize, layerFilter: VectorLayerVisibilityFilter = .everythingVisible) -> Signature {
        signature(segments: page.primitives.compactMap { layerFilter.admits($0) ? GeometryQuerySegment(primitive: $0) : nil },
                  pageSize: pageSize)
    }

    // MARK: - Grids

    /// Square cells over the bounding box of one sheet's usable segments, one spare cell on each
    /// side. Coordinates outside are clamped to the edge, which only brings cells closer together,
    /// so any "within one cell" argument made inside the frame survives geometry outside it.
    struct GridFrame: Sendable {
        let cellSize: Double
        let originX: Double
        let originY: Double
        let columns: Int
        let rows: Int

        /// The most cells a frame allocates; the cell grows to stay under it on huge pages.
        static let maximumCells = 1 << 20

        init(segments: [VectorLine], minimumCellSize: Double) {
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for line in segments where RepeatedSheetDetector.isUsable(line) {
                minX = min(minX, line.start.x, line.end.x); maxX = max(maxX, line.start.x, line.end.x)
                minY = min(minY, line.start.y, line.end.y); maxY = max(maxY, line.start.y, line.end.y)
            }
            if minX > maxX { minX = 0; maxX = 0; minY = 0; maxY = 0 }
            let width = maxX - minX, height = maxY - minY
            var size = minimumCellSize
            while (width / size + 3) * (height / size + 3) > Double(Self.maximumCells) { size *= 2 }
            cellSize = size
            originX = minX - size
            originY = minY - size
            columns = Int(width / size) + 3
            rows = Int(height / size) + 3
        }

        var cellCount: Int { columns * rows }

        /// The clamped cell of `(x, y)`.
        func cell(_ x: Double, _ y: Double) -> (x: Int, y: Int) {
            (Int(min(max(((x - originX) / cellSize).rounded(.down), 0), Double(columns - 1))),
             Int(min(max(((y - originY) / cellSize).rounded(.down), 0), Double(rows - 1))))
        }

        /// Whether `point` lies inside the frame, which reaches one cell beyond every segment the
        /// frame was made for: a point outside it is more than a cell from all of them.
        func contains(_ point: CGPoint) -> Bool {
            point.x >= originX && point.x <= originX + Double(columns) * cellSize
                && point.y >= originY && point.y <= originY + Double(rows) * cellSize
        }

        /// Samples at most half a cell apart along `line`, endpoints included, calling `body` with
        /// each sample's cell whenever it differs from the previous sample's.
        func forEachCell(along line: VectorLine, _ body: (Int, Int) -> Void) {
            let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
            let steps = max(1, Int((hypot(dx, dy) / (cellSize / 2)).rounded(.up)))
            var last = (x: -1, y: -1)
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let c = cell(line.start.x + dx * t, line.start.y + dy * t)
                if c == last { continue }
                last = c
                body(c.x, c.y)
            }
        }

        /// Every cell within one cell (in both directions) of a cell that a point of `line` lies
        /// in, each once: row by row, the stretch of the line within one row of that row, widened
        /// by a column on each side. A hair of slack on both axes keeps rounding from dropping a
        /// cell at a boundary; a cell too many costs a lookup, a cell too few would cost exactness.
        func forEachCell(near line: VectorLine, _ body: (Int) -> Void) {
            let slack = 1e-6
            let u0 = (line.start.x - originX) / cellSize, v0 = (line.start.y - originY) / cellSize
            let u1 = (line.end.x - originX) / cellSize, v1 = (line.end.y - originY) / cellSize
            func clamped(_ value: Double, _ count: Int) -> Int { Int(min(max(value, 0), Double(count - 1))) }
            let rowLow = clamped((min(v0, v1) - slack).rounded(.down) - 1, rows)
            let rowHigh = clamped((max(v0, v1) + slack).rounded(.down) + 1, rows)
            for row in rowLow...rowHigh {
                var uLow = min(u0, u1), uHigh = max(u0, u1)
                if v0 != v1 {
                    var t0 = (Double(row - 1) - slack - v0) / (v1 - v0), t1 = (Double(row + 2) + slack - v0) / (v1 - v0)
                    if t0 > t1 { swap(&t0, &t1) }
                    t0 = max(0, t0); t1 = min(1, t1)
                    guard t0 <= t1 else { continue }
                    let ua = u0 + (u1 - u0) * t0, ub = u0 + (u1 - u0) * t1
                    uLow = min(ua, ub); uHigh = max(ua, ub)
                }
                let columnLow = clamped((uLow - slack).rounded(.down) - 1, columns)
                let columnHigh = clamped((uHigh + slack).rounded(.down) + 1, columns)
                for column in columnLow...columnHigh { body(row * columns + column) }
            }
        }

        /// The cells of the 3 × 3 block around `(x, y)` that exist.
        func forEachNeighbour(of x: Int, _ y: Int, _ body: (Int) -> Void) {
            for ny in max(0, y - 1)...min(rows - 1, y + 1) {
                for nx in max(0, x - 1)...min(columns - 1, x + 1) { body(ny * columns + nx) }
            }
        }
    }

    /// Segment indices listed per cell of a frame, in compressed rows: cell `c`'s indices are
    /// `entries[offsets[c] ..< offsets[c + 1]]`.
    struct CellLists: Sendable {
        let offsets: [Int32]
        let entries: [Int32]

        /// `register(line, emit)` emits the cells a segment belongs in; it is called twice for every
        /// usable segment, once to count and once to fill, and must emit the same cells both times.
        /// A cell one segment emits again, with no other segment in between, is entered once.
        init(frame: GridFrame, segments: [VectorLine], register: (VectorLine, (Int) -> Void) -> Void) {
            let cellCount = frame.cellCount
            var counts = [Int32](repeating: 0, count: cellCount + 1)
            var lastIndex = [Int32](repeating: -1, count: cellCount)
            for (index, line) in segments.enumerated() where RepeatedSheetDetector.isUsable(line) {
                let tag = Int32(truncatingIfNeeded: index)
                register(line) { cell in
                    guard lastIndex[cell] != tag else { return }
                    lastIndex[cell] = tag
                    counts[cell + 1] += 1
                }
            }
            for cell in 0..<cellCount { counts[cell + 1] += counts[cell] }
            var cursor = Array(counts.dropLast())
            var entries = [Int32](repeating: 0, count: Int(counts[cellCount]))
            for cell in lastIndex.indices { lastIndex[cell] = -1 }
            for (index, line) in segments.enumerated() where RepeatedSheetDetector.isUsable(line) {
                let tag = Int32(truncatingIfNeeded: index)
                register(line) { cell in
                    guard lastIndex[cell] != tag else { return }
                    lastIndex[cell] = tag
                    entries[Int(cursor[cell])] = tag
                    cursor[cell] += 1
                }
            }
            offsets = counts
            self.entries = entries
        }

        func forEach(inCell cell: Int, _ body: (Int) -> Void) {
            for slot in Int(offsets[cell])..<Int(offsets[cell + 1]) { body(Int(entries[slot])) }
        }
    }

    /// One sheet prepared to answer "is this line within the tolerance of your linework?".
    /// Local to one call of ``matches(_:_:tolerance:)`` or ``groups(_:tolerance:)``; never shared
    /// between threads, so it is a plain class with lazily built grids.
    final class SheetIndex {
        let segments: [VectorLine]
        let tolerance: Double

        init(segments: [VectorLine], tolerance: Double) {
            self.segments = segments
            self.tolerance = tolerance
        }

        /// Segment ends by cell, the cell at least three tolerances wide: an end within the
        /// tolerance of a point lies in the 3 × 3 block of cells around it.
        private(set) lazy var ends: (frame: GridFrame, lists: CellLists) = {
            let frame = GridFrame(segments: segments, minimumCellSize: max(4, 3 * tolerance))
            let lists = CellLists(frame: frame, segments: segments) { line, emit in
                let a = frame.cell(line.start.x, line.start.y), b = frame.cell(line.end.x, line.end.y)
                emit(a.y * frame.columns + a.x)
                emit(b.y * frame.columns + b.x)
            }
            return (frame, lists)
        }()

        /// Segments by the cells along them, as a band three cells wide: a segment is entered in
        /// every cell within one cell of a cell it passes through (``GridFrame/forEachCell(near:_:)``).
        /// A query segment is walked with samples at most half a cell apart and reads only its
        /// samples' cells.
        ///
        /// Why that finds every segment within the tolerance: take a point `p` of the query segment
        /// and the nearest point `m` of a stored segment, `|p − m| ≤ tolerance`. Some query sample
        /// `w` lies within a quarter cell of `p`, so `|w − m|` is at most a quarter cell plus the
        /// tolerance — under one cell, since the cell is at least three tolerances wide — and the
        /// cells of `w` and `m` are neighbours. The stored segment passes through `m`'s cell, so it
        /// was entered in `w`'s.
        private(set) lazy var band: (frame: GridFrame, lists: CellLists) = {
            let frame = GridFrame(segments: segments, minimumCellSize: max(16, 3 * tolerance))
            let lists = CellLists(frame: frame, segments: segments) { line, emit in frame.forEachCell(near: line, emit) }
            return (frame, lists)
        }()

        /// Per-query marks, so a segment met in several cells is measured once.
        private var stamp: [Int32] = []
        private var stampTag: Int32 = 0
        private var intervals: [(Double, Double)] = []

        /// Whether every point of every usable segment of `lines` lies within ``tolerance`` of
        /// this sheet's segments. Exact: no point of a segment goes unexamined.
        ///
        /// Segments with a near duplicate are settled first. The rest have their two ends and
        /// midpoint looked up — a necessary condition, one cell each, which turns most different
        /// sheets away before any walk — and only then are walked end to end.
        func covers(_ lines: [VectorLine]) -> Bool {
            guard tolerance > 0, tolerance.isFinite else { return false }
            let rest = lines.filter { RepeatedSheetDetector.isUsable($0) && !hasNearDuplicate(of: $0) }
            for line in rest {
                let middle = CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)
                guard pointIsCovered(line.start), pointIsCovered(line.end), pointIsCovered(middle) else { return false }
            }
            return rest.allSatisfy(bandCovers)
        }

        /// Whether `point` lies within the tolerance of a segment. The cell of the point lists
        /// every segment that can (the argument at ``band`` with the sample at the point itself).
        func pointIsCovered(_ point: CGPoint) -> Bool {
            let (frame, lists) = band
            guard frame.contains(point) else { return false }
            let c = frame.cell(point.x, point.y)
            let squared = tolerance * tolerance
            var found = false
            lists.forEach(inCell: c.y * frame.columns + c.x) { index in
                if !found, RepeatedSheetDetector.squaredDistance(from: point, to: segments[index]) <= squared { found = true }
            }
            return found
        }

        /// Step 1: a segment whose ends each lie within the tolerance of `line`'s ends. Every point
        /// `(1 − u)·a + u·b` of `line` is then within `(1 − u)·r + u·r = r` of the matching point
        /// of that segment.
        func hasNearDuplicate(of line: VectorLine) -> Bool {
            let (frame, lists) = ends
            let squared = tolerance * tolerance
            func near(_ p: CGPoint, _ q: CGPoint) -> Bool {
                let dx = p.x - q.x, dy = p.y - q.y
                return dx * dx + dy * dy <= squared
            }
            let c = frame.cell(line.start.x, line.start.y)
            var found = false
            frame.forEachNeighbour(of: c.x, c.y) { cell in
                guard !found else { return }
                lists.forEach(inCell: cell) { index in
                    guard !found else { return }
                    let other = segments[index]
                    if (near(line.start, other.start) && near(line.end, other.end))
                        || (near(line.start, other.end) && near(line.end, other.start)) {
                        found = true
                    }
                }
            }
            return found
        }

        /// Step 2: the stretches of `line` within the tolerance of each nearby segment cover it.
        func bandCovers(_ line: VectorLine) -> Bool {
            let (frame, lists) = band
            // The frame reaches one cell — more than the tolerance — beyond every segment, and it
            // is convex: both ends inside keeps the whole line inside, and bounds the walk.
            guard frame.contains(line.start), frame.contains(line.end) else { return false }
            if stamp.count != segments.count || stampTag == .max {
                stamp = [Int32](repeating: -1, count: segments.count)
                stampTag = 0
            }
            stampTag += 1
            let tag = stampTag
            intervals.removeAll(keepingCapacity: true)
            frame.forEachCell(along: line) { x, y in
                lists.forEach(inCell: y * frame.columns + x) { index in
                    guard stamp[index] != tag else { return }
                    stamp[index] = tag
                    if let interval = RepeatedSheetDetector.coveredInterval(of: line, by: segments[index], within: tolerance) {
                        intervals.append(interval)
                    }
                }
            }
            return RepeatedSheetDetector.intervalsCoverSegment(intervals, length: line.length)
        }
    }

    // MARK: - Exact coverage of one segment

    /// The squared distance from `p` to the closed segment `line`.
    static func squaredDistance(from p: CGPoint, to line: VectorLine) -> Double {
        let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
        let lengthSquared = dx * dx + dy * dy
        var t = lengthSquared > 0 ? ((p.x - line.start.x) * dx + (p.y - line.start.y) * dy) / lengthSquared : 0
        t = min(1, max(0, t))
        let ex = line.start.x + dx * t - p.x, ey = line.start.y + dy * t - p.y
        return ex * ex + ey * ey
    }

    /// The stretch of `line`, as parameters in `[0, 1]` from its start, whose points lie within
    /// `radius` of the closed segment `other`; `nil` when no point does.
    ///
    /// The points within `radius` of a segment form a stadium — a band along it and a disc at each
    /// end — and a convex set meets a line in one interval, so the answer is the hull of the
    /// three pieces. The disc test uses the cross-product form of the discriminant, which keeps
    /// its precision when the line is long and the radius small.
    static func coveredInterval(of line: VectorLine, by other: VectorLine, within radius: Double) -> (Double, Double)? {
        let px = line.start.x, py = line.start.y
        let dx = line.end.x - px, dy = line.end.y - py
        let dd = dx * dx + dy * dy
        var low = Double.infinity, high = -Double.infinity
        func unite(_ a: Double, _ b: Double) {
            let a = max(0, a), b = min(1, b)
            guard a <= b else { return }
            low = min(low, a); high = max(high, b)
        }
        // The discs at the other segment's ends.
        func disc(_ centre: CGPoint) {
            let fx = px - centre.x, fy = py - centre.y
            if dd == 0 {
                if fx * fx + fy * fy <= radius * radius { unite(0, 1) }
                return
            }
            let cross = dx * fy - dy * fx
            let discriminant = dd * radius * radius - cross * cross
            guard discriminant >= 0 else { return }
            let along = dx * fx + dy * fy, root = discriminant.squareRoot()
            unite((-along - root) / dd, (-along + root) / dd)
        }
        disc(other.start)
        disc(other.end)
        // The band: 0 ≤ (p − q)·e ≤ |e|² along the other segment, |(p − q) × e| ≤ radius·|e| across it.
        let ex = other.end.x - other.start.x, ey = other.end.y - other.start.y
        let ee = ex * ex + ey * ey
        if ee > 0 {
            var a = 0.0, b = 1.0
            func clip(_ f0: Double, _ f1: Double, _ lower: Double, _ upper: Double) {
                if f1 == 0 {
                    if f0 < lower || f0 > upper { a = 1; b = 0 }
                    return
                }
                var u0 = (lower - f0) / f1, u1 = (upper - f0) / f1
                if f1 < 0 { swap(&u0, &u1) }
                a = max(a, u0); b = min(b, u1)
            }
            let qx = px - other.start.x, qy = py - other.start.y
            clip(qx * ex + qy * ey, dx * ex + dy * ey, 0, ee)
            let reach = radius * ee.squareRoot()
            clip(qx * ey - qy * ex, dx * ey - dy * ex, -reach, reach)
            if a <= b { unite(a, b) }
        }
        return low <= high ? (low, high) : nil
    }

    /// Whether `intervals` (parameters along a segment of `length` points) cover `[0, 1]` without
    /// a gap wider than a billionth of a point.
    static func intervalsCoverSegment(_ intervals: [(Double, Double)], length: Double) -> Bool {
        guard !intervals.isEmpty else { return false }
        guard length > 0 else { return true }
        let slack = 1e-9 / length
        var reach = 0.0
        for (low, high) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if low > reach + slack { return false }
            reach = max(reach, high)
            if reach >= 1 - slack { return true }
        }
        return reach >= 1 - slack
    }

    // MARK: - Matching

    /// Whether `a` and `b` can match at all: sheets of different sizes, or with hardly any
    /// linework, never do.
    static func comparable(_ a: Signature, _ b: Signature) -> Bool {
        guard a.sampleCount >= 50, b.sampleCount >= 50 else { return false }
        return abs(a.pageSize.width - b.pageSize.width) <= 1 && abs(a.pageSize.height - b.pageSize.height) <= 1
    }

    /// Whether two sheets are the same drawing within `tolerance` page points: every point of
    /// every segment of each lies within `tolerance` of the other's segments.
    public static func matches(_ a: Signature, _ b: Signature, tolerance: Double) -> Bool {
        guard comparable(a, b), tolerance > 0, tolerance.isFinite else { return false }
        return SheetIndex(segments: b.segments, tolerance: tolerance).covers(a.segments)
            && SheetIndex(segments: a.segments, tolerance: tolerance).covers(b.segments)
    }

    /// Groups of matching sheets, each of two or more, by their first member; `signatures` is
    /// keyed by page index. A sheet joins the first group whose first sheet it matches.
    ///
    /// A group's first sheet keeps its ``SheetIndex`` for every later comparison, and a sheet's
    /// grids are built only when a comparison reaches them.
    public static func groups(_ signatures: [(page: Int, signature: Signature)],
                              tolerance: Double = defaultTolerancePoints) -> [[Int]] {
        guard tolerance > 0, tolerance.isFinite else { return [] }
        var groups: [[Int]] = []
        var heads: [(signature: Signature, index: SheetIndex)] = []
        for entry in signatures.sorted(by: { $0.page < $1.page }) {
            let entryIndex = SheetIndex(segments: entry.signature.segments, tolerance: tolerance)
            let joined = heads.firstIndex { head in
                comparable(head.signature, entry.signature)
                    && head.index.covers(entry.signature.segments)
                    && entryIndex.covers(head.signature.segments)
            }
            if let joined {
                groups[joined].append(entry.page)
            } else {
                heads.append((entry.signature, entryIndex))
                groups.append([entry.page])
            }
        }
        return groups.filter { $0.count > 1 }
    }
}
