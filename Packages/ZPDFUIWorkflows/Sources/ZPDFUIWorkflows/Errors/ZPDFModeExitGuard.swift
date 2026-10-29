import Foundation
import Observation

/// The "cannot leave a mode" guard.
///
/// A mode a user cannot leave is worse than a missing feature — the first assembled build
/// trapped its user inside Revision Compare with quitting the application as the only exit. These types make that state unrepresentable at the seam where
/// modes are tracked: a mode can only be registered *with* an exit route, because the route is
/// a non-optional part of the registration. There is no way to construct a registered mode
/// that cannot be left.

/// The way out of one mode: what the menu item says, what the shortcut is, and what leaving does.
public struct ZPDFModeExitRoute {

    /// The localized menu title for the way out, e.g. "Close Revision Compare".
    public var menuTitle: String
    /// The shortcut shown next to the menu title. `Escape` unless the mode says otherwise.
    public var keyboardHint: String
    /// Leaves the mode. Never destructive, never blocked on a question the person cannot see.
    public var performExit: @MainActor () -> Void

    /// Creates an exit route.
    public init(
        menuTitle: String,
        keyboardHint: String = "⎋",
        performExit: @escaping @MainActor () -> Void
    ) {
        self.menuTitle = menuTitle
        self.keyboardHint = keyboardHint
        self.performExit = performExit
    }
}

/// One mode the user is currently inside. It cannot exist without its exit route.
public struct ZPDFRegisteredMode: Identifiable {

    /// Stable identity, e.g. the panel kind's raw value.
    public let id: String
    /// The localized name shown wherever the mode is announced.
    public var displayName: String
    /// The way out. Non-optional by design; that is the whole guard.
    public var exitRoute: ZPDFModeExitRoute

    /// Creates a registration.
    public init(id: String, displayName: String, exitRoute: ZPDFModeExitRoute) {
        self.id = id
        self.displayName = displayName
        self.exitRoute = exitRoute
    }
}

/// The stack of modes the user is inside, newest last.
///
/// `Escape` always backs out one level: the registry pops the newest mode and runs its exit
/// route. The app tier registers a mode when it opens a panel or enters a canvas view mode,
/// unregisters it when the surface closes by any other path, and routes the window-level
/// `Escape` (and the "there is no way out" safety check before presenting anything) through
/// this object.
@MainActor
@Observable
public final class ZPDFModeExitRegistry {

    /// Every mode currently entered, in entry order.
    public private(set) var modes: [ZPDFRegisteredMode] = []

    /// Creates an empty registry.
    public init() {}

    /// The mode `Escape` would leave next, or `nil` when the canvas is bare.
    public var topmost: ZPDFRegisteredMode? { modes.last }

    /// Whether any mode is active.
    public var hasActiveMode: Bool { !modes.isEmpty }

    /// Registers a mode. Registering an id that is already present replaces its registration
    /// in place rather than stacking a duplicate.
    public func register(_ mode: ZPDFRegisteredMode) {
        if let index = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[index] = mode
        } else {
            modes.append(mode)
        }
    }

    /// Registers a mode from its parts. The exit route is required by the signature — the
    /// compiler is the guard.
    public func register(id: String, displayName: String, exitRoute: ZPDFModeExitRoute) {
        register(ZPDFRegisteredMode(id: id, displayName: displayName, exitRoute: exitRoute))
    }

    /// Removes a mode that closed by another path (its own close button, the toolbar toggle).
    public func unregister(id: String) {
        modes.removeAll { $0.id == id }
    }

    /// The exit route for one registered mode, or `nil` when it is not registered.
    public func exitRoute(for id: String) -> ZPDFModeExitRoute? {
        modes.first { $0.id == id }?.exitRoute
    }

    /// `Escape` backs out one level: leaves the newest mode and reports whether there was one.
    ///
    /// The mode is removed *before* its exit runs, so an exit route that re-enters a mode
    /// cannot make `Escape` loop.
    @discardableResult
    public func escapeBacksOutOneLevel() -> Bool {
        guard let top = modes.last else { return false }
        modes.removeLast()
        top.exitRoute.performExit()
        return true
    }

    /// Leaves every mode, newest first. Used before presenting anything that must be visible,
    /// such as the unsaved-changes review at quit.
    ///
    /// Bounded. An exit route that registers a mode on its way out — closing Revision Overlay
    /// back into Split Canvas, say — used to keep the stack non-empty forever, and this is
    /// called first when the app quits: Quit spun on the main actor. Finding BH-834. Each pass
    /// leaves at most as many levels as there were when it started plus a fixed allowance for
    /// modes re-entered on the way out; whatever an exit route registers beyond that is dropped
    /// without running its route again, so the stack always ends empty.
    public func exitAll() {
        var remaining = modes.count + Self.reentryAllowance
        while remaining > 0, escapeBacksOutOneLevel() {
            remaining -= 1
        }
        modes.removeAll()
    }

    /// How many modes exit routes may re-enter during ``exitAll()`` and still be exited
    /// properly.
    static let reentryAllowance = 16
}
