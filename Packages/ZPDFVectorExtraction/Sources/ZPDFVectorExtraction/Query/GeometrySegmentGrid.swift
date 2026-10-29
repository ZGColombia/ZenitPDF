import CoreGraphics
import Foundation

/// A uniform spatial grid over segments, additionally bucketed by line angle.
///
/// The parallel-pair query is a nearest-neighbour question with two independent filters —
/// *close enough* and *near enough to parallel* — so the index applies both. Without it
/// the query is `O(n²)`: a page with 100 000 primitives is five billion pair tests.
///
/// **Why the grid is correct.** Cell size is at least `gap + tolerance`, so two segments
/// that can possibly pair have points within one cell of each other, and a query over the
/// first segment's bounds grown by `gap + tolerance` cannot miss the second. Segments are
/// inserted into **every** cell they cross — an incremental grid traversal, not a
/// bounding-box stamp — so a long diagonal is present where it actually is rather than in
/// the `O(L²/c²)` cells its box covers.
///
/// **Why the angle bucket is correct.** Bucket width is at least the angle tolerance, so
/// two segments within tolerance of each other land in the same bucket or in an adjacent
/// one. Buckets wrap, because a line at 179.5° and a line at 0.2° are 0.7° apart. Wider
/// buckets than the tolerance are always safe; narrower ones would not be, which is why
/// the bucket count is only ever clamped downwards.
///
/// **Why there is no dictionary here.** The index is built by a counting sort into two
/// flat `Int32` arrays: `slotStart` delimits each `(cell, bucket)` slot's run inside
/// `entries`. A `Dictionary` keyed by a struct hashes on every probe, and this query
/// probes millions of times — measured at roughly 3 µs per probe in a debug build, which
/// is the whole budget spent on bookkeeping. Plain array indexing costs nothing.
struct GeometrySegmentGrid {
    /// The index is dense over `columns × rows × bucketCount`. When that product would
    /// exceed this, the cells are made coarser until it fits — coarser is always correct,
    /// only slower, whereas a finer grid than `gap + tolerance` would lose pairs.
    static let maximumSlotCount = 4_000_000
    /// Clamped downwards only: a coarser angle bucket than the tolerance is safe.
    static let maximumAngleBuckets = 1024
    /// A segment that would cross more cells than this is stamped by its bounding box
    /// instead — conservative, so it cannot lose a pair.
    static let maximumCellsPerSegment = 4096

    let cellSize: Double
    let originX: Double
    let originY: Double
    let columns: Int
    let rows: Int
    let bucketCount: Int
    /// The angle bucket of each segment, in the order the segments were given.
    let buckets: [Int32]
    /// `entries[slotStart[s] ..< slotStart[s + 1]]` are the segment indices in slot `s`.
    let slotStart: [Int32]
    let entries: [Int32]

    init(
        segments: [GeometryQuerySegment],
        angles: [Double],
        reach: Double,
        angleToleranceRadians: Double
    ) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for segment in segments {
            minX = Swift.min(minX, Swift.min(segment.start.x, segment.end.x))
            minY = Swift.min(minY, Swift.min(segment.start.y, segment.end.y))
            maxX = Swift.max(maxX, Swift.max(segment.start.x, segment.end.x))
            maxY = Swift.max(maxY, Swift.max(segment.start.y, segment.end.y))
        }
        if !minX.isFinite || !maxX.isFinite { minX = 0; maxX = 0 }
        if !minY.isFinite || !maxY.isFinite { minY = 0; maxY = 0 }

        let bucketTotal: Int
        if angleToleranceRadians > 0, angleToleranceRadians.isFinite {
            // Rounded *down*, so `π / bucketTotal ≥ tolerance` and the header's argument
            // holds. Rounding up gave `ceil(π / tol)` buckets each narrower than the
            // tolerance whenever `π / tol` was not an integer, and two segments within
            // tolerance could then sit two buckets apart — outside the centre ± 1 probe —
            // and be silently absent from a result reported `.complete` (BH-325, BH-326).
            // The 1.5° default divides 180° exactly, which is why nothing caught it.
            let wanted = (Double.pi / angleToleranceRadians).rounded(.down)
            bucketTotal = Int(Swift.max(1, Swift.min(wanted, Double(Self.maximumAngleBuckets))))
        } else {
            bucketTotal = 1
        }

