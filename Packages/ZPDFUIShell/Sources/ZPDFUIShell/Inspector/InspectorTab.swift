import Foundation

/// The Inspector's three pages, in the order the 2026-09-23 main-window mockup shows them.
///
/// * **Markup** — what a person edits most: the header card, Label, the measured quantities
///   with their secondary unit, colour, border, style, notes, layer, review status, author and
///   the two timestamps.
/// * **Properties** — everything else the plan's section list (21.6) fixes, as collapsible
///   sections: the measurement controls, the derivation, scale, identity, lock and visibility,
///   Project Zone, custom data and the actions.
/// * **Comments** — the notes written on the selected markups, one card per markup.
///
/// Every ``InspectorSection`` is reachable from exactly one tab, which is pinned by a test so
/// that moving a section cannot quietly drop it off the panel.
public enum InspectorTab: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    case markup
    case properties
    case comments
    /// The Tool Library, docked beside the drawing (NL-UX-06, r2-markup).
    case tools

    public var id: String { rawValue }

    /// The tab's visible title.
    public var title: String {
        switch self {
        case .markup: return NSLocalizedString("Markup", comment: "Inspector tab title: the selected markup's main properties")
        case .properties: return NSLocalizedString("Properties", comment: "Inspector tab title: every other property section")
        case .comments: return NSLocalizedString("Comments", comment: "Inspector tab title: the notes written on the selection")
        case .tools: return NSLocalizedString("Tools", comment: "Inspector tab title: the docked Tool Library")
        }
    }

    /// The tooltip and VoiceOver hint for the tab.
    public var helpText: String {
        switch self {
        case .markup:
            return NSLocalizedString(
                "Label, quantities, colour, notes and review status of the selection.",
                comment: "Inspector Markup tab help"
            )
        case .properties:
            return NSLocalizedString(
                "Scale Region, subject, precision, the calculation, lock state, Project Zone and custom data.",
                comment: "Inspector Properties tab help"
            )
        case .comments:
            return NSLocalizedString(
                "The notes written on the selected markups.",
                comment: "Inspector Comments tab help"
            )
        case .tools:
            return NSLocalizedString(
                "The Tool Library: click a tool to arm it, double-click to edit it.",
                comment: "Inspector Tools tab help"
            )
        }
    }

    /// The ``InspectorSection``s this tab presents.
    ///
    /// The Markup tab draws Appearance and Caption as the mockup's fixed form rather than as
    /// collapsible sections, together with the review status, layer, author and timestamps
    /// that the Status, Layer and Zone, and Identity sections used to carry; those sections
    /// keep what only they show when they appear on the Properties tab.
    public var sections: [InspectorSection] {
        switch self {
        case .markup: return [.appearance, .caption]
        case .properties: return Self.propertiesSections
        case .comments, .tools: return []
        }
    }

    /// The collapsible sections on the Properties tab, in plan order.
    public static let propertiesSections: [InspectorSection] = [
        .measurement, .derivation, .scale, .identity, .status, .layerZone, .customData, .actions
    ]

    /// The Properties tab's sections for one selection (L-99): a selection in which nothing
    /// produces a quantity — a Note, a Text box, a shape — has no number to explain, so "How
    /// This Number Was Calculated" is left out instead of heading an empty derivation.
    public static func propertiesSections(for summary: InspectorSelectionSummary) -> [InspectorSection] {
        guard !summary.isEmpty, summary.markups.allSatisfy({ $0.measurementKind == nil }) else {
            return propertiesSections
        }
        return propertiesSections.filter { $0 != .derivation }
    }

    /// The identifier of the invisible landmark under the tab's button, which the off-screen
    /// hit-target probe finds and clicks (L-90). It never takes a click itself.
    public var markerIdentifier: String { "zpdf.inspector.tab.\(rawValue)" }

    /// The tab a freshly opened Inspector shows.
    public static let initial: InspectorTab = .markup
}
