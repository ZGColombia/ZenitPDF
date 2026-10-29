import Foundation
import ZPDFUIPresentation

/// Two Scale Regions that share area on the same page.
///
/// Overlap is forbidden by default. The panel reports it rather than resolving it
/// silently, because which of the two scales is "right" is a decision only the estimator can
/// make.
public struct ScaleRegionOverlap: Identifiable, Hashable, Sendable {

    /// Stable identity built from the two region identifiers.
    public var id: String { "\(first.uuidString)|\(second.uuidString)" }

    /// The lower-priority region.
    public let first: UUID
    /// The higher-priority region.
    public let second: UUID
    /// Name of ``first``, denormalised for the warning text.
    public let firstName: String
    /// Name of ``second``.
    public let secondName: String

    public init(first: UUID, second: UUID, firstName: String, secondName: String) {
        self.first = first
        self.second = second
        self.firstName = firstName
        self.secondName = secondName
    }

    /// The warning shown in the panel.
    public var message: String {
        String(
            format: NSLocalizedString(
                "“%1$@” and “%2$@” overlap. Measurements inside the shared area would be ambiguous.",
                comment: "Overlap warning: two region names"
            ),
            firstName,
            secondName
        )
    }
}

/// How a markup that crosses two Scale Regions is resolved.
///
/// Exactly three outcomes are allowed, and the app never picks one silently.
public enum ScaleRegionCrossingResolution: Hashable, Sendable, Identifiable {

    /// Split the markup at the region boundary and measure each part with its own scale.
    case splitAtBoundary
    /// Measure the whole markup with one chosen scale. `nil` means the page default.
    case useScale(regionID: UUID?)
    /// Refuse to create the markup.
    case block

    public var id: String {
        switch self {
        case .splitAtBoundary: return "split"
        case let .useScale(regionID): return "scale:\(regionID?.uuidString ?? "page")"
        case .block: return "block"
        }
    }
}

/// A markup whose geometry lies in more than one Scale Region.
public struct ScaleRegionCrossing: Identifiable, Hashable, Sendable {

    /// Stable identity of the crossing.
    public let id: UUID
    /// What the user was drawing, for example "Area".
    public let measurementName: String
    /// Page the geometry sits on.
    public let pageLabel: String
    /// The regions the geometry touches, in priority order.
    public let regions: [ScaleRegionSummary]
    /// Whether the geometry can actually be cut at the boundary. A count group cannot.
    public let canSplitAtBoundary: Bool
    /// The page default scale, offered as one of the "choose a scale" options.
    public let pageDefaultScale: ScaleSummary?

    public init(
        id: UUID,
        measurementName: String,
        pageLabel: String,
        regions: [ScaleRegionSummary],
        canSplitAtBoundary: Bool,
        pageDefaultScale: ScaleSummary?
    ) {
        self.id = id
        self.measurementName = measurementName
        self.pageLabel = pageLabel
        self.regions = regions
        self.canSplitAtBoundary = canSplitAtBoundary
        self.pageDefaultScale = pageDefaultScale
    }

    /// The headline shown above the three choices.
    ///
    /// One region cannot be crossed: a single region here means the geometry runs out of it
    /// onto the bare sheet (the resolver's partly-outside case), which used to read "This Area
    /// crosses 1 Scale Regions on page A-101." (W-073).
    public var headline: String {
        if regions.count == 1, let region = regions.first {
            return String(
                format: NSLocalizedString(
                    "This %1$@ runs out of “%2$@” onto the sheet on page %3$@.",
                    comment: "Crossing headline when a measurement runs from one Scale Region onto the bare sheet: measurement name, region name, page label"
                ),
                measurementName,
                region.name,
                pageLabel
            )
        }
        return String(
            format: NSLocalizedString(
                "This %1$@ crosses %2$@ on page %3$@.",
                comment: "Crossing headline: measurement name, counted Scale Regions (\"2 Scale Regions\"), page label"
            ),
            measurementName,
            MeasurementPlurals.scaleRegions(regions.count),
            pageLabel
        )
    }

    /// Whether part of the geometry lies outside every region and the page has a scale for
    /// it: the page scale is offered only then (the crossing prompt's wiring), and a single
    /// region can only be "crossed" that way.
    private var partMeasuredAtPageScale: Bool { pageDefaultScale != nil }

    /// The three legal outcomes, with the split option dropped when the geometry cannot be cut.
    public var offeredResolutions: [ScaleRegionCrossingResolution] {
        var options: [ScaleRegionCrossingResolution] = []
        if canSplitAtBoundary { options.append(.splitAtBoundary) }
        options.append(contentsOf: regions.map { .useScale(regionID: $0.id) })
        if pageDefaultScale != nil { options.append(.useScale(regionID: nil)) }
        options.append(.block)
        return options
    }

    /// The label for one option.
    public func title(for resolution: ScaleRegionCrossingResolution) -> String {
        switch resolution {
        case .splitAtBoundary:
            return NSLocalizedString(
                "Split at the boundary",
                comment: "Crossing resolution: cut the markup at the region edge"
            )
        case let .useScale(regionID):
            guard let regionID, let region = regions.first(where: { $0.id == regionID }) else {
                return String(
                    format: NSLocalizedString(
                        "Use the page scale (%@)",
                        comment: "Crossing resolution: use the page default scale, ratio string"
                    ),
                    pageDefaultScale?.displayString ?? "—"
                )
            }
            return String(
                format: NSLocalizedString(
                    "Use “%1$@” (%2$@)",
                    comment: "Crossing resolution: use one region's scale — region name, ratio"
                ),
                region.name,
                region.scale.displayString
            )
        case .block:
            return NSLocalizedString(
                "Do not create this measurement",
                comment: "Crossing resolution: refuse the markup"
            )
        }
    }

    /// One line of explanation for an option.
    public func explanation(for resolution: ScaleRegionCrossingResolution) -> String {
        switch resolution {
        case .splitAtBoundary:
            if partMeasuredAtPageScale {
                // A part on the bare sheet sits in no region, so "the scale of the region it
                // sits in" did not describe it.
                return NSLocalizedString(
                    "Separate measurements are created: each part inside a region uses that region’s scale, and each part outside every region uses the page scale.",
                    comment: "Crossing resolution help: split, when part of the measurement lies outside every region"
                )
            }
            return NSLocalizedString(
                "Two measurements are created, each measured with the scale of the region it sits in.",
                comment: "Crossing resolution help: split"
            )
        case .useScale(regionID: nil):
            // No region is chosen here, so "the chosen region" had nothing to refer to (W-073).
            return NSLocalizedString(
                "One measurement is created. All of it, including what lies inside a region, uses the page scale.",
                comment: "Crossing resolution help: use the page scale for the whole measurement"
            )
        case .useScale:
            return NSLocalizedString(
                "One measurement is created. The parts outside the chosen region are measured with that same scale.",
                comment: "Crossing resolution help: single scale"
            )
        case .block:
            return NSLocalizedString(
                "Nothing is created. Redraw the measurement inside a single region.",
                comment: "Crossing resolution help: block"
            )
        }
    }
}
