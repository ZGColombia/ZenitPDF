import Foundation
import ZPDFContracts
import ZPDFGeometry

// MARK: - A dashed line through the room is not a wall with an opening (L-73)

/// Tells two loose ends aimed at each other across a run of dashes from two wall ends aimed at
/// each other across a doorway.
///
/// # The case this exists for
///
/// A real drawing is crossed by dash-dot lines — grid axes, centre lines, section lines — and a
/// CAD export writes each dash as a separate solid stroke: a grid axis at 1:50 is typically
/// 20 pt dashes and 5 pt dots with gaps of 3 to 4 pt, one stroke each. The dash that crosses a
/// room's wall is split there and hangs into the room as a spur; so does the dash where the
/// axis leaves through the far wall. The two spur ends are collinear and point at each other,
/// which is exactly the signature `brokenWallPair` reads as a door, so every room an axis
/// crossed was refused as "not closed".
///
/// # The rule
///
/// Two **loose ends** are a dashed line, not an opening, only when both hold:
///
/// 1. **Dashes between them.** The drawn pieces lying on the line between the two ends — within
///    ``TraceOptions/joinTolerance`` of it, along its direction — cover at least half of the gap
///    and leave no uncovered stretch wider than ``maximumDashGap(_:)``.
/// 2. **The pattern goes on past each end.** Outward from each loose end, the run of drawn
///    pieces that holds it — its own dash, through or up to the wall it hangs from — is no
///    longer than the longest dash between the ends; the next piece on the line starts within
///    ``maximumDashGap(_:)`` of it; and that piece's run is no longer than that dash either.
///
/// Jambs are never a dashed line: a wall drawn with thickness is a wall. The first rule alone
/// was too wide: a threshold or a closed leaf drawn on the wall line a few points short of each
/// jamb covers most of a doorway with no gap over the cap, and the room was committed merged
/// with the corridor (L-73 re-check). Such a doorway fails the second rule — outward from each
/// wall end the run is the wall itself, longer than the leaf, and nothing resumes past the
/// room's corner — so it is an opening, refused, and proposed for closing as before.
///
/// The second rule does not ask whether a dash crosses the wall it hangs from. On a roof plan
/// it often does not: a dash of an axis can stop a couple of points short of a hip line and be
/// bridged to it, so the dash and a wall ending at a T-junction are the same shape in the
/// arrangement. What tells them apart is what lies on the line beyond: the axis resumes, dash
/// after gap after dash; a wall line beside a door ends at the corner, or runs on as a wall.
///
/// Both rules read the page's segments rather than the window's arrangement, so the answer does
/// not depend on how far the working window had grown when the face was judged.
///
/// # What it costs
///
/// A doorway with a dashed line drawn exactly along the wall line through it — an overhead
/// beam on the wall axis, say — is read as no opening, and the face beyond it joins the room.
/// The traced ring then runs round both, visibly, rather than being refused. So is a doorway
/// whose wall line is itself drawn in short pieces either side of it, each no longer than a
/// leaf drawn across it, with gaps under the cap — a wall line that is, to the drawing, dashed.
/// A room crossed by an axis whose last dash ends at the wall is refused at the axis.
final class DashedLineProbe {
    private let prepared: PreparedTrace
    private let options: TraceOptions

    init(prepared: PreparedTrace) {
        self.prepared = prepared
        self.options = prepared.options
    }

    /// The widest uncovered stretch a dashed line may have between two dashes, page points:
    /// four bridging tolerances, 12 pt (4.2 mm of paper) by default. Line-type gaps are a few
    /// millimetres of paper whatever the scale.
    static func maximumDashGap(_ options: TraceOptions) -> Double { options.gapTolerance * 4 }

    private var tolerance: Double { Swift.max(options.joinTolerance, 1e-9) }

