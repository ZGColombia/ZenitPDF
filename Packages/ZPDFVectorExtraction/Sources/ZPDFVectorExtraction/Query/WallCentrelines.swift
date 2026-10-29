import CoreGraphics
import Foundation

/// Wall takeoff from parallel pairs (NL-AUTO-20): the wall classes of a plan by thickness, and
/// each class's centrelines, as **proposals**.
///
/// # What it does
///
/// 1. **Classes.** Every pair of near-parallel segments whose separation lies in a plausible wall
///    range is weighed by how far the two faces run side by side; the separations are binned and
///    the peaks are the plan's wall thicknesses ("Wall 150 mm", "Wall 250 mm"). A thickness is a
///    class only when enough wall runs at it, so a pair of dimension lines does not become one.
/// 2. **Centrelines.** For each class, every facing pair gives the midline of the stretch where
///    the two faces overlap. Collinear midlines are merged; a gap between them no wider than
///    one and a half wall thicknesses is a junction (another wall's end, a break in a face) and
///    is closed; a wider gap is an **opening** and is excluded and listed with its width — unless
///    another wall's centreline crosses it (a thinner wall passing through a thicker one), whose
///    footprint is a junction, or it is wider than ``Options/maximumOpeningPoints`` (two
///    unrelated walls on one line), which splits the run without listing anything (U-082).
/// 3. **Corners.** At an L-corner the two centrelines are extended to meet at their
///    intersection, the centreline convention for a perimeter. At a T-junction the wall that
///    stops stays stopped at the face of the wall it meets, so no stretch is counted twice.
/// 4. **Chains.** Pieces that meet end to end are chained into polylines, one polylength each.
///
/// # What it never does
///
/// It does not commit anything. The result is a proposal a person reviews and accepts; accepted
/// walls carry `CaptureMethod.wallCentreline` with their thickness (ADR-0031). Junction handling
/// is the risky part of this problem (the report says so), which is why every proposal lists its
/// openings and the rule for corners and junctions is stated, not guessed.
public struct WallCentrelineEngine: Sendable {

    /// One wall class and its centrelines.
    public struct WallClass: Sendable, Hashable {
        /// The class's wall thickness in page points (the separation peak).
        public let thicknessPoints: Double
        /// Each chained centreline, as the polyline points of one polylength.
        public let centrelines: [[CGPoint]]
        /// Each excluded opening: where it is (the midpoint) and how wide, in page points.
        public let openings: [Opening]
        /// Whether a parallel-pair search behind this class stopped at ``WallCentrelineEngine/pairLimit``
        /// — the one that found the thicknesses or the one that found this class's faces. The
        /// search keeps the pairs of the lowest-indexed segments and drops the rest, so walls of
        /// this class may be missing and ``lengthPoints`` may be short (S-098).
        public let isTruncated: Bool
        /// The share of the class's facing length, `0…1`, that repeats on both sides: pairs in
        /// which a face has another line at the class's spacing behind it as well as in front
        /// (L-74). A wall is a band of material with a room on either side, so its faces pair
        /// with each other only, and the share is near 0; hatching, tile and roof-covering
        /// patterns, stair treads and stacked dimension lines are evenly spaced runs of
        /// parallels, where every inner line pairs both ways, and the share is near 1 — at the
        /// pattern's spacing and at every multiple of it.
        public let repeatingShare: Double
        /// Whether the class looks like walls rather than a repeating pattern: at most
        /// ``WallCentrelineEngine/maximumWallRepeatingShare`` of its facing length repeats.
        public var isLikelyWall: Bool { repeatingShare <= WallCentrelineEngine.maximumWallRepeatingShare }
        /// Total centreline length, in page points.
        public var lengthPoints: Double {
            centrelines.reduce(0) { total, line in
                total + zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            }
        }
    }

    public struct Opening: Sendable, Hashable {
        public let midpoint: CGPoint
        public let widthPoints: Double
    }

    /// Every class, and whether any pair search stopped at its limit.
    ///
    /// The flag is here as well as on each class because a truncated thickness search can lose
    /// a class outright: an empty ``classes`` with ``isTruncated`` set means "none found in the
    /// part of the sheet that was searched", not "this sheet has no walls".
    public struct Takeoff: Sendable, Hashable {
        public let classes: [WallClass]
        public let isTruncated: Bool
    }

