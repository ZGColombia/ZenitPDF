import Foundation
import Observation
import ZPDFUIPresentation

/// The canvas-replacing view modes: Compare, Overlay and Split Canvas.
///
/// These are *view modes* of the document, not overlays sitting
/// on top of it. Entering one changes what the canvas shows; leaving it restores exactly the
/// previous view, scroll position and zoom. The types here are the contract that makes leaving
/// possible: a mode is entered with a return token, and leaving hands the token back.
public enum DismissibleCanvasMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Revision Compare.
    case revisionCompare
    /// Revision Overlay.
    case revisionOverlay
    /// Split Canvas.
    case splitCanvas

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for menus and the mode indicator.
    public var displayName: String {
        switch self {
        case .revisionCompare:
            return NSLocalizedString("Revision Compare", comment: "Canvas view mode name")
        case .revisionOverlay:
            return NSLocalizedString("Revision Overlay", comment: "Canvas view mode name")
        case .splitCanvas:
            return NSLocalizedString("Split Canvas", comment: "Canvas view mode name")
        }
    }
}

/// Everything needed to put the canvas back exactly as it was before a view mode took it over.
///
/// The app tier captures one of these at the moment a mode is entered and restores from it at
/// the moment the mode is left. The token is `Codable` so a workspace can persist it across a
/// relaunch that happens mid-mode.
public struct CanvasReturnToken: Codable, Hashable, Sendable {

    /// The document that was showing, or `nil` when the mode was entered with no document.
    public var documentID: UUID?
    /// The exact viewport — page, zoom, scroll, rotation — to restore.
    public var viewport: ViewportSnapshot

    /// Creates a return token.
    public init(documentID: UUID? = nil, viewport: ViewportSnapshot) {
        self.documentID = documentID
        self.viewport = viewport
    }
}

/// Tracks which canvas view mode is active and holds the way back out of it.
///
/// The rule this class exists to enforce: a mode cannot be entered without the coordinator
/// holding the state needed to leave it, and `leave()` always works. Switching directly from
/// one mode to another keeps the *original* token, because the view the person wants back is
/// the one they had before any mode took the canvas.
@MainActor
@Observable
public final class CanvasViewModeCoordinator {

    /// The mode the canvas is in, or `nil` when the canvas is the plain document view.
    public private(set) var activeMode: DismissibleCanvasMode?
    /// The view to restore on leave, captured when the first mode was entered.
    public private(set) var returnToken: CanvasReturnToken?

    /// Runs when a mode is left, with the mode that ended and the token to restore from.
    /// The app tier wires this to the canvas.
    public var onLeave: (@MainActor (DismissibleCanvasMode, CanvasReturnToken?) -> Void)?

    /// Creates a coordinator with no mode active.
    public init() {}

    /// Whether a view mode currently owns the canvas.
    public var isInMode: Bool { activeMode != nil }

    /// Enters a mode, or switches to it when another mode is already active.
    ///
    /// - Parameters:
    ///   - mode: the mode taking over the canvas.
    ///   - token: the view to come back to. Kept only when no mode is active yet, so a
    ///     mode-to-mode switch still returns to the true previous view.
    public func enter(_ mode: DismissibleCanvasMode, returning token: CanvasReturnToken?) {
        if activeMode == nil {
            returnToken = token
        }
        activeMode = mode
    }

    /// Leaves the active mode and returns the token to restore from.
    ///
    /// Safe to call when no mode is active; it does nothing and returns `nil`.
    @discardableResult
    public func leave() -> CanvasReturnToken? {
        guard let mode = activeMode else { return nil }
        let token = returnToken
        activeMode = nil
        returnToken = nil
        onLeave?(mode, token)
        return token
    }
}
