import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// What the engine does with a ring that crosses itself (spec 12.3).
///
/// The spec says a self-intersection is *blocked or normalised through Clipper2 after user
/// confirmation*. The engine is pure and has no user, so the choice is a parameter: the UI asks,
/// then calls with the answer. There is no third "just take the shoelace number" case, because
/// the shoelace of a figure-eight is the difference of its lobes and nobody means that.
public enum SelfIntersectionPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Run the ring through a Clipper2 union, measure the normalised result, and warn.
    case normalize
    /// Refuse the measurement with ``MeasurementError/selfIntersectingPolygon``.
    case reject
}

/// The knobs that change *how* a measurement is computed, never *what* it means.
///
/// Options are deliberately not part of ``MeasurementResult``: two builds with different
/// tolerances must still be comparable, so anything that could change a number materially
/// (the self-intersection policy) also raises a warning when it fires.
public struct MeasurementEngineOptions: Hashable, Sendable {
    /// Tolerances for duplicate-vertex collapse, on-segment tests and the zero-area floor.
    public var epsilon: GeometryEpsilon
    /// What to do with a ring that crosses itself.
    public var selfIntersectionPolicy: SelfIntersectionPolicy
    /// The integer lattice the cutout booleans run on. 1e-6 pt by default (spec 12.4).
    public var clipperScale: ClipperScale
    /// Normalised collinearity floor for the three-point circle (spec 12.11).
    public var collinearityThreshold: Double
    /// Rings above this vertex count skip the exhaustive self-intersection sweep, which is
    /// `O(n log n)` best case but `O(n^2)` on adversarial input.
    public var selfIntersectionVertexLimit: Int
    /// When set, a measurement made under an older scale version raises
    /// ``MeasurementWarning/Code/staleScaleVersion`` (spec 10.6).
    public var expectedScaleVersion: Int?
    /// Relative slack allowed before a cutout counts as sticking out of its parent.
    public var cutoutContainmentTolerance: Double

    public init(
        epsilon: GeometryEpsilon = .standard,
        selfIntersectionPolicy: SelfIntersectionPolicy = .normalize,
        clipperScale: ClipperScale = .pagePoints,
        collinearityThreshold: Double = 1e-9,
        selfIntersectionVertexLimit: Int = 50_000,
        expectedScaleVersion: Int? = nil,
        cutoutContainmentTolerance: Double = 1e-9
    ) {
        self.epsilon = epsilon
        self.selfIntersectionPolicy = selfIntersectionPolicy
        self.clipperScale = clipperScale
        self.collinearityThreshold = collinearityThreshold
        self.selfIntersectionVertexLimit = selfIntersectionVertexLimit
        self.expectedScaleVersion = expectedScaleVersion
        self.cutoutContainmentTolerance = cutoutContainmentTolerance
    }

    public static let `default` = MeasurementEngineOptions()

    /// Refuses self-intersecting input rather than normalising it.
    public static let strict = MeasurementEngineOptions(
        epsilon: .strict,
        selfIntersectionPolicy: .reject
    )
}