        // Grow the cells until the dense index fits. Every step is a doubling.
        //
        // A drawing that does not fit within a few doublings is not a big drawing but a
        // hostile one: the scanner keeps any finite coordinate, so one `l` to `x = 1e30`
        // reaches this index with its other end on the sheet. Doubling towards that
        // point used to give up after 64 steps and allocate `4e6 × 4e6 × buckets` slots —
        // a petabyte, a trap — and short of that it fitted only by collapsing the whole
        // real drawing into one cell, an `n²` query (BH-060, BH-327). So when the full
        // extent does not fit at a modest cell size, the extent is re-measured without
        // the outlying endpoints and doubling resumes from the reach; coordinates past the
        // covered extent clamp into the edge cells, which keeps every pair reachable (a
        // clamped segment is in the last cell, and a partner within reach of it either is
        // too or probes that cell) at the cost of a few extra comparisons on the edge.
        // The second loop is unbounded on purpose: a span over an infinite cell size is
        // one cell, so it terminates within about 1 100 doublings whatever the input.
        let baseSize = reach.isFinite && reach > 0 ? reach : 1
        var size = baseSize
        var width = maxX - minX
        var height = maxY - minY
        let cellBudget = Self.maximumSlotCount / bucketTotal
        var columnCount = 1
        var rowCount = 1
        var fitted = false
        for _ in 0..<Self.uniformDoublingLimit {
            columnCount = Self.cellCount(span: width, size: size)
            rowCount = Self.cellCount(span: height, size: size)
            if columnCount * rowCount <= cellBudget {
                fitted = true
                break
            }
            size *= 2
        }
        if !fitted {
            let xExtent = Self.robustExtent(segments, \.x)
            let yExtent = Self.robustExtent(segments, \.y)
            minX = xExtent.low
            maxX = xExtent.high
            minY = yExtent.low
            maxY = yExtent.high
            width = maxX - minX
            height = maxY - minY
            size = baseSize
            while true {
                columnCount = Self.cellCount(span: width, size: size)
                rowCount = Self.cellCount(span: height, size: size)
                if columnCount * rowCount <= cellBudget { break }
                size *= 2
            }
        }

        var bucketOf = [Int32](repeating: 0, count: segments.count)
        let bucketWidth = Double.pi / Double(bucketTotal)
        for index in segments.indices {
            let raw = Int((angles[index] / bucketWidth).rounded(.down))
            bucketOf[index] = Int32(((raw % bucketTotal) + bucketTotal) % bucketTotal)
        }

        let slotCount = columnCount * rowCount * bucketTotal
        var counts = [Int32](repeating: 0, count: slotCount + 1)

        // Pass one: how many entries land in each slot.
        let walker = Walker(
            originX: minX,
            originY: minY,
            cellSize: size,
            columns: columnCount,
            rows: rowCount
        )
        for index in segments.indices {
            let bucket = Int(bucketOf[index])
            walker.visit(segments[index]) { cell in
                counts[cell * bucketTotal + bucket + 1] += 1
            }
        }
        for slot in 1...slotCount { counts[slot] += counts[slot - 1] }

        // Pass two: fill. The walk is deterministic, so the two passes agree exactly.
        var cursor = counts
        var filled = [Int32](repeating: 0, count: Int(counts[slotCount]))
        for index in segments.indices {
            let bucket = Int(bucketOf[index])
            let value = Int32(index)
            walker.visit(segments[index]) { cell in
                let slot = cell * bucketTotal + bucket
                filled[Int(cursor[slot])] = value
                cursor[slot] += 1
            }
        }

