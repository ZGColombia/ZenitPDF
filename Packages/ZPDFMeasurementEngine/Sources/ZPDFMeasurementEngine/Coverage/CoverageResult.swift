import Foundation
import ZPDFContracts

/// What one page's coverage map came out as: the covered regions, the regions still unaccounted
/// for, and the fraction — with the name of what it is a fraction of.
///
/// # The regions are page-space geometry, not quantities
///
/// ``coveredPDFArea`` and ``extentPDFArea`` are square PDF **points**. They are not a takeoff
/// quantity: nothing here has been through a ``ScaleTransform``, and no value here belongs in the
/// Quantity Ledger. The coverage map is a diagnostic overlay — *what have I forgotten* — and its
/// only job is to be internally consistent, which is why both sides of ``coveredFraction`` come
/// out of one area routine (see ``CoverageMap``).
///
/// # Nothing is double-counted
///
/// ``coveredPolygons`` is the **union** of the measured areas, clipped to the extent, so two
/// areas that overlap contribute their shared region once. That is not a nicety: an overlay built
/// from a sum would report over 100 % coverage on a drawing that has a genuine double count, and
/// the one thing this feature exists to do is notice missing area, not manufacture it.
/// ``OverlapGuard/overlaps(of:floor:options:)`` is where the double count itself is available, separately.
public struct CoverageResult: Equatable, Sendable {

    /// The union of the measured areas, clipped to the extent, as disjoint net regions.
    ///
    /// Holes are carried as holes: a courtyard cut out of a measured area was never measured, so
    /// it is not covered, and it appears as a ``PolygonGeometry/holes`` ring here and as its own
    /// region in ``uncoveredPolygons``.
    ///
    /// Ordered descending by net area, then ascending minimum x, then ascending minimum y.
    public var coveredPolygons: [PolygonGeometry]

    /// The extent minus the union of the measured areas: everything still unaccounted for.
    ///
    /// Same ordering rule as ``coveredPolygons``. Empty when the measured areas tile the extent.
    public var uncoveredPolygons: [PolygonGeometry]

    /// Area of ``coveredPolygons`` in square PDF points, holes already subtracted.
    public var coveredPDFArea: Double

    /// Area of the extent in square PDF points — the denominator.
    public var extentPDFArea: Double

    /// ``coveredPDFArea`` / ``extentPDFArea``, clamped to `0...1`.
    ///
    /// Zero when the extent has no area. The clamp is a guard, not a correction: with the union
    /// taken first and the result clipped to the extent, the raw ratio cannot exceed 1 except by
    /// a lattice step, and if it ever did, showing 103 % would be worse than showing 100 %.
    public var coveredFraction: Double

    /// Which rectangle ``coveredFraction`` is a fraction of. Never present the fraction without
    /// it — see ``CoverageExtentKind``.
    public var denominator: CoverageExtentKind

    public init(
        coveredPolygons: [PolygonGeometry],
        uncoveredPolygons: [PolygonGeometry],
        coveredPDFArea: Double,
        extentPDFArea: Double,
        coveredFraction: Double,
        denominator: CoverageExtentKind
    ) {
        self.coveredPolygons = coveredPolygons
        self.uncoveredPolygons = uncoveredPolygons
        self.coveredPDFArea = coveredPDFArea
        self.extentPDFArea = extentPDFArea
        self.coveredFraction = coveredFraction
        self.denominator = denominator
    }

    /// True when nothing measured falls inside the extent.
    public var isEmpty: Bool { coveredPolygons.isEmpty }
}

/// How ``CoverageMap`` behaves. Nothing here changes what coverage *means*; it is the numeric
/// policy.
public struct CoverageOptions: Hashable, Sendable {

    /// The numeric policy the coverage map shares with the cutout pipeline and the splitter:
    /// epsilons, the 1e-6 pt Clipper2 lattice, the self-intersection policy.
    ///
    /// Passing the same value the rest of the engine uses is what makes a covered area
    /// comparable with a measured one.
    public var engine: MeasurementEngineOptions

    public init(engine: MeasurementEngineOptions = .default) {
        self.engine = engine
    }

    public static let `default` = CoverageOptions()
}