    /// The most parallel pairs one search keeps. A dense sheet (hatching, tile grids, stair
    /// treads) can exceed it; the result then says so rather than passing a partial takeoff off
    /// as a whole one.
    public static let pairLimit = 50_000

    /// The most of a class's facing length that may repeat on both sides for the class to be
    /// offered as walls (L-74). A wall's face repeats only where something parallel sits at
    /// exactly the wall's thickness in the room beside it — a worktop edge, a dimension line —
    /// which is a small part of a run; a pattern repeats along nearly all of it. A quarter is
    /// far from both.
    public static let maximumWallRepeatingShare = 0.25

    public struct Options: Sendable, Hashable {
        /// The thinnest separation that can be a wall, in page points.
        public var minimumThicknessPoints: Double
        /// The thickest, in page points.
        public var maximumThicknessPoints: Double
        /// Histogram bin width, in page points.
        public var binPoints: Double
        /// A class needs at least this much facing length, in page points.
        public var minimumClassLengthPoints: Double
        /// How far a pair's separation may sit from its class's peak.
        public var thicknessTolerancePoints: Double
        /// Two faces must face each other at least this far to be a wall.
        public var minimumOverlapPoints: Double
        /// A gap wider than this many thicknesses is an opening, not a junction.
        public var junctionGapFactor: Double
        /// The widest gap that can be a door or a window, in page points. A wider gap on one line
        /// is two walls that happen to be collinear: the run is split there and nothing is listed
        /// (U-082).
        public var maximumOpeningPoints: Double

        public init(minimumThicknessPoints: Double, maximumThicknessPoints: Double, binPoints: Double = 0.5,
                    minimumClassLengthPoints: Double, thicknessTolerancePoints: Double = 0.75,
                    minimumOverlapPoints: Double = 2, junctionGapFactor: Double = 1.5,
                    maximumOpeningPoints: Double = .infinity) {
            self.minimumThicknessPoints = minimumThicknessPoints
            self.maximumThicknessPoints = maximumThicknessPoints
            self.binPoints = binPoints
            self.minimumClassLengthPoints = minimumClassLengthPoints
            self.thicknessTolerancePoints = thicknessTolerancePoints
            self.minimumOverlapPoints = minimumOverlapPoints
            self.junctionGapFactor = junctionGapFactor
            self.maximumOpeningPoints = maximumOpeningPoints
        }

        /// Options for a calibrated page: walls from 50 mm to 600 mm, a class needs 2 m of wall,
        /// an opening is at most 3 m wide.
        public static func calibrated(pointsPerMetre: Double) -> Options {
            Options(minimumThicknessPoints: 0.05 * pointsPerMetre, maximumThicknessPoints: 0.6 * pointsPerMetre,
                    binPoints: max(0.01 * pointsPerMetre, 0.1), minimumClassLengthPoints: 2 * pointsPerMetre,
                    thicknessTolerancePoints: max(0.0075 * pointsPerMetre, 0.25), minimumOverlapPoints: 0.1 * pointsPerMetre,
                    maximumOpeningPoints: 3 * pointsPerMetre)
        }
    }

    public let segments: [GeometryQuerySegment]
    public let options: Options

    public init(segments: [GeometryQuerySegment], options: Options) {
        self.segments = segments
        self.options = options
    }

    public init(page: VectorPageExtraction, options: Options, layerFilter: VectorLayerVisibilityFilter = .everythingVisible) {
        self.init(segments: page.primitives.compactMap { layerFilter.admits($0) ? GeometryQuerySegment(primitive: $0) : nil },
                  options: options)
    }

    /// The segments that can take part in a pair. Two faces overlap by at most the shorter
    /// face's length, so a segment shorter than ``Options/minimumOverlapPoints`` can never form
    /// a wall; leaving tick marks, hatch dashes and text strokes out keeps them from spending
    /// the pair budget and from slowing the search.
    var pairingSegments: [GeometryQuerySegment] {
        segments.filter { $0.length >= options.minimumOverlapPoints }
    }

    // MARK: - Classes