        originX = minX
        originY = minY
        cellSize = size
        columns = columnCount
        rows = rowCount
        bucketCount = bucketTotal
        buckets = bucketOf
        slotStart = counts
        entries = filled
    }

    /// Doublings from the reach tried over the full extent before the extent is treated
    /// as hostile. `2¹⁰` cells of 301 pt is a 300 000 pt sheet — a hundred metres of
    /// paper — so nothing a person drew ever reaches the robust path.
    static let uniformDoublingLimit = 10

    /// The share of endpoints, per end, that the robust extent leaves outside the grid.
    static let robustTrimShare = 0.005

    /// The extent of one coordinate with the outlying endpoints set aside: the range
    /// between the `robustTrimShare` and `1 − robustTrimShare` quantiles of all endpoint
    /// coordinates, at least one endpoint trimmed from each end. Falls back to the full
    /// extent when there is nothing to trim.
    static func robustExtent(
        _ segments: [GeometryQuerySegment], _ axis: KeyPath<CGPoint, CGFloat>
    ) -> (low: Double, high: Double) {
        var values: [Double] = []
        values.reserveCapacity(segments.count * 2)
        for segment in segments {
            values.append(segment.start[keyPath: axis])
            values.append(segment.end[keyPath: axis])
        }
        values.sort()
        let trim = Swift.max(1, Int(Double(values.count) * robustTrimShare))
        guard values.count > 2 * trim else {
            return (values.first ?? 0, values.last ?? 0)
        }
        return (values[trim], values[values.count - 1 - trim])
    }

    private static func cellCount(span: Double, size: Double) -> Int {
        guard span.isFinite, span > 0 else { return 1 }
        let raw = (span / size).rounded(.down) + 1
        guard raw.isFinite else { return 1 }
        return Int(Swift.max(1, Swift.min(raw, Double(Self.maximumSlotCount))))
    }

    func column(forX x: Double) -> Int {
        Self.index(x, origin: originX, size: cellSize, limit: columns)
    }

    func row(forY y: Double) -> Int {
        Self.index(y, origin: originY, size: cellSize, limit: rows)
    }

    private static func index(_ value: Double, origin: Double, size: Double, limit: Int) -> Int {
        guard value.isFinite else { return 0 }
        let raw = ((value - origin) / size).rounded(.down)
        if raw <= 0 { return 0 }
        if raw >= Double(limit - 1) { return limit - 1 }
        return Int(raw)
    }

    /// The `entries` range of one slot.
    func range(column: Int, row: Int, bucket: Int) -> Range<Int> {
        let slot = (row * columns + column) * bucketCount + bucket
        return Int(slotStart[slot])..<Int(slotStart[slot + 1])
    }

    /// Amanatides–Woo grid traversal, reused across both build passes so the two agree
    /// exactly on which cells a segment occupies.
    struct Walker {
        let originX: Double
        let originY: Double
        let cellSize: Double
        let columns: Int
        let rows: Int

        func clampedColumn(_ x: Double) -> Int {
            GeometrySegmentGrid.index(x, origin: originX, size: cellSize, limit: columns)
        }

        func clampedRow(_ y: Double) -> Int {
            GeometrySegmentGrid.index(y, origin: originY, size: cellSize, limit: rows)
        }

        /// Calls `body` once per cell the segment passes through, as a flat cell index.
        func visit(_ segment: GeometryQuerySegment, _ body: (Int) -> Void) {
            let p = segment.start
            let q = segment.end
            var column = clampedColumn(p.x)
            var row = clampedRow(p.y)
            let endColumn = clampedColumn(q.x)
            let endRow = clampedRow(q.y)

            body(row * columns + column)
            if column == endColumn, row == endRow { return }

            let dx = q.x - p.x
            let dy = q.y - p.y
            let stepX = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
            let stepY = dy > 0 ? 1 : (dy < 0 ? -1 : 0)

            var tMaxX = Double.infinity
            var tDeltaX = Double.infinity
            if stepX != 0 {
                let edge = column + (stepX > 0 ? 1 : 0)
                tMaxX = (originX + Double(edge) * cellSize - p.x) / dx
                tDeltaX = cellSize / abs(dx)
            }
            var tMaxY = Double.infinity
            var tDeltaY = Double.infinity
            if stepY != 0 {
                let edge = row + (stepY > 0 ? 1 : 0)
                tMaxY = (originY + Double(edge) * cellSize - p.y) / dy
                tDeltaY = cellSize / abs(dy)
            }

            let span = abs(endColumn - column) + abs(endRow - row) + 2
            let budget = Swift.min(span, GeometrySegmentGrid.maximumCellsPerSegment)
            var steps = 0
            while (column != endColumn || row != endRow), steps < budget {
                // The end cell is *clamped* — an endpoint a hair past the last boundary is
                // in the last cell — but the crossing parameters are not, so on an axis
                // that has already reached its end cell the walk could take one more step
                // and name a cell outside the grid (CR-47). An axis that has arrived is
                // therefore never advanced again, and the advance is clamped besides.
                let advanceX: Bool
                if column == endColumn {
                    advanceX = false
                } else if row == endRow {
                    advanceX = true
                } else {
                    advanceX = tMaxX < tMaxY
                }
                if advanceX {
                    column = Swift.min(Swift.max(column + stepX, 0), columns - 1)
                    tMaxX += tDeltaX
                } else {
                    row = Swift.min(Swift.max(row + stepY, 0), rows - 1)
                    tMaxY += tDeltaY
                }
                steps += 1
                body(row * columns + column)
            }
            // A traversal cut short by the budget would leave part of the segment
            // unindexed, so fall back to stamping the whole box: more cells, never fewer.
            guard steps >= budget, column != endColumn || row != endRow else { return }
            let c0 = Swift.min(clampedColumn(p.x), endColumn)
            let c1 = Swift.max(clampedColumn(p.x), endColumn)
            let r0 = Swift.min(clampedRow(p.y), endRow)
            let r1 = Swift.max(clampedRow(p.y), endRow)
            for r in r0...r1 {
                for c in c0...c1 {
                    body(r * columns + c)
                }
            }
        }
    }
}
