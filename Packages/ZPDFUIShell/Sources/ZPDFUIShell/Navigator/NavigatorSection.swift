import Foundation
import ZPDFDesignSystem

/// The pages of the Navigator sidebar.
///
/// The mockup fixes the switcher to Pages · Layers · Zones · Search; the
/// mockup has no Bookmarks page, so the shell ships none.
public enum NavigatorSection: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Every open drawing, as a thumbnail, the way Pages shows the pages of one (2026-08-27).
    /// With thirty one-page drawings open, a drawing is recognised by
    /// its picture, not by its file name, and with thirty sheets open the tab bar is unusable.
    case drawings
    /// Page thumbnails for the active document.
    case pages
    /// Markup layers and their visibility.
    case layers
    /// Project Zones and their visibility.
    case zones
    /// Search across text, OCR text, markups and custom fields.
    case search

    public var id: String { rawValue }

    /// The switcher label.
    public var displayName: String {
        switch self {
        case .drawings: return NSLocalizedString("Open Drawings", comment: "Navigator section name")
        case .pages: return NSLocalizedString("Pages", comment: "Navigator section name")
        case .layers: return NSLocalizedString("Layers", comment: "Navigator section name")
        case .zones: return NSLocalizedString("Project Zones", comment: "Navigator section name")
        case .search: return NSLocalizedString("Search", comment: "Navigator section name")
        }
    }

    /// The short segment label the switcher shows, per the mockup: `Pages · Layers ·
    /// Zones · Search` in a ~150 pt sidebar. The full name stays in ``displayName`` for
    /// menus and VoiceOver.
    public var switcherTitle: String {
        switch self {
        // "Drawings", not "Files" (IM-216): one term, short here and long in `displayName`,
        // so the segment, the tooltip and VoiceOver name the same thing.
        case .drawings: return NSLocalizedString("Drawings", comment: "Navigator switcher segment, short for Open Drawings")
        case .zones: return NSLocalizedString("Zones", comment: "Navigator switcher segment, short for Project Zones")
        default: return displayName
        }
    }

    /// The switcher icon.
    public var glyph: ZPDFGlyph {
        switch self {
        // Not the Workspaces glyph (IM-216): Workspaces is a distinct Zenit feature (saved
        // window layouts), and borrowing its icon for the open-drawings list blurred the two.
        case .drawings: return .symbol(.open)
        case .pages: return .symbol(.pages)
        case .layers: return .symbol(.layers)
        case .zones: return .symbol(.projectZones)
        case .search: return .symbol(.search)
        }
    }

    /// The identifier of the invisible landmark under the switcher tab, which the off-screen
    /// click probe finds and clicks (L-108). It never takes a click itself.
    public var markerIdentifier: String { "zpdf.navigator.tab.\(rawValue)" }

    /// Hover help, also used as the VoiceOver hint on the switcher segment.
    public var helpText: String {
        switch self {
        case .drawings:
            return NSLocalizedString("Every open drawing; click one to switch to it", comment: "Navigator section help")
        case .pages:
            return NSLocalizedString("Browse the pages of this document", comment: "Navigator section help")
        case .layers:
            return NSLocalizedString("Show or hide markup layers", comment: "Navigator section help")
        case .zones:
            return NSLocalizedString("Show or hide Project Zones", comment: "Navigator section help")
        case .search:
            return NSLocalizedString("Search this document", comment: "Navigator section help")
        }
    }
}
