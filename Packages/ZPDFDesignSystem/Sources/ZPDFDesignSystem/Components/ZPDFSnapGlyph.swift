import SwiftUI

/// The snapping modes Zenit offers, matching the three indicators in the status bar.
public enum ZPDFSnapKind: String, CaseIterable, Sendable, Hashable {
    /// Snap to geometry recovered from the page's own vector content.
    case vector
    /// Snap to the working grid.
    case grid
    /// Snap to existing Zenit markup.
    case markup

    public var icon: ZPDFIconKind {
        switch self {
        case .vector: return .vectorSnap
        case .grid: return .gridSnap
        case .markup: return .markupSnap
        }
    }

    public var title: String {
        switch self {
        case .vector: return NSLocalizedString("Vector Snap", comment: "Snapping mode name")
        case .grid: return NSLocalizedString("Grid Snap", comment: "Snapping mode name")
        case .markup: return NSLocalizedString("Markup Snap", comment: "Snapping mode name")
        }
    }
}

/// Whether a snap mode is switched on, as the status strip speaks it.
///
/// Two states only. An "engaged" state (a candidate acquired right now) was declared but never
/// produced — the strip builds `.armed` or `.off` from the toggle — so it was removed (T-036).
/// The canvas announces an acquired snap itself ("Snapped", `CanvasPageView`).
public enum ZPDFSnapState: String, CaseIterable, Sendable, Hashable {
    /// The mode is switched off.
    case off
    /// The mode is on and waiting for a candidate.
    case armed

    /// The spoken state, so the status is never carried by tint alone.
    public var spokenName: String {
        switch self {
        case .off: return NSLocalizedString("Off", comment: "Snap state: the mode is disabled")
        case .armed: return NSLocalizedString("On", comment: "Snap state: the mode is enabled and waiting")
        }
    }
}
