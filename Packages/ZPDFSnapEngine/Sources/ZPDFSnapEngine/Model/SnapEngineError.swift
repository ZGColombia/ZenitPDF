import Foundation

/// Every way the snap engine can refuse. Typed, exhaustive, and never a trap:
/// untrusted geometry reaching this package produces one of these or a result.
public enum SnapEngineError: Error, Hashable, Sendable {

    /// `SnapSettings.validate()` rejected the settings.
    case invalidSettings(String)

    /// A coordinate, radius or zoom that is not finite arrived from the view layer.
    case nonFiniteInput(field: String)

    /// More primitives than ``SnapIndexLimits/maximumPrimitives``.
    case indexTooLarge(count: Int, limit: Int)

    /// `SnapPrimitive.kind` disagreed with `geometry.kind`. Per SNAP_CONTRACT the entry is
    /// rejected rather than snapped to.
    case inconsistentPrimitive(id: UInt64)

    /// Two entries claimed the same index-local identifier and probing could not resolve it.
    case duplicateIdentifier(id: UInt64)

    /// The caller's cancellation predicate returned `true` during an index build.
    case cancelled

    /// A view <-> page conversion failed; carries the underlying geometry error's description
    /// so the snap engine's error surface stays one closed enum.
    case coordinateConversionFailed(String)
}

extension SnapEngineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidSettings(let detail): "invalid snap settings: \(detail)"
        case .nonFiniteInput(let field): "non-finite input: \(field)"
        case .indexTooLarge(let count, let limit):
            "snap index would hold \(count) primitives, limit is \(limit)"
        case .inconsistentPrimitive(let id): "primitive \(id) has a kind that disagrees with its geometry"
        case .duplicateIdentifier(let id): "duplicate snap primitive identifier \(id)"
        case .cancelled: "snap index build was cancelled"
        case .coordinateConversionFailed(let detail): "coordinate conversion failed: \(detail)"
        }
    }
}

/// Hard bounds on what the engine will accept, so hostile input cannot exhaust memory.
public struct SnapIndexLimits: Sendable, Hashable, Codable {

    /// Primitives per page across all three sources.
    public var maximumPrimitives: Int

    /// Vertices in one markup or boundary ring before it is refused.
    public var maximumRingVertices: Int

    /// Primitives inside one query radius that are carried into derived-target generation.
    ///
    /// At 5 % zoom a 10-view-point radius is 200 page points and can contain thousands of
    /// primitives. Truncation is deterministic — the nearest `maximumCandidatePrimitives` by
    /// the total order `(bounding-box distance, primitive id)` — and is part of the specified
    /// behaviour.
    ///
    /// The brute-force reference scorer of the golden tests does **not** truncate (it walks
    /// every entry), so the `QUALITY_BAR` S1 comparison holds only for fixtures that stay below
    /// this limit, and `SnapGoldenTests` keeps them there. The truncation rule itself is asserted
    /// on its own by engine-only tests (`Iter1QuantitiesCoreSnapTests`): above the limit the
    /// kept set is exactly the nearest `maximumCandidatePrimitives` by that total order. The
    /// candidate truncation is silent in ``SnapResolution``; only the intersection truncation
    /// below is reported (R-173).
    public var maximumCandidatePrimitives: Int

    /// Primitives inside the radius that participate in pairwise intersection solving.
    ///
    /// Intersections are the expensive derived target: the pair count is quadratic. The
    /// nearest `maximumIntersectionPrimitives` by the same total order **among those with a
    /// curve near the cursor** are used, giving at most `k*(k-1)/2` pairs per query. A primitive
    /// whose box contains the cursor but none of whose edges comes near it cannot cross
    /// anything there and takes no slot (W-087).
    public var maximumIntersectionPrimitives: Int

    /// Candidates returned in ``SnapResolution/alternatives``.
    public var maximumRankedAlternatives: Int

    public init(
        maximumPrimitives: Int = 2_000_000,
        maximumRingVertices: Int = 100_000,
        maximumCandidatePrimitives: Int = 512,
        maximumIntersectionPrimitives: Int = 24,
        maximumRankedAlternatives: Int = 32
    ) {
        self.maximumPrimitives = Swift.max(1, maximumPrimitives)
        self.maximumRingVertices = Swift.max(4, maximumRingVertices)
        self.maximumCandidatePrimitives = Swift.max(1, maximumCandidatePrimitives)
        self.maximumIntersectionPrimitives = Swift.max(2, maximumIntersectionPrimitives)
        self.maximumRankedAlternatives = Swift.max(1, maximumRankedAlternatives)
    }

    public static let standard = SnapIndexLimits()
}
