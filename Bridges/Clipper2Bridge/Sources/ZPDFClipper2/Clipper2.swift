import CClipper2
import CoreGraphics

/// A polygon: an implicitly closed ring of vertices. The final vertex need not
/// repeat the first one.
public typealias ClipperPath = [CGPoint]

/// A polygon soup: outer rings and holes together, interpreted by a fill rule.
public typealias ClipperPaths = [[CGPoint]]

/// Swift facade over the vendored Clipper2 C++ library.
///
/// No C++ type ever crosses this module boundary: `ZPDFClipper2` talks to a
/// hand-written `extern "C"` shim (`CClipper2`), so the package builds with a
/// plain `swift build` under Command Line Tools with Swift/C++ interop off.
///
/// All coordinates are caller-space `Double`s (PDF page points in Zenit PDF)
/// and are quantised onto an integer lattice — see ``ClipperScale`` for the
/// precision contract. Every operation is a pure function of its arguments:
/// no clocks, no identifiers, no global state, deterministic across runs.
public enum Clipper2: Sendable {

    // MARK: - Boolean operations

    /// Union of `subjects` with `clips`. Passing no clips normalises the
    /// subjects: self-intersections are resolved and coincident edges merged.
    ///
    /// - Parameter preservingCollinearVertices: Clipper2 keeps vertices that sit
    ///   on a straight edge; this bridge drops them by default so that results
    ///   are minimal-vertex and stable (unioning a 40x40 grid of abutting unit
    ///   squares yields a 4-vertex rectangle, not a 160-vertex one). Pass `true`
    ///   to get upstream Clipper2's behaviour.
    public static func union(
        _ subjects: ClipperPaths,
        _ clips: ClipperPaths = [],
        fillRule: ClipperFillRule = .nonZero,
        preservingCollinearVertices: Bool = false,
        scale: ClipperScale = .pagePoints
    ) throws(ClipperError) -> ClipperPaths {
        try boolean(ZPCLIPPER2_CLIP_UNION, subjects, clips, fillRule, preservingCollinearVertices, scale)
    }

    /// Intersection of `subjects` with `clips`.
    public static func intersection(
        _ subjects: ClipperPaths,
        _ clips: ClipperPaths,
        fillRule: ClipperFillRule = .nonZero,
        preservingCollinearVertices: Bool = false,
        scale: ClipperScale = .pagePoints
    ) throws(ClipperError) -> ClipperPaths {
        try boolean(ZPCLIPPER2_CLIP_INTERSECTION, subjects, clips, fillRule, preservingCollinearVertices, scale)
    }

    /// `subjects` minus `clips`.
    public static func difference(
        _ subjects: ClipperPaths,
        _ clips: ClipperPaths,
        fillRule: ClipperFillRule = .nonZero,
        preservingCollinearVertices: Bool = false,
        scale: ClipperScale = .pagePoints
    ) throws(ClipperError) -> ClipperPaths {
        try boolean(ZPCLIPPER2_CLIP_DIFFERENCE, subjects, clips, fillRule, preservingCollinearVertices, scale)
    }

    /// Resolves self-intersections, removes zero-area spikes and re-orients
    /// rings so that outer rings and holes are consistent under `fillRule`.
    /// This is a union against an empty clip set.
    public static func normalized(
        _ paths: ClipperPaths,
        fillRule: ClipperFillRule = .nonZero,
        preservingCollinearVertices: Bool = false,
        scale: ClipperScale = .pagePoints
    ) throws(ClipperError) -> ClipperPaths {
        try boolean(ZPCLIPPER2_CLIP_UNION, paths, [], fillRule, preservingCollinearVertices, scale)
    }

    // MARK: - Measurement

