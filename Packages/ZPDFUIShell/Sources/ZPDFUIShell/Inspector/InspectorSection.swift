import Foundation

/// The sections of the Inspector, in their fixed order.
public enum InspectorSection: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Colour, line weight, opacity, fill.
    case appearance
    /// The measurement fields the selection produces.
    case measurement
    /// ADR-0007 §1: the derivation of the selected markup's values — geometry, scale with
    /// calibration evidence, slope, parameters, the raw SI values at full precision with the
    /// display rounding shown separately, and the markup's own change list.
    case derivation
    /// The scale the selection is measured against.
    case scale
    /// The visible caption drawn next to the markup.
    case caption
    /// Subject, label, author, timestamps.
    case identity
    /// Review status and lock.
    case status
    /// Layer and Project Zone membership.
    case layerZone
    /// User-defined columns carried by the markup.
    case customData
    /// Operations on the selection.
    case actions

    public var id: String { rawValue }

    /// The section header title.
    public var displayName: String {
        switch self {
        case .appearance: return NSLocalizedString("Appearance", comment: "Inspector section title")
        case .measurement: return NSLocalizedString("Measurement", comment: "Inspector section title")
        case .derivation: return NSLocalizedString(
            "How This Number Was Calculated",
            comment: "Inspector section title: the derivation of the selected measurement (ADR-0007)"
        )
        case .scale: return NSLocalizedString("Scale", comment: "Inspector section title")
        case .caption: return NSLocalizedString("Caption", comment: "Inspector section title")
        case .identity: return NSLocalizedString("Identity", comment: "Inspector section title")
        case .status: return NSLocalizedString("Status", comment: "Inspector section title")
        case .layerZone: return NSLocalizedString("Layer and Zone", comment: "Inspector section title")
        case .customData: return NSLocalizedString("Custom Data", comment: "Inspector section title")
        case .actions: return NSLocalizedString("Actions", comment: "Inspector section title")
        }
    }

    /// The sections that are open the first time a user sees the Inspector.
    ///
    /// With a measurement selected, only the Measurement section
    /// is open; every other section is collapsed by default so the panel opens scannable
    /// rather than as one long scroll.
    public static let defaultExpanded: Set<InspectorSection> = [
        .measurement
    ]
}
