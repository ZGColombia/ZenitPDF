import Foundation

/// What a Project Zone represents.
///
/// Zones organise quantities. They never affect the measurement transform — that is
/// what a Scale Region does.
public enum ProjectZoneKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// A single room.
    case room
    /// A dwelling unit.
    case apartment
    /// A whole floor.
    case floor
    /// A section of a building.
    case buildingSection
    /// An area belonging to one trade.
    case tradeArea
    /// An arbitrary grouping used only for takeoff totals.
    case quantityGroup

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the zone-type picker.
    public var displayName: String {
        switch self {
        case .room: return NSLocalizedString("Room", comment: "Project Zone type")
        case .apartment: return NSLocalizedString("Apartment", comment: "Project Zone type")
        case .floor: return NSLocalizedString("Floor", comment: "Project Zone type")
        case .buildingSection: return NSLocalizedString("Building Section", comment: "Project Zone type")
        case .tradeArea: return NSLocalizedString("Trade Area", comment: "Project Zone type")
        case .quantityGroup: return NSLocalizedString("Quantity Group", comment: "Project Zone type")
        }
    }

    /// SF Symbol name for the zone list.
    public var symbolName: String {
        switch self {
        case .room: return "square.split.bottomrightquarter"
        case .apartment: return "house"
        case .floor: return "square.stack.3d.up"
        case .buildingSection: return "building.2"
        case .tradeArea: return "hammer"
        case .quantityGroup: return "sum"
        }
    }
}

/// A named, polygonal organisational area of the project.
public struct ProjectZoneSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the zone.
    public let id: UUID
    /// User-visible name, for example `"Ground Floor — Zone A"`.
    public var name: String
    /// What the zone represents.
    public var kind: ProjectZoneKind
    /// Parent zone for nested zones, or `nil`.
    public var parentID: UUID?
    /// Page the polygon lives on, or `nil` for a zone that spans pages.
    public var pageID: PageDescriptor.ID?
    /// Page label of ``pageID``, or `nil`.
    public var pageLabel: String?
    /// Closed polygon in page space, empty for a zone with no drawn boundary.
    public var boundary: [PDFPointValue]
    /// Outline colour on the canvas and the redundant swatch in the ledger.
    public var colorRGBA: ColorRGBA
    /// Number of markups currently assigned to the zone.
    public var markupCount: Int
    /// Whether the boundary is drawn.
    public var isVisible: Bool

    /// Creates a Project Zone summary.
    public init(
        id: UUID,
        name: String,
        kind: ProjectZoneKind,
        parentID: UUID? = nil,
        pageID: PageDescriptor.ID? = nil,
        pageLabel: String? = nil,
        boundary: [PDFPointValue] = [],
        colorRGBA: ColorRGBA,
        markupCount: Int = 0,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.pageID = pageID
        self.pageLabel = pageLabel
        self.boundary = boundary
        self.colorRGBA = colorRGBA
        self.markupCount = markupCount
        self.isVisible = isVisible
    }

    /// A localized VoiceOver label: name, type and markup count.
    public var accessibilityLabel: String {
        // BH-788: "Kitchen, Room, 1 markups".
        let count = LocalizedPlural.string(
            "%lld markups",
            count: markupCount,
            one: NSLocalizedString("%lld markup", comment: "Count of markups, singular"),
            other: NSLocalizedString("%lld markups", comment: "Count of markups, plural")
        )
        let format = NSLocalizedString(
            "%1$@, %2$@, %3$@",
            comment: "VoiceOver label for a Project Zone: name, zone type, markup count phrase"
        )
        return String(format: format, name, kind.displayName, count)
    }
}
