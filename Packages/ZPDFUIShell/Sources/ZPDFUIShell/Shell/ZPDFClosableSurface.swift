import Foundation
import ZPDFDesignSystem

/// Every surface of the project window a person can close and then have to find again.
///
/// ## Why this is an enumeration and not four hand-written call sites
///
/// The same defect was reported on three panes at once: the `✕` on the Navigator, the
/// Inspector and the Quantity Ledger each removed a pane with nothing left behind and no menu
/// item anywhere that brought it back. Fixing three call sites would leave
/// the fourth surface — History, the bottom pane's other tab — and the fifth, whenever it is
/// added, to be remembered by whoever adds them. This project's own record says that is not a
/// rule, it is a hope: six built-but-unwired surfaces so far.
///
/// So the list is a type. Adding a closable surface means adding a case, and the compiler then
/// demands an edge and a command for it; `ClosableSurfaceAffordanceTests` demands the menu item
/// and the ear. A new panel with neither does not build, and if it builds it does not pass.
public enum ZPDFClosableSurface: String, CaseIterable, Hashable, Sendable, Identifiable {

    /// The left sidebar: pages, layers, search, zones.
    case navigator
    /// The right sidebar: the selection's properties.
    case inspector
    /// The bottom pane's Quantities tab: the Quantity Ledger table.
    case quantityLedger
    /// The bottom pane's History tab: the project's append-only audit trail.
    case history

    /// Stable identity.
    public var id: String { rawValue }

    /// The pane's name, as every surface in the application says it.
    public var displayName: String {
        switch self {
        case .navigator:
            return NSLocalizedString("Navigator", comment: "Pane name")
        case .inspector:
            return NSLocalizedString("Inspector", comment: "Pane name")
        case .quantityLedger:
            return NSLocalizedString("Quantity Ledger", comment: "Pane name")
        case .history:
            return NSLocalizedString("History", comment: "Pane name")
        }
    }

    /// Which window edge the surface lives on, and therefore where its ear sits.
    ///
    /// The Quantity Ledger and History share the bottom edge because they share the pane: they
    /// are two tabs of one split item, so closing either closes both and the bottom edge shows
    /// both ears.
    public var edge: ZPDFPaneEdge {
        switch self {
        case .navigator: return .leading
        case .inspector: return .trailing
        case .quantityLedger, .history: return .bottom
        }
    }

    /// The command that shows the surface, and hides it again.
    public var command: ZPDFCommandID {
        switch self {
        case .navigator: return .toggleNavigator
        case .inspector: return .toggleInspector
        case .quantityLedger: return .toggleQuantityLedger
        case .history: return .toggleHistory
        }
    }

    /// The surface a pane command belongs to, or `nil` for a command that is not one.
    public init?(command: ZPDFCommandID) {
        guard let match = Self.allCases.first(where: { $0.command == command }) else { return nil }
        self = match
    }

    /// The menu item's title for the current state.
    ///
    /// The title flips rather than the item gaining a checkmark, because the menu is read as an
    /// instruction — *"Show Inspector"* answers "how do I get it back" at the moment the pane is
    /// gone, which is the only moment anybody goes looking.
    public func menuTitle(isVisible: Bool) -> String {
        isVisible ? hideTitle : showTitle
    }

    /// The *"Show …"* form: the ear's VoiceOver label, and the menu title while the pane is gone.
    public var showTitle: String {
        switch self {
        case .navigator:
            return NSLocalizedString("Show Navigator", comment: "Menu item and ear label")
        case .inspector:
            return NSLocalizedString("Show Inspector", comment: "Menu item and ear label")
        case .quantityLedger:
            return NSLocalizedString("Show Quantity Ledger", comment: "Menu item and ear label")
        case .history:
            return NSLocalizedString("Show History", comment: "Menu item and ear label")
        }
    }

    /// The *"Hide …"* form: the menu title while the pane is on screen.
    public var hideTitle: String {
        switch self {
        case .navigator:
            return NSLocalizedString("Hide Navigator", comment: "Menu item")
        case .inspector:
            return NSLocalizedString("Hide Inspector", comment: "Menu item")
        case .quantityLedger:
            return NSLocalizedString("Hide Quantity Ledger", comment: "Menu item")
        case .history:
            return NSLocalizedString("Hide History", comment: "Menu item")
        }
    }

    /// The surfaces sharing one edge, in the order their ears are drawn along it.
    public static func surfaces(on edge: ZPDFPaneEdge) -> [ZPDFClosableSurface] {
        allCases.filter { $0.edge == edge }
    }
}

/// Which tab of the bottom pane is showing.
///
/// Lifted out of `QuantityLedgerPane`'s private `@State` so the surface can be reached from
/// outside it: *Show History* has to be able to open the pane **on** History, and a tab that
/// only the pane's own segmented control can reach is not a surface a menu item can serve.
public enum ZPDFBottomPaneTab: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {

    /// The Quantity Ledger table.
    case quantities
    /// The project's audit trail.
    case history

    /// Stable identity.
    public var id: String { rawValue }

    /// The tab's title in the pane's segmented control.
    public var title: String {
        switch self {
        case .quantities:
            return NSLocalizedString("Quantities", comment: "Bottom pane tab: the Quantity Ledger table")
        case .history:
            return NSLocalizedString("History", comment: "Bottom pane tab: the project audit trail")
        }
    }

    /// The closable surface this tab is.
    public var surface: ZPDFClosableSurface {
        switch self {
        case .quantities: return .quantityLedger
        case .history: return .history
        }
    }
}