    /// Signed shoelace area of a single ring, in caller units squared.
    ///
    /// Positive for counter-clockwise rings in a y-up coordinate system.
    /// Summed with Neumaier (improved Kahan) compensation so that a ring with tens of
    /// thousands of vertices does not accumulate drift. No rounding is applied — round only
    /// at the view or export boundary.
    ///
    /// The shoelace is **origin-shifted**: every vertex is taken relative to the ring's first
    /// vertex before the cross products are formed (QUALITY_BAR 2.2 rule 1). The trapezoid form
    /// this used, `(x₀ − x₁)(y₀ + y₁)`, multiplies by a sum of two absolute coordinates; on a
    /// sheet 14 000 pt from the origin that sum is rounded at about 2Y before it meets the
    /// difference, and the net and cutout areas the measurement engine stores from this
    /// function were off by up to 4.6e-10 relative against an exact rational oracle — several
    /// hundred times the 1e-12 the quality bar allows (R-167). Relative to the first vertex the
    /// products are of the ring's own size, and the result is translation-invariant.
    public static func area(of path: ClipperPath) -> Double {
        guard path.count >= 3 else { return 0 }
        let originX = Double(path[0].x)
        let originY = Double(path[0].y)
        // The same terms, in the same order and with the same Neumaier compensation, as the
        // geometry package's `PolygonMath.signedArea`, so a ring measured here and there gives
        // the same bits (the two terms involving the origin vertex are exactly zero).
        var sum = 0.0
        var compensation = 0.0
        var previousX = Double(path[path.count - 1].x) - originX
        var previousY = Double(path[path.count - 1].y) - originY
        for point in path {
            let x = Double(point.x) - originX
            let y = Double(point.y) - originY
            let term = previousX * y - x * previousY
            let candidate = sum + term
            if Swift.abs(sum) >= Swift.abs(term) {
                compensation += (sum - candidate) + term
            } else {
                compensation += (term - candidate) + sum
            }
            sum = candidate
            previousX = x
            previousY = y
        }
        return (sum.isFinite ? sum + compensation : sum) * 0.5
    }

    /// Sum of the signed areas of every ring, so holes (opposite winding)
    /// subtract from their outer ring. Kahan-compensated across rings too.
    public static func area(of paths: ClipperPaths) -> Double {
        var sum = 0.0
        var compensation = 0.0
        for path in paths {
            let adjusted = area(of: path) - compensation
            let next = sum + adjusted
            compensation = (next - sum) - adjusted
            sum = next
        }
        return sum
    }

    // MARK: - Point queries

    /// Exact point-in-polygon test performed on the integer lattice, so it is
    /// free of the floating-point ambiguity a naive ray cast suffers from.
    ///
    /// - Parameter fillRule: how a self-overlapping ring is read. The default, `.nonZero`,
    ///   matches the booleans' default, so `contains` and a boolean agree on a ring whose
    ///   overlap winds twice. (Before BH-397 this was even-odd whatever the documentation
    ///   said.) For a multi-ring polygon with holes, test each ring and combine.
    public static func containment(
        of point: CGPoint,
        in path: ClipperPath,
        fillRule: ClipperFillRule = .nonZero,
        scale: ClipperScale = .pagePoints
    ) throws(ClipperError) -> ClipperContainment {
        guard path.count >= 3 else { return .outside }
        // BH-398: the coordinate buffer holds twice the vertices, and both counts cross
        // the ABI as Int32.
        guard path.count <= Int(Int32.max) / 2 else { throw ClipperError.invalidPathCount }
        var coords = [Double]()
        coords.reserveCapacity(path.count * 2)
        for vertex in path {
            coords.append(Double(vertex.x))
            coords.append(Double(vertex.y))
        }
        var raw: Int32 = ZPCLIPPER2_PIP_OUTSIDE
        let status = coords.withUnsafeBufferPointer { buffer -> Int32 in
            zpclipper2_point_in_polygon(
                Double(point.x), Double(point.y),
                buffer.baseAddress, Int32(buffer.count), Int32(path.count),
                fillRule.rawCValue, scale.value, &raw
            )
        }
        if let error = ClipperError.from(status: status, scale: scale.value) {
            throw error
        }
        switch raw {
        case ZPCLIPPER2_PIP_INSIDE: return .inside
        case ZPCLIPPER2_PIP_ON: return .onBoundary
        default: return .outside
        }
    }

