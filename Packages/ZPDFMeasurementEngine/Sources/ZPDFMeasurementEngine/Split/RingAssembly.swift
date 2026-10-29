import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// Rebuilds ``PolygonGeometry`` values from the flat ring soup a Clipper2 boolean returns.
///
/// Clipper2 hands back a `ClipperPaths` — a list of rings with no nesting information attached.
/// The nesting is carried in the winding: under the non-zero rule an outer ring and the holes
/// inside it wind opposite ways, which is the same fact `CutoutSolver` relies on when it takes
/// the signed sum of a difference to get a net area.
///
/// Two things here are deliberately not assumed:
///
/// * **Which sign means "outer".** Rather than hard-coding that outer rings come back
///   counter-clockwise, the sign that means "outer" is derived from the result itself: the
///   signed sum over all rings is the region's area, which is positive, so whichever sign
///   agrees with that sum is the outer sign. A change of convention in a future Clipper2 cannot
///   silently invert holes into islands.
/// * **That a hole belongs to the only outer ring.** One side of a cut can be several
///   disconnected pieces, each with its own holes, so every hole is matched to its own outer
///   ring by containment and, among containing rings, to the smallest.
enum RingAssembly {

    /// Number of hole vertices sampled when deciding which outer ring a hole sits in.
    ///
    /// A hole is strictly inside exactly one outer ring, so one vertex would settle it — except
    /// that a hole may *touch* its outer ring at a vertex, where an exact on-lattice
    /// point-in-polygon test reports "on boundary" for a ring the hole does not belong to.
    /// Sampling a handful of vertices and taking a majority removes that ambiguity without
    /// turning the assembly into an O(holes x outers x vertices) sweep on traced geometry.
    static let containmentSamples = 9

    static func polygons(
        from paths: ClipperPaths,
        options: MeasurementEngineOptions
    ) throws(MeasurementEngineError) -> [PolygonGeometry] {
        let rings = paths.filter { $0.count >= 3 }
        guard !rings.isEmpty else { return [] }

        // The signed total is the region's area and is therefore positive; the sign that agrees
        // with it is the sign of an outer ring.
        let outerSign: Double = Clipper2.area(of: rings) >= 0 ? 1 : -1

        var outers: [(ring: ClipperPath, area: Double)] = []
        var holes: [ClipperPath] = []
        for ring in rings {
            let signed = Clipper2.area(of: ring) * outerSign
            // A zero-area spike is an artefact of the boolean, never a part and never a hole.
            guard Swift.abs(signed) > options.epsilon.areaFloor else { continue }
            if signed > 0 {
                outers.append((ring: ring, area: signed))
            } else {
                holes.append(ring)
            }
        }
        guard !outers.isEmpty else { return [] }

        var assigned: [[ClipperPath]] = Array(repeating: [], count: outers.count)
        let outerBoxes = outers.map { bounds(of: $0.ring, grownBy: 1 / options.clipperScale.value) }
        for hole in holes {
            let owner = try owner(of: hole, among: outers, boxes: outerBoxes, options: options)
            assigned[owner].append(hole)
        }

        var result: [PolygonGeometry] = []
        result.reserveCapacity(outers.count)
        for (index, outer) in outers.enumerated() {
            result.append(
                PolygonGeometry(
                    outer: ring(from: outer.ring, counterClockwise: true),
                    holes: assigned[index].map { ring(from: $0, counterClockwise: false) }
                )
            )
        }
        return result
    }

    /// The index of the smallest outer ring that contains `hole`.
    ///
    /// Falls back to the smallest outer ring overall if containment cannot be established, so
    /// the hole is never silently dropped — dropping it would inflate a part's net area, and an
    /// inflated area is the exact failure this feature must not produce. A misplaced hole shows
    /// up in ``PolygonSplitter/areaCheck(original:parts:)`` as a real error; a dropped one would
    /// too, but only after it had already changed a number.
    ///
    /// `boxes` (IM-193), when given, holds each outer ring's bounds grown by one lattice step. A
    /// sample outside an outer's box cannot be inside the outer, so an outer whose box holds no
    /// majority of the samples is skipped before any `Clipper2.contains` call. The skip is a
    /// necessary condition of the majority test, not a heuristic, so the owner is identical with
    /// and without it; the lattice step covers `contains` rounding a point onto the boundary.
    static func owner(
        of hole: ClipperPath,
        among outers: [(ring: ClipperPath, area: Double)],
        boxes: [CGRect]? = nil,
        options: MeasurementEngineOptions
    ) throws(MeasurementEngineError) -> Int {
        let samples = sampled(hole, count: containmentSamples)
        var best: Int?
        var bestArea = Double.greatestFiniteMagnitude
        for (index, outer) in outers.enumerated() {
            if let boxes {
                let box = boxes[index]
                var inBox = 0
                for point in samples where Self.inclusivelyContains(box, point) { inBox += 1 }
                guard inBox * 2 > samples.count else { continue }
            }
            var hits = 0
            for point in samples {
                let inside: Bool
                do {
                    inside = try Clipper2.contains(
                        point,
                        in: outer.ring,
                        includingBoundary: true,
                        scale: options.clipperScale
                    )
                } catch {
                    throw MeasurementEngineError.clipper(error)
                }
                if inside { hits += 1 }
            }
            guard hits * 2 > samples.count else { continue }
            if outer.area < bestArea {
                bestArea = outer.area
                best = index
            }
        }
        if let best { return best }

        var smallest = 0
        for (index, outer) in outers.enumerated() where outer.area < outers[smallest].area {
            smallest = index
        }
        return smallest
    }

    /// A ring's bounding box grown by `margin` on every side.
    static func bounds(of ring: ClipperPath, grownBy margin: Double) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in ring {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        return CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
    }

    /// Box containment with every edge included (`CGRect.contains` excludes the max edges; the
    /// ring containment test includes the boundary).
    private static func inclusivelyContains(_ box: CGRect, _ point: CGPoint) -> Bool {
        point.x >= box.minX && point.x <= box.maxX && point.y >= box.minY && point.y <= box.maxY
    }

    /// Up to `count` vertices spread evenly around the ring.
    private static func sampled(_ ring: ClipperPath, count: Int) -> [CGPoint] {
        guard ring.count > count else { return ring }
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(ring[index * ring.count / count])
        }
        return result
    }

    /// A ``PolygonRing`` in the requested winding, closed, with no repeated closing vertex.
    ///
    /// Canonical winding is not required by anything downstream — `CutoutSolver` takes
    /// absolute areas, on purpose, because real files get winding wrong — but a stored part that winds the same way every time is one less thing for a
    /// golden test or a diff to be noisy about.
    private static func ring(from path: ClipperPath, counterClockwise: Bool) -> PolygonRing {
        let isCounterClockwise = Clipper2.area(of: path) >= 0
        let ordered = isCounterClockwise == counterClockwise ? path : Array(path.reversed())
        return PolygonRing(points: ordered.map(CutoutSolver.pdfPoint), isClosed: true)
    }
}
