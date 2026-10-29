import Foundation
import ZPDFContracts

/// Even-odd containment in one ring, answered from the ring edges that cross the point's height
/// only (L-73).
///
/// ``RegionTracer/encloses(_:_:)`` scans every edge of the ring, which is right for one point
/// and quadratic for the tens of thousands of points the island search and the room detector
/// test against a ring of thousands of vertices. The ring's height is cut into bands and every
/// edge is listed in each band its y-extent touches; an edge that crosses a horizontal line
/// through the point has the point's height inside its y-extent, so it is in the point's band.
/// The crossing test is the scan's own expression on the same edges in the same order, so the
/// answer is the scan's answer, bit for bit.
package struct RingContainment {
    private let ring: [PDFPoint]
    private let minY: Double
    private let bandHeight: Double
    /// For each band, the indices `i` of the edges `ring[i] – ring[i - 1]` (wrapping) it holds,
    /// ascending — the order the scan visits them.
    private let bands: [[Int]]

    package init(_ ring: [PDFPoint]) {
        self.ring = ring
        let ys = ring.map(\.y)
        guard ring.count >= 3, let low = ys.min(), let high = ys.max(), high > low, low.isFinite, high.isFinite else {
            self.minY = 0
            self.bandHeight = 1
            self.bands = []
            return
        }
        let count = Swift.min(4_096, Swift.max(1, ring.count / 2))
        let height = (high - low) / Double(count)
        self.minY = low
        self.bandHeight = height
        // The band range of every edge first: a ring whose edges each span most of its height —
        // a zig-zag — would list every edge in every band, so past a few entries per edge the
        // index is not built and every query is the scan.
        var spans: [(first: Int, last: Int)] = []
        spans.reserveCapacity(ring.count)
        var entries = 0
        var j = ring.count - 1
        for i in ring.indices {
            let first = Self.band(Swift.min(ring[i].y, ring[j].y), minY: low, height: height, count: count)
            let last = Self.band(Swift.max(ring[i].y, ring[j].y), minY: low, height: height, count: count)
            spans.append((first, last))
            entries += last - first + 1
            j = i
        }
        guard entries <= 16 * ring.count + 4_096 else {
            self.bands = []
            return
        }
        var bands = [[Int]](repeating: [], count: count)
        for (i, span) in spans.enumerated() {
            for band in span.first...span.last { bands[band].append(i) }
        }
        self.bands = bands
    }

    private static func band(_ y: Double, minY: Double, height: Double, count: Int) -> Int {
        let raw = ((y - minY) / height).rounded(.down)
        guard raw.isFinite else { return 0 }
        return Int(Swift.max(0, Swift.min(Double(count - 1), raw)))
    }

    /// `RegionTracer.encloses(ring, point)`.
    package func encloses(_ point: PDFPoint) -> Bool {
        guard !bands.isEmpty else { return RegionTracer.encloses(ring, point) }
        let band = Self.band(point.y, minY: minY, height: bandHeight, count: bands.count)
        // A point above or below the ring crosses nothing, which is what the scan finds too;
        // clamping it into the outermost band only tests edges that cannot cross it.
        var inside = false
        let count = ring.count
        for i in bands[band] {
            let a = ring[i]
            let b = ring[(i + count - 1) % count]
            if (a.y > point.y) != (b.y > point.y) {
                let x = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if point.x < x { inside.toggle() }
            }
        }
        return inside
    }
}
