import Foundation

/// Every panel and mode this package ships, as one enumerable list.
///
/// The list exists so the no-dead-ends rule is testable generically: a regression test iterates
/// `allCases`, registers each kind in a ``ZPDFModeExitRegistry``, and asserts `Escape` backs out
/// of it. Adding a surface to this package means adding a case here, and the exhaustive switch
/// in the test target refuses to compile until the new surface proves it can be closed.
public enum WorkflowPanelKind: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// The Tool Library panel.
    case toolLibrary
    /// The search panel.
    case search
    /// The OCR run sheet.
    case ocrRun
    /// The first-run onboarding card.
    case onboarding
    /// Revision Compare, as a canvas view mode.
    case revisionCompare
    /// Revision Overlay, as a canvas view mode.
    case revisionOverlay
    /// Split Canvas, as a canvas view mode.
    case splitCanvas
    /// The scoped batch apply sheet.
    case batchApply

    /// Stable identity.
    public var id: String { rawValue }

    /// The localized panel name.
    public var displayName: String {
        switch self {
        case .toolLibrary:
            return NSLocalizedString("Tool Library", comment: "Panel name")
        case .search:
            return NSLocalizedString("Search", comment: "Panel name")
        case .ocrRun:
            return NSLocalizedString("Read Text from Scanned Pages", comment: "Panel name for the OCR sheet")
        case .onboarding:
            return NSLocalizedString("Getting Started", comment: "Panel name for the onboarding card")
        case .revisionCompare:
            return NSLocalizedString("Revision Compare", comment: "Panel name")
        case .revisionOverlay:
            return NSLocalizedString("Revision Overlay", comment: "Panel name")
        case .splitCanvas:
            return NSLocalizedString("Split Canvas", comment: "Panel name")
        case .batchApply:
            return NSLocalizedString("Batch Apply", comment: "Panel name for the scoped batch apply sheet")
        }
    }

    /// The localized menu title for leaving this surface.
    public var closeMenuTitle: String {
        String(
            format: NSLocalizedString("Close %@", comment: "Menu item: close a named panel"),
            displayName
        )
    }

    /// Builds the registry entry for this surface. The close action is a required parameter,
    /// so no panel kind can be registered as a mode without a way out.
    @MainActor
    public func makeRegistration(onClose: @escaping @MainActor () -> Void) -> ZPDFRegisteredMode {
        ZPDFRegisteredMode(
            id: rawValue,
            displayName: displayName,
            exitRoute: ZPDFModeExitRoute(menuTitle: closeMenuTitle, performExit: onClose)
        )
    }
}
