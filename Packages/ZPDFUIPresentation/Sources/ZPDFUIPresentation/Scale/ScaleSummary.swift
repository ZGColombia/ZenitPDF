import Foundation

/// A read-only view of one scale definition, as the UI needs to present it.
///
/// The underlying model is the affine transform `r = A × p + b`. The presentation layer
/// only carries the two diagonal factors of `A`, because a Zenit scale is either uniform
/// or axis-separated; a full non-diagonal matrix is reported through ``isUniform`` being
/// `false` together with a residual reported by the calibration flow.
public struct ScaleSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the scale definition.
    public let id: UUID
    /// User-visible name, for example `"Plan 1:50"`.
    public var name: String
    /// Ratio string shown in the status bar and the inspector, for example `"1:50"`.
    public var displayString: String
    /// Whether ``sx`` and ``sy`` are equal, that is whether the scale is uniform.
    public var isUniform: Bool
    /// Real-world metres per PDF point along the page x axis.
    public var sx: Double
    /// Real-world metres per PDF point along the page y axis.
    public var sy: Double
    /// The length unit this scale is presented in.
    public var unit: LengthUnit
    /// Monotonic version, bumped on every recalibration. Markups store the version they
    /// were measured against so that stale measurements can be detected.
    public var version: Int
    /// Whether the scale is locked against edits.
    public var locked: Bool

    /// Creates a scale summary.
    public init(
        id: UUID,
        name: String,
        displayString: String,
        isUniform: Bool,
        sx: Double,
        sy: Double,
        unit: LengthUnit,
        version: Int,
        locked: Bool
    ) {
        self.id = id
        self.name = name
        self.displayString = displayString
        self.isUniform = isUniform
        self.sx = sx
        self.sy = sy
        self.unit = unit
        self.version = version
        self.locked = locked
    }

    /// The absolute determinant of the diagonal transform, that is the area factor in
    /// square metres per square PDF point.
    public var areaFactor: Double { abs(sx * sy) }

    /// A localized accessibility value combining name, ratio and lock state.
    public var accessibilityValue: String {
        let base = String(
            format: NSLocalizedString(
                "%1$@, scale %2$@",
                comment: "VoiceOver value for a scale: scale name, ratio string"
            ),
            name,
            displayString
        )
        guard locked else { return base }
        return base + ", " + NSLocalizedString("locked", comment: "VoiceOver suffix for a locked scale")
    }
}

extension ScaleRegionSummary {
    /// Scale Region resolution order: highest priority first, ties broken by name so the order
    /// is the same on every run.
    ///
    /// The one comparator for it (U-075). The Scale Regions panel's rows, its Raise/Lower (which
    /// finds the moved region's index in this order) and the Inspector's region popup all read
    /// it; two private copies used to agree only by coincidence, and a change to one would have
    /// had Raise move a different region from the row the person clicked.
    public static func inResolutionOrder(_ regions: [ScaleRegionSummary]) -> [ScaleRegionSummary] {
        regions.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.name < rhs.name : lhs.priority > rhs.priority
        }
    }
}

/// A polygonal region of a page that overrides the page's default scale.
///
/// Scale Regions decide the measurement transform. Project Zones decide organisational
/// grouping. They may share a polygon but they are different domain objects, and a
/// markup that crosses two regions is never silently assigned a scale.
public struct ScaleRegionSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the region.
    public let id: UUID
    /// User-visible name, for example `"Stair Detail"`.
    public var name: String
    /// Page the region lives on.
    public var pageID: PageDescriptor.ID
    /// Page label of ``pageID``, denormalised so lists do not need a second lookup.
    public var pageLabel: String
    /// The scale that applies inside ``boundary``.
    public var scale: ScaleSummary
    /// Closed polygon in page space. The first point is not repeated at the end.
    public var boundary: [PDFPointValue]
    /// Resolution order when regions are adjacent; higher wins.
    public var priority: Int
    /// Whether the region is locked against edits.
    public var locked: Bool
    /// Outline colour used to draw the region on the canvas.
    public var colorRGBA: ColorRGBA
    /// Whether the region outline is currently drawn.
    public var isVisible: Bool

    /// Creates a scale region summary.
    public init(
        id: UUID,
        name: String,
        pageID: PageDescriptor.ID,
        pageLabel: String,
        scale: ScaleSummary,
        boundary: [PDFPointValue],
        priority: Int,
        locked: Bool,
        colorRGBA: ColorRGBA,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pageID = pageID
        self.pageLabel = pageLabel
        self.scale = scale
        self.boundary = boundary
        self.priority = priority
        self.locked = locked
        self.colorRGBA = colorRGBA
        self.isVisible = isVisible
    }

    /// Axis-aligned bounds of ``boundary`` in page space, or `nil` for an empty polygon.
    public var boundsInPageSpace: PDFRectValue? {
        guard let first = boundary.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in boundary.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
