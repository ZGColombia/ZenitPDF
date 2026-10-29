import Foundation
import ZPDFContracts

/// Errors raised by the geometry core.
///
/// Every failure mode is a typed case. There is no `fatalError` anywhere in this package: a
/// degenerate polygon on page 400 of a scanned drawing set is normal input, not a programmer
/// error, and the caller has to be able to report it.
public enum GeometryError: Error, Hashable, Sendable {
    /// A NaN or infinite coordinate reached a pure function.
    case nonFiniteCoordinate

    /// Zoom outside ``PageViewLayout/supportedZoomRange`` (5 % ... 6400 %, spec 9.3).
    case zoomOutOfRange(Double)

    /// The backing (Retina) scale was zero, negative or non-finite. 1 and 2 are the real values.
    case invalidBackingScale(Double)

    /// A tolerance in pixels was negative or non-finite.
    case invalidTolerance(Double)

    /// An epsilon in ``GeometryEpsilon`` was zero, negative or non-finite.
    case invalidEpsilon(name: String, value: Double)

    /// A polygon had fewer than three points that survive duplicate cleanup.
    case fewerThanThreeUniquePoints(count: Int)

    /// A segment or line was defined by two coincident points.
    case degenerateSegment

    /// An angle was requested between vectors one of which has (near) zero length.
    case zeroLengthVector

    /// Three points are collinear to within the rejection threshold, so no circumcircle exists.
    /// `measure` is the normalised twice-area `|cross| / maxEdge^2`.
    case nearlyCollinearPoints(measure: Double)

    /// A ring that must be simple (a Scale Region boundary, for one) crosses or touches itself.
    /// Raised where the error has to travel as a ``GeometryError``; the measurement-facing
    /// equivalent is ``ZPDFContracts/MeasurementError/selfIntersectingPolygon``.
    case selfIntersectingRing

    /// The exhaustive self-intersection check refused a ring larger than its configured limit.
    /// See ``SelfIntersectionOptions`` for the cost model behind the limit.
    case ringTooLargeForIntersectionCheck(vertexCount: Int, limit: Int)

    /// An R-tree node size outside 2...65_535.
    case invalidNodeSize(Int)

    /// A rectangle handed to the R-tree contained a non-finite coordinate.
    case nonFiniteBounds(index: Int)

    /// The multi-page converter has no layout for this page (spec 9.2 `CoordinateError`
    /// equivalent; re-raised as ``CoordinateError/unknownPage(_:)`` at the protocol boundary).
    case unknownPage(PageID)
}

/// Errors raised when a ``ScaleTransform`` is applied to page geometry (spec 10.4).
public enum ScaleApplicationError: Error, Hashable, Sendable {
    /// A bare length was scaled under a non-uniform (separate-XY or sheared) scale, where the
    /// answer depends on direction. Callers must pass the two endpoints instead.
    case directionRequiredForNonUniformScale(ScaleID)

    /// Two Scale Regions on the same page overlap. Overlap is forbidden by default (spec 10.4).
    case overlappingRegions(ScaleRegionID, ScaleRegionID)

    /// A region names a scale that is not in the supplied scale table.
    case unknownScale(ScaleID, region: ScaleRegionID)

    /// A region's boundary ring is not a usable polygon.
    case invalidRegionBoundary(ScaleRegionID, underlying: GeometryError)

    /// A resolution was asked for an empty point set.
    case emptyGeometry

    /// A numeric conversion into `Decimal` failed (non-finite geometry).
    case numeric(NumericError)
}