    /// `true` when the gap between `a` and `b` is a dashed line's, per the rule above.
    func isDashedLine(_ a: RegionTracer.Stop, _ b: RegionTracer.Stop) -> Bool {
        guard !a.isJamb, !b.isJamb else { return false }
        let dx = b.point.x - a.point.x
        let dy = b.point.y - a.point.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0, length.isFinite else { return false }
        let forward = (x: dx / length, y: dy / length)
        let gapCap = Self.maximumDashGap(options)

        // 1. Dashes between the two ends.
        let between = pieces(from: a.point, along: forward, over: 0...length)
        guard !between.isEmpty else { return false }
        var cursor = 0.0
        var total = 0.0
        // The longest dash: a run of pieces that touch or overlap, within the join tolerance.
        var longest = 0.0
        var runLow: Double?
        for piece in between {
            if piece.low - cursor > gapCap { return false }
            if let low = runLow, piece.low > cursor + tolerance {
                longest = Swift.max(longest, cursor - low)
                runLow = nil
            }
            if runLow == nil { runLow = piece.low }
            if piece.high > cursor {
                total += piece.high - Swift.max(piece.low, cursor)
                cursor = piece.high
            }
        }
        if let low = runLow { longest = Swift.max(longest, cursor - low) }
        if length - cursor > gapCap { return false }
        guard total >= length / 2 else { return false }

        // 2. The pattern goes on past each end.
        let dashCap = longest + tolerance
        return continuesPast(a.point, outward: (-forward.x, -forward.y), dashCap: dashCap, gapCap: gapCap)
            && continuesPast(b.point, outward: forward, dashCap: dashCap, gapCap: gapCap)
    }

    /// `true` when the run of drawn pieces holding `stop`, measured outward from it, is no longer
    /// than `dashCap`, the next piece on the line starts within `gapCap` of its end, and the run
    /// that piece starts is no longer than `dashCap` either: one dash, a gap, another dash.
    private func continuesPast(
        _ stop: PDFPoint,
        outward: (x: Double, y: Double),
        dashCap: Double,
        gapCap: Double
    ) -> Bool {
        let tolerance = self.tolerance
        // Far enough that a next run clipped at the reach measures longer than the cap.
        let reach = 2 * dashCap + gapCap + 3 * tolerance
        let found = pieces(from: stop, along: outward, over: -tolerance...reach)
        /// The end of the run of touching pieces that starts at `found[index]`, and the index
        /// after it.
        func run(from index: Int, at start: Double) -> (end: Double, next: Int) {
            var cursor = start
            var index = index
            while index < found.count, found[index].low <= cursor + tolerance {
                cursor = Swift.max(cursor, found[index].high)
                index += 1
            }
            return (cursor, index)
        }
        let own = run(from: 0, at: 0)
        guard own.end > tolerance, own.end <= dashCap, own.next < found.count else { return false }
        let gapStart = own.end
        let resumed = found[own.next].low
        guard resumed - gapStart <= gapCap else { return false }
        let following = run(from: own.next, at: resumed)
        return following.end - resumed <= dashCap
    }

    /// The page's segments lying on the line through `origin` along the unit `direction` —
    /// both ends within the join tolerance of it — as intervals of distance along it, clipped to
    /// `range` and sorted.
    private func pieces(
        from origin: PDFPoint,
        along direction: (x: Double, y: Double),
        over range: ClosedRange<Double>
    ) -> [(low: Double, high: Double)] {
        let tolerance = self.tolerance
        let start = PDFPoint(x: origin.x + direction.x * range.lowerBound, y: origin.y + direction.y * range.lowerBound)
        let end = PDFPoint(x: origin.x + direction.x * range.upperBound, y: origin.y + direction.y * range.upperBound)
        var result: [(low: Double, high: Double)] = []
        for segment in prepared.segments(intersecting: PDFRect(corner: start, opposite: end).outsetBy(tolerance)) {
            let p = segment.start
            let q = segment.end
            let offP = Swift.abs((p.x - origin.x) * direction.y - (p.y - origin.y) * direction.x)
            let offQ = Swift.abs((q.x - origin.x) * direction.y - (q.y - origin.y) * direction.x)
            // Both ends on the line: a piece of it, not a stroke crossing it.
            guard offP <= tolerance, offQ <= tolerance else { continue }
            let sP = (p.x - origin.x) * direction.x + (p.y - origin.y) * direction.y
            let sQ = (q.x - origin.x) * direction.x + (q.y - origin.y) * direction.y
            let low = Swift.max(range.lowerBound, Swift.min(sP, sQ))
            let high = Swift.min(range.upperBound, Swift.max(sP, sQ))
            if high > low { result.append((low, high)) }
        }
        result.sort { $0.low != $1.low ? $0.low < $1.low : $0.high < $1.high }
        return result
    }
}