    /// The plan's wall thicknesses, thinnest first, and whether the pair search behind them
    /// stopped at ``pairLimit``. Reached only through ``takeoff()``, which keeps the flag (T-070
    /// deleted the public `thicknessClasses()`, which dropped it).
    private func thicknessSearch(_ engine: GeometryQueryEngine) -> (classes: [Double], isTruncated: Bool) {
        let middle = (options.minimumThicknessPoints + options.maximumThicknessPoints) / 2
        let half = (options.maximumThicknessPoints - options.minimumThicknessPoints) / 2
        let search = engine.parallelPairs(gap: middle, tolerance: half, minimumOverlap: options.minimumOverlapPoints,
                                          resultLimit: Self.pairLimit)
        let pairs = search.matches
        var bins: [Int: Double] = [:]
        for pair in pairs {
            bins[Int((pair.separationPoints / options.binPoints).rounded()), default: 0] += pair.overlapLengthPoints
        }
        // Peaks: the heaviest bins first, each claiming its neighbourhood of one tolerance.
        var classes: [Double] = []
        let reach = Int((options.thicknessTolerancePoints / options.binPoints).rounded(.up))
        for (bin, _) in bins.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            let weight = (bin - reach...bin + reach).reduce(0) { $0 + (bins[$1] ?? 0) }
            guard weight >= options.minimumClassLengthPoints else { continue }
            let centre = Double(bin) * options.binPoints
            guard !classes.contains(where: { abs($0 - centre) <= options.thicknessTolerancePoints * 2 }) else { continue }
            // The weighted mean of the neighbourhood, so a bin edge does not bias the thickness.
            var sum = 0.0, total = 0.0
            for neighbour in bin - reach...bin + reach {
                let w = bins[neighbour] ?? 0
                sum += Double(neighbour) * options.binPoints * w
                total += w
            }
            classes.append(total > 0 ? sum / total : centre)
        }
        return (classes.sorted(), search.status != .complete)
    }

    // MARK: - Centrelines

    /// Every class with its centrelines and openings, and whether the result is complete.
    ///
    /// Before S-098 both pair searches dropped their `.truncated` status, so a dense sheet could
    /// yield understated wall lengths, or no class at all, with nothing to say so.
    public func takeoff() -> Takeoff {
        guard let engine = try? GeometryQueryEngine(segments: pairingSegments) else {
            return Takeoff(classes: [], isTruncated: false)
        }
        let (classes, thicknessTruncated) = thicknessSearch(engine)
        guard !classes.isEmpty else { return Takeoff(classes: [], isTruncated: thicknessTruncated) }
        var perClass: [(thickness: Double, pieces: [Piece], gaps: [Gap], truncated: Bool, repeating: Double)] = []
        let byID = Dictionary(pairingSegments.map { ($0.primitiveID, $0) }, uniquingKeysWith: { first, _ in first })
        for thickness in classes {
            let search = engine.parallelPairs(gap: thickness, tolerance: options.thicknessTolerancePoints,
                                              minimumOverlap: options.minimumOverlapPoints, resultLimit: Self.pairLimit)
            let midlines = search.matches.map { pair -> Piece in
                let q = pair.overlapQuad
                return Piece(start: mid(q.c0, q.c3), end: mid(q.c1, q.c2))
            }
            let (merged, gaps) = mergeRuns(midlines, thickness: thickness)
            perClass.append((thickness, merged, gaps, thicknessTruncated || search.status != .complete,
                             Self.repeatingShare(of: search.matches, segments: byID)))
        }
        // Openings are judged against every class's runs: a thinner wall crossing a thicker one
        // leaves a gap in its own midline that is a junction, not a door (U-082).
        let walls = perClass.flatMap { entry in entry.pieces.map { (thickness: entry.thickness, piece: $0) } }
        let pieces = perClass.map { entry in
            (thickness: entry.thickness, pieces: entry.pieces, openings: openings(entry.gaps, crossedBy: walls),
             truncated: entry.truncated, repeating: entry.repeating)
        }
        // L-corners across every class: two pieces whose ends sit near the same intersection.
        var all = pieces.flatMap { entry in entry.pieces.map { (entry.thickness, $0) } }
        extendCorners(&all)
        let result = pieces.map { entry in
            let own = all.filter { $0.0 == entry.thickness }.map(\.1)
            return WallClass(thicknessPoints: entry.thickness, centrelines: chain(own), openings: entry.openings,
                             isTruncated: entry.truncated, repeatingShare: entry.repeating)
        }
        return Takeoff(classes: result, isTruncated: result.contains(where: \.isTruncated))
    }

    /// The share of `pairs`' facing length in which a face repeats on both sides (L-74).
    ///
    /// Every pair puts each of its two lines on one side of the other. A line's facing length
    /// is summed per side; what it faces on *both* sides is the smaller of the two sums. A pair
    /// repeats over as much of its own overlap as either of its lines faces both ways, and the
    /// class's share is that, weighted by overlap, over its whole facing length. Pure; `0` for
    /// no pairs.
    static func repeatingShare(of pairs: [GeometryParallelPairHighlight], segments: [UInt64: GeometryQuerySegment]) -> Double {
        // Facing length per line and side: index 0 the left of the line's own direction, 1 the right.
        var facing: [UInt64: (left: Double, right: Double)] = [:]
        func side(of point: CGPoint, from segment: GeometryQuerySegment) -> Bool {
            let cross = (segment.end.x - segment.start.x) * (point.y - segment.start.y)
                - (segment.end.y - segment.start.y) * (point.x - segment.start.x)
            return cross >= 0
        }
        func add(_ id: UInt64, left: Bool, _ length: Double) {
            var entry = facing[id] ?? (0, 0)
            if left { entry.left += length } else { entry.right += length }
            facing[id] = entry
        }
        var sides: [(first: UInt64, second: UInt64, length: Double)] = []
        sides.reserveCapacity(pairs.count)
        for pair in pairs {
            guard let first = segments[pair.firstPrimitiveID], let second = segments[pair.secondPrimitiveID] else { continue }
            // The facing span's centre lies between the two lines, so on each line's side of
            // the other.
            let q = pair.overlapQuad
            let centre = CGPoint(x: (q.c0.x + q.c1.x + q.c2.x + q.c3.x) / 4, y: (q.c0.y + q.c1.y + q.c2.y + q.c3.y) / 4)
            add(first.primitiveID, left: side(of: centre, from: first), pair.overlapLengthPoints)
            add(second.primitiveID, left: side(of: centre, from: second), pair.overlapLengthPoints)
            sides.append((first.primitiveID, second.primitiveID, pair.overlapLengthPoints))
        }
        var total = 0.0, repeating = 0.0
        for entry in sides where entry.length > 0 {
            let both = [entry.first, entry.second].map { id -> Double in
                let f = facing[id] ?? (0, 0)
                return Swift.min(f.left, f.right)
            }.max() ?? 0
            total += entry.length
            repeating += Swift.min(entry.length, both)
        }
        return total > 0 ? repeating / total : 0
    }

    struct Piece: Hashable {
        var start: CGPoint
        var end: CGPoint
        var length: Double { hypot(end.x - start.x, end.y - start.y) }
        var direction: CGPoint {
            let l = length
            return l > 0 ? CGPoint(x: (end.x - start.x) / l, y: (end.y - start.y) / l) : .zero
        }
    }

    func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    /// A break wider than a junction between two runs on one line, before it is judged an
    /// opening: from the end of one run to the start of the next, on a line of `thickness`.
    struct Gap: Hashable {
        var start: CGPoint
        var end: CGPoint
        var thickness: Double
        var width: Double { hypot(end.x - start.x, end.y - start.y) }
    }

    /// Collinear midlines merged along their line; junction gaps closed, openings listed. The
    /// openings are judged against this class's own runs only; ``takeoff()`` judges them against
    /// every class's.
    func merge(_ midlines: [Piece], thickness: Double) -> ([Piece], [Opening]) {
        let (runs, gaps) = mergeRuns(midlines, thickness: thickness)
        return (runs, openings(gaps, crossedBy: runs.map { (thickness: thickness, piece: $0) }))
    }

    /// Collinear midlines merged along their line, junction gaps closed; every wider gap is
    /// returned for ``openings(_:crossedBy:)`` to judge.
    func mergeRuns(_ midlines: [Piece], thickness: Double) -> ([Piece], [Gap]) {
        // Group by line: a piece joins a line when its direction matches the line's modulo π and
        // both its ends lie on the line, measured along the line's own normal.
        //
        // T-064: the angle is canonicalised into [0, π), which has a seam at 0 ≡ π. A
        // near-horizontal midline that rises by 1e-6 gets angle +1e-6, one that falls gets
        // π − 1e-6, and each piece's normal offset was taken against its own flipped normal
        // (+y against −y). The two pieces of one wall landed on separate lines: the door between
        // them was never listed, a junction gap was never closed and overlaps counted twice.
        struct Line { var angle: Double; var intervals: [(Double, Double)]; var origin: CGPoint; var direction: CGPoint }
        var lines: [Line] = []
        let angleTolerance = 1.5 * .pi / 180
        for piece in midlines where piece.length > 0 {
            var direction = piece.direction
            var angle = atan2(direction.y, direction.x)
            if angle < 0 { angle += .pi; direction = CGPoint(x: -direction.x, y: -direction.y) }
            if angle >= .pi - 1e-9 { angle -= .pi; direction = CGPoint(x: -direction.x, y: -direction.y) }
            func offset(_ p: CGPoint, from line: Line) -> Double {
                (p.x - line.origin.x) * -line.direction.y + (p.y - line.origin.y) * line.direction.x
            }
            let index = lines.firstIndex { line in
                let turn = abs(line.angle - angle)
                guard min(turn, .pi - turn) <= angleTolerance else { return false }
                return abs(offset(piece.start, from: line)) <= options.thicknessTolerancePoints
                    && abs(offset(piece.end, from: line)) <= options.thicknessTolerancePoints
            }
            func along(_ p: CGPoint, _ line: Line) -> Double {
                (p.x - line.origin.x) * line.direction.x + (p.y - line.origin.y) * line.direction.y
            }
            if let index {
                let a = along(piece.start, lines[index]), b = along(piece.end, lines[index])
                lines[index].intervals.append((min(a, b), max(a, b)))
            } else {
                var line = Line(angle: angle, intervals: [], origin: piece.start, direction: direction)
                let a = along(piece.start, line), b = along(piece.end, line)
                line.intervals.append((min(a, b), max(a, b)))
                lines.append(line)
            }
        }
        var merged: [Piece] = []
        var gaps: [Gap] = []
        let junctionGap = thickness * options.junctionGapFactor
        for line in lines {
            let sorted = line.intervals.sorted { $0.0 < $1.0 }
            var runs: [(Double, Double)] = []
            for interval in sorted {
                if var last = runs.last, interval.0 <= last.1 + junctionGap {
                    last.1 = max(last.1, interval.1)
                    runs[runs.count - 1] = last
                } else {
                    if let last = runs.last {
                        gaps.append(Gap(
                            start: CGPoint(x: line.origin.x + line.direction.x * last.1, y: line.origin.y + line.direction.y * last.1),
                            end: CGPoint(x: line.origin.x + line.direction.x * interval.0, y: line.origin.y + line.direction.y * interval.0),
                            thickness: thickness
                        ))
                    }
                    runs.append(interval)
                }
            }
            for run in runs where run.1 - run.0 > 0 {
                merged.append(Piece(start: CGPoint(x: line.origin.x + line.direction.x * run.0, y: line.origin.y + line.direction.y * run.0),
                                    end: CGPoint(x: line.origin.x + line.direction.x * run.1, y: line.origin.y + line.direction.y * run.1)))
            }
        }
        return (merged, gaps)
    }

    /// The openings among `gaps` (U-082).
    ///
    /// A wall whose centreline crosses a gap — or ends at the gap line's face, a T-junction — is
    /// a junction over its own footprint (its thickness, widened by the angle it crosses at).
    /// What is left of the gap on either side of every footprint is an opening when it is wider
    /// than a junction and no wider than ``Options/maximumOpeningPoints``; a wider remainder is
    /// two unrelated walls on one line and is not listed. So a 100 mm partition crossing a
    /// 200 mm wall lists nothing, and a door right beside a T-junction lists the door's own width.
    func openings(_ gaps: [Gap], crossedBy walls: [(thickness: Double, piece: Piece)]) -> [Opening] {
        let tolerance = options.thicknessTolerancePoints
        let minimumSine = sin(1.5 * .pi / 180)
        var openings: [Opening] = []
        for gap in gaps {
            let width = gap.width
            guard width > 0 else { continue }
            let along = CGPoint(x: (gap.end.x - gap.start.x) / width, y: (gap.end.y - gap.start.y) / width)
            var remaining: [(Double, Double)] = [(0, width)]
            for wall in walls {
                let direction = wall.piece.direction
                let sine = abs(along.x * direction.y - along.y * direction.x)
                guard sine > minimumSine,
                      let x = intersection(Piece(start: gap.start, end: gap.end), wall.piece) else { continue }
                let at = (x.x - gap.start.x) * along.x + (x.y - gap.start.y) * along.y
                guard at >= -tolerance, at <= width + tolerance else { continue }
                // The wall must reach the gap's line: through it, or ending at its face.
                let reach = gap.thickness / 2 / sine + tolerance
                let onWall = (x.x - wall.piece.start.x) * direction.x + (x.y - wall.piece.start.y) * direction.y
                guard onWall >= -reach, onWall <= wall.piece.length + reach else { continue }
                let half = wall.thickness / 2 / sine
                remaining = remaining.flatMap { part -> [(Double, Double)] in
                    let lower = (part.0, min(part.1, at - half)), upper = (max(part.0, at + half), part.1)
                    return [lower, upper].filter { $0.1 > $0.0 }
                }
            }
            let junctionGap = gap.thickness * options.junctionGapFactor
            for part in remaining where part.1 - part.0 > junctionGap && part.1 - part.0 <= options.maximumOpeningPoints {
                let middle = (part.0 + part.1) / 2
                openings.append(Opening(midpoint: CGPoint(x: gap.start.x + along.x * middle, y: gap.start.y + along.y * middle),
                                        widthPoints: part.1 - part.0))
            }
        }
        return openings
    }

    /// Extends the ends of two pieces that meet at an L-corner to their intersection. An end is
    /// extended only when the other piece also ends there: at a T-junction the other piece runs
    /// on, and the stopping wall stays stopped at its face.
    func extendCorners(_ pieces: inout [(Double, Piece)]) {
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                let (ti, a) = pieces[i], (tj, b) = pieces[j]
                let cross = a.direction.x * b.direction.y - a.direction.y * b.direction.x
                guard abs(cross) > 0.5 else { continue }   // not a corner: within 30° of parallel
                guard let x = intersection(a, b) else { continue }
                let reach = (ti + tj) / 2 + options.thicknessTolerancePoints
                func nearEnd(_ p: Piece) -> (isStart: Bool, distance: Double) {
                    let ds = hypot(p.start.x - x.x, p.start.y - x.y), de = hypot(p.end.x - x.x, p.end.y - x.y)
                    return ds <= de ? (true, ds) : (false, de)
                }
                let ea = nearEnd(a), eb = nearEnd(b)
                guard ea.distance <= reach, eb.distance <= reach else { continue }
                var na = a, nb = b
                if ea.isStart { na.start = x } else { na.end = x }
                if eb.isStart { nb.start = x } else { nb.end = x }
                pieces[i].1 = na
                pieces[j].1 = nb
            }
        }
    }

    func intersection(_ a: Piece, _ b: Piece) -> CGPoint? {
        let r = CGPoint(x: a.end.x - a.start.x, y: a.end.y - a.start.y)
        let s = CGPoint(x: b.end.x - b.start.x, y: b.end.y - b.start.y)
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((b.start.x - a.start.x) * s.y - (b.start.y - a.start.y) * s.x) / denominator
        return CGPoint(x: a.start.x + r.x * t, y: a.start.y + r.y * t)
    }

    /// Pieces that share an end joined into polylines; a closed loop repeats its first point.
    func chain(_ pieces: [Piece]) -> [[CGPoint]] {
        var remaining = pieces
        var chains: [[CGPoint]] = []
        func same(_ p: CGPoint, _ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= 1e-6 }
        while !remaining.isEmpty {
            let first = remaining.removeFirst()
            var line = [first.start, first.end]
            var grew = true
            while grew {
                grew = false
                if let index = remaining.firstIndex(where: { same($0.start, line.last!) || same($0.end, line.last!) }) {
                    let piece = remaining.remove(at: index)
                    line.append(same(piece.start, line.last!) ? piece.end : piece.start)
                    grew = true
                } else if let index = remaining.firstIndex(where: { same($0.start, line.first!) || same($0.end, line.first!) }) {
                    let piece = remaining.remove(at: index)
                    line.insert(same(piece.start, line.first!) ? piece.end : piece.start, at: 0)
                    grew = true
                }
            }
            chains.append(line)
        }
        // Largest first, then by position, so the proposal list is stable.
        return chains.sorted { lhs, rhs in
            let l = lhs.count, r = rhs.count
            if l != r { return l > r }
            return (lhs.first?.x ?? 0, lhs.first?.y ?? 0) < (rhs.first?.x ?? 0, rhs.first?.y ?? 0)
        }
    }
}
