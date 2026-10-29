import Foundation

/// The tolerance policy for every predicate in this package.
///
/// # Why absolute, not relative
///
/// PDF page space is bounded: the format caps a box at 14 400 points (200 inch) per side, and a
/// crop box origin is rarely more than a few thousand points from zero. At 14 400 the `Double`
/// ulp is about 1.8e-12 points, so an absolute epsilon of 1e-6 points sits roughly six orders of
/// magnitude above the noise floor everywhere on every legal page. A relative epsilon would
/// instead shrink to nothing near the origin and silently widen at the far corner, which is the
/// classic way a polygon validates on page 1 and fails on page 2 of the same drawing.
///
/// One point is 1/72 inch. `1e-6` points is ~3.5e-10 metres at 1:1 and ~1.8e-8 metres at 1:50 —
/// far below anything a construction drawing can express, and far below PDFium's own emitted
/// vector precision.
///
/// # Which epsilon is which
///
/// - ``pointMerge``: two vertices closer than this are the same vertex.
/// - ``onSegment``: perpendicular distance under which a point counts as lying on a segment.
/// - ``parallel``: threshold on `|a x b| / (|a||b|)`, i.e. `sin(angle)`. Dimensionless.
/// - ``areaFloor``: absolute square points under which an area is treated as zero.
///
/// Every value is configurable. The three-point collinearity floor is not one of them: it is the
/// measurement engine's `MeasurementEngineOptions.collinearityThreshold`, handed to
/// ``SegmentMath/circumcircle(_:_:_:collinearityThreshold:)``, the one predicate that applies it.
/// A `collinear` member here was validated and read by nothing, so tightening it (the ``strict``
/// preset set 1e-14) changed no answer (W-090).
public struct GeometryEpsilon: Hashable, Sendable {
    public var pointMerge: Double
    public var onSegment: Double
    public var parallel: Double
    public var areaFloor: Double

    public init(
        pointMerge: Double,
        onSegment: Double,
        parallel: Double,
        areaFloor: Double
    ) {
        self.pointMerge = pointMerge
        self.onSegment = onSegment
        self.parallel = parallel
        self.areaFloor = areaFloor
    }

    /// The policy used everywhere unless a caller overrides it.
    public static let standard = GeometryEpsilon(
        pointMerge: 1e-6,
        onSegment: 1e-6,
        parallel: 1e-9,
        areaFloor: 1e-9
    )

    /// A deliberately strict policy for regression tests and for validating imported geometry
    /// where nothing has been through a float round trip yet.
    public static let strict = GeometryEpsilon(
        pointMerge: 1e-12,
        onSegment: 1e-12,
        parallel: 1e-14,
        areaFloor: 1e-15
    )

    /// - Throws: ``GeometryError/invalidEpsilon(name:value:)`` for any non-positive or
    ///   non-finite member.
    public func validate() throws {
        func check(_ value: Double, _ name: String) throws {
            guard value.isFinite, value > 0 else {
                throw GeometryError.invalidEpsilon(name: name, value: value)
            }
        }
        try check(pointMerge, "pointMerge")
        try check(onSegment, "onSegment")
        try check(parallel, "parallel")
        try check(areaFloor, "areaFloor")
    }
}