    /// `true` when `point` is strictly inside, or exactly on, `path`.
    public static func contains(
        _ point: CGPoint,
        in path: ClipperPath,
        includingBoundary: Bool = true,
        fillRule: ClipperFillRule = .nonZero,
        scale: ClipperScale = .pagePoints
    ) throws(ClipperError) -> Bool {
        switch try containment(of: point, in: path, fillRule: fillRule, scale: scale) {
        case .inside: true
        case .onBoundary: includingBoundary
        case .outside: false
        }
    }

    // MARK: - Bridging

    private static func boolean(
        _ clipType: Int32,
        _ subjects: ClipperPaths,
        _ clips: ClipperPaths,
        _ fillRule: ClipperFillRule,
        _ preserveCollinear: Bool,
        _ scale: ClipperScale
    ) throws(ClipperError) -> ClipperPaths {
        let subjectFlat = try flatten(subjects)
        let clipFlat = try flatten(clips)
        var result = ZPClipper2Paths()

        let status = subjectFlat.coords.withUnsafeBufferPointer { sc -> Int32 in
            subjectFlat.lengths.withUnsafeBufferPointer { sl -> Int32 in
                clipFlat.coords.withUnsafeBufferPointer { cc -> Int32 in
                    clipFlat.lengths.withUnsafeBufferPointer { cl -> Int32 in
                        zpclipper2_boolean(
                            clipType, fillRule.rawCValue,
                            sc.baseAddress, Int32(sc.count),
                            sl.baseAddress, subjectFlat.pathCount,
                            cc.baseAddress, Int32(cc.count),
                            cl.baseAddress, clipFlat.pathCount,
                            preserveCollinear ? 1 : 0, scale.value, &result
                        )
                    }
                }
            }
        }
        return try decode(status: status, result: &result, scale: scale)
    }

    private struct FlatPaths {
        var coords: [Double]
        var lengths: [Int32]
        var pathCount: Int32
    }

    private static func flatten(_ paths: ClipperPaths) throws(ClipperError) -> FlatPaths {
        guard paths.count <= Int(Int32.max) else { throw ClipperError.invalidPathCount }
        var coords = [Double]()
        var lengths = [Int32]()
        lengths.reserveCapacity(paths.count)
        var total = 0
        for path in paths {
            guard path.count <= Int(Int32.max) else { throw ClipperError.invalidPathCount }
            total += path.count
            // BH-398: the coordinate buffer is 2 × total doubles and its length crosses the
            // ABI as Int32 too, so the bound is Int32.max / 2, not Int32.max.
            guard total <= Int(Int32.max) / 2 else { throw ClipperError.invalidPathCount }
            lengths.append(Int32(path.count))
        }
        coords.reserveCapacity(total * 2)
        for path in paths {
            for point in path {
                coords.append(Double(point.x))
                coords.append(Double(point.y))
            }
        }
        return FlatPaths(coords: coords, lengths: lengths, pathCount: Int32(paths.count))
    }

    private static func decode(
        status: Int32,
        result: inout ZPClipper2Paths,
        scale: ClipperScale
    ) throws(ClipperError) -> ClipperPaths {
        if let error = ClipperError.from(status: status, scale: scale.value) {
            zpclipper2_paths_free(&result)
            throw error
        }
        defer { zpclipper2_paths_free(&result) }

        let pathCount = Int(result.path_count)
        guard pathCount > 0,
              let lengths = result.path_lengths,
              let coords = result.coords
        else { return [] }

        var output = ClipperPaths()
        output.reserveCapacity(pathCount)
        var cursor = 0
        for index in 0..<pathCount {
            let count = Int(lengths[index])
            guard count >= 0 else { throw ClipperError.coordinateOverflow }
            var path = ClipperPath()
            path.reserveCapacity(count)
            for _ in 0..<count {
                path.append(CGPoint(x: coords[cursor], y: coords[cursor + 1]))
                cursor += 2
            }
            output.append(path)
        }
        return output
    }
}
