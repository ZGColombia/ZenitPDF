import Foundation
import ZPDFContracts

/// A polygonal area of one page that carries its own scale (spec 10.4).
///
/// `ZPDFContracts` freezes ``ScaleRegionID`` and ``ScaleRegionCrossingPolicy`` but not the region
/// value itself, because the contract layer never needed the boundary geometry. It lives here,
/// next to the point-in-polygon code that is the only thing that reads it.
///
/// Overlap between regions on a page is **forbidden by default** (spec 10.4). ``priority`` exists
/// for the deliberate, user-declared exception; it is never consulted unless the caller opts in
/// through ``ScaleRegionResolutionPolicy/highestPriorityWins``.
public struct ScaleRegion: Codable, Hashable, Sendable {
    public let id: ScaleRegionID
    public let pageID: PageID
    /// The scale that applies inside the boundary.
    public let scaleID: ScaleID
    /// The boundary in canonical PDF page space. Treated as closed regardless of
    /// ``PolygonRing/isClosed``: an open boundary cannot own an area.
    public let boundary: PolygonRing
    /// Higher wins where a caller has explicitly allowed priority to break an overlap.
    public let priority: Int
    /// A locked region cannot be edited or recalculated without being unlocked first.
    public let isLocked: Bool
    /// Optional human label, shown in the ambiguity prompt.
    public let label: String?

    public init(
        id: ScaleRegionID,
        pageID: PageID,
        scaleID: ScaleID,
        boundary: PolygonRing,
        priority: Int = 0,
        isLocked: Bool = false,
        label: String? = nil
    ) {
        self.id = id
        self.pageID = pageID
        self.scaleID = scaleID
        self.boundary = boundary
        self.priority = priority
        self.isLocked = isLocked
        self.label = label
    }

    /// Cached-friendly bounding box of the boundary, used as the R-tree key.
    public var bounds: PDFRect? { boundary.bounds }

    /// - Throws: ``ScaleApplicationError/invalidRegionBoundary(_:underlying:)`` when the boundary
    ///   is not a usable ring.
    public func validate(epsilon: GeometryEpsilon = .standard) throws {
        do {
            _ = try PolygonMath.requireSimplePolygon(boundary.points, epsilon: epsilon)
        } catch let error as GeometryError {
            throw ScaleApplicationError.invalidRegionBoundary(id, underlying: error)
        } catch MeasurementError.selfIntersectingPolygon {
            // A crossing boundary has a perfectly good area; reporting it as a zero-area
            // polygon (as this once did) made the real cause unrecoverable (BH-551).
            throw ScaleApplicationError.invalidRegionBoundary(id, underlying: .selfIntersectingRing)
        }
    }
}

/// How a caller wants overlaps resolved.
public enum ScaleRegionResolutionPolicy: String, Hashable, Sendable, CaseIterable {
    /// Any overlap is reported as ambiguous. The default, and the only one spec 10.4 allows:
    /// the app must never silently choose the wrong scale.
    case strict
    /// Break an overlap by ``ScaleRegion/priority``, and only when exactly one region has the
    /// strictly highest priority. Equal priorities are still ambiguous.
    case highestPriorityWins
}

/// Why a resolution could not name a single owner.
public enum ScaleRegionAmbiguityReason: Hashable, Sendable {
    /// One point falls inside more than one region.
    case pointInOverlappingRegions
    /// Different parts of one markup fall in different regions.
    case geometryCrossesRegionBoundary
    /// Part of the markup is inside a region and part is on the page default scale.
    case geometryPartlyOutsideAnyRegion
    /// Every candidate had the same priority, so ``ScaleRegionResolutionPolicy/highestPriorityWins``
    /// could not break the tie either.
    case tiedPriorities
}

/// An explicit "I will not guess" answer (spec 10.4).
public struct ScaleRegionAmbiguity: Hashable, Sendable {
    /// The regions in play, sorted by descending priority then by id, so the prompt is stable.
    public let candidates: [ScaleRegionID]
    /// True when the page's default scale is also a candidate.
    public let includesPageDefault: Bool
    public let reason: ScaleRegionAmbiguityReason

    public init(
        candidates: [ScaleRegionID],
        includesPageDefault: Bool,
        reason: ScaleRegionAmbiguityReason
    ) {
        self.candidates = candidates
        self.includesPageDefault = includesPageDefault
        self.reason = reason
    }
}

/// Which scale owns a point or a piece of geometry.
public enum ScaleRegionResolution: Hashable, Sendable {
    /// No region claims it; the page default applies.
    case pageDefault
    /// Exactly one region claims it.
    case region(ScaleRegionID)
    /// More than one claim, or a mix of region and default. **Never** silently collapsed to one
    /// of the candidates — the caller applies a ``ScaleRegionCrossingPolicy``.
    case ambiguous(ScaleRegionAmbiguity)

    public var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}
