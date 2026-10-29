import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation

/// A Scale Region as the document holds it.
///
/// Two objects already existed for this and neither was the document's: `ZPDFGeometry`'s
/// ``ScaleRegion`` is the resolver's input and carries no name, colour or visibility, and
/// `ZPDFUIPresentation`'s ``ScaleRegionSummary`` is what a panel renders and carries a whole
/// resolved ``ScaleSummary``. This is the third and smallest one — what the session stores and
/// what the database round-trips — and it holds a **scale identifier**, never a scale value, so
/// a recalibration cannot leave a region measuring against a copy of the old transform.
public struct ScaleRegionDefinition: Sendable, Hashable, Identifiable {

    /// Stable identity.
    public let id: ScaleRegionID
    /// The page the boundary lives on.
    public var pageID: PageID
    /// What the estimator calls it.
    public var name: String
    /// The closed boundary in page space. The first point is not repeated.
    public var boundary: [PDFPoint]
    /// The scale that applies inside the boundary.
    public var scaleID: ScaleID
    /// Resolution order; higher wins.
    public var priority: Int
    /// A locked region refuses edits until it is unlocked.
    public var locked: Bool
    /// Whether the outline is drawn on the canvas.
    public var isVisible: Bool
    /// Outline colour.
    public var colorRGBA: ColorRGBA

    /// Creates a definition.
    public init(
        id: ScaleRegionID,
        pageID: PageID,
        name: String,
        boundary: [PDFPoint],
        scaleID: ScaleID,
        priority: Int,
        locked: Bool = false,
        isVisible: Bool = true,
        colorRGBA: ColorRGBA
    ) {
        self.id = id
        self.pageID = pageID
        self.name = name
        self.boundary = boundary
        self.scaleID = scaleID
        self.priority = priority
        self.locked = locked
        self.isVisible = isVisible
        self.colorRGBA = colorRGBA
    }

    /// The resolver's view of the region.
    public var geometryRegion: ScaleRegion {
        ScaleRegion(
            id: id,
            pageID: pageID,
            scaleID: scaleID,
            boundary: PolygonRing(points: boundary, isClosed: true),
            priority: priority,
            isLocked: locked,
            label: name
        )
    }
}

/// A Project Zone as the document holds it.
///
/// A zone organises quantities and never affects a measurement. `pageID` is optional because
/// "Phase 2" is a legitimate zone that spans the whole set and has no polygon at all — the one
/// structural difference from a Scale Region, which without a boundary would be meaningless.
public struct ProjectZoneDefinition: Sendable, Hashable, Identifiable {

    /// Stable identity.
    public let id: ZoneID
    /// What the estimator calls it.
    public var name: String
    /// What the zone represents.
    public var kind: ProjectZoneKind
    /// The zone this one is nested inside.
    public var parentID: ZoneID?
    /// The page the boundary lives on, or `nil` for a zone with no drawn area.
    public var pageID: PageID?
    /// The closed boundary in page space, empty when there is none.
    public var boundary: [PDFPoint]
    /// Where the zone sits in the panel's own ordering.
    public var sortOrder: Int
    /// Whether the boundary is drawn on the canvas.
    public var isVisible: Bool
    /// Outline colour.
    public var colorRGBA: ColorRGBA

    /// Creates a definition.
    public init(
        id: ZoneID,
        name: String,
        kind: ProjectZoneKind,
        parentID: ZoneID? = nil,
        pageID: PageID? = nil,
        boundary: [PDFPoint] = [],
        sortOrder: Int,
        isVisible: Bool = true,
        colorRGBA: ColorRGBA
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.pageID = pageID
        self.boundary = boundary
        self.sortOrder = sortOrder
        self.isVisible = isVisible
        self.colorRGBA = colorRGBA
    }
}

// MARK: - Bridging to the presentation vocabulary

extension ScaleRegionDefinition {

    /// The panel's view of the region, resolved against the scale it names.
    ///
    /// - Parameters:
    ///   - scale: the transform ``scaleID`` refers to. A region whose scale has vanished cannot
    ///     be summarised, and returning `nil` is the honest answer — the alternative is a panel
    ///     row that shows a ratio nobody defined.
    ///   - pageLabel: the page's printed label, denormalised into the summary.
    ///   - userUnit: the page's `/UserUnit`. Without it the panel read a nominal 1:100 on a
    ///     `/UserUnit 2` sheet as 1:200 — the CR-128 error through a default argument (BH-092).
    ///   - localeIdentifier: the document's locale, which the region's ratio is written in (L-38).
    public func summary(
        scale: ScaleTransform,
        pageLabel: String,
        userUnit: Double = 1,
        localeIdentifier: String = "en_US_POSIX"
    ) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: id.rawValue,
            name: name,
            pageID: pageID.rawValue,
            pageLabel: pageLabel,
            scale: ScaleSummary(domain: scale, name: nil, userUnit: userUnit, localeIdentifier: localeIdentifier),
            boundary: boundary.map { PDFPointValue(x: $0.x, y: $0.y) },
            priority: priority,
            locked: locked,
            colorRGBA: colorRGBA,
            isVisible: isVisible
        )
    }
}

extension ProjectZoneDefinition {

    /// The panel's view of the zone, with the markup count the ledger will group by.
    public func summary(pageLabel: String?, markupCount: Int) -> ProjectZoneSummary {
        ProjectZoneSummary(
            id: id.rawValue,
            name: name,
            kind: kind,
            parentID: parentID?.rawValue,
            pageID: pageID?.rawValue,
            pageLabel: pageLabel,
            boundary: boundary.map { PDFPointValue(x: $0.x, y: $0.y) },
            colorRGBA: colorRGBA,
            markupCount: markupCount,
            isVisible: isVisible
        )
    }
}
