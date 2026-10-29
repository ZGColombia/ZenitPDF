import AppKit

/// The project window.
///
/// Two overrides that matter.
///
/// View ▸ Hide Toolbar. The window's `NSToolbar` is hidden on purpose — the top band draws the
/// tools (``ProjectTopBandView``) — so AppKit's own `toggleToolbarShown(_:)` would *show* that
/// hidden toolbar under the band, a second copy of every tool. Here the command collapses the band
/// to its tab row instead, or brings it back, and the menu item's title says which.
///
/// Event dispatch (L-108). Every left press and release is counted by a ``ZPDFClickCounter``
/// before AppKit dispatches it, so a press counts as the second click of a double-click only at
/// the place of the first. AppKit sends a press counted 2 or more to the view that took the
/// previous press without hit-testing; a click on any control within half a second of a click
/// somewhere else went to that somewhere else and was lost.
@MainActor
public final class ZPDFProjectWindow: NSWindow {

    /// The layout filling the window, when it is a project layout.
    private var layout: ProjectWindowLayoutController? {
        contentViewController as? ProjectWindowLayoutController
    }

    /// The window's left-press count (L-108). Internal so tests can read what was counted.
    private(set) var clickCounter = ZPDFClickCounter()

    public override func sendEvent(_ event: NSEvent) {
        super.sendEvent(clickCountedEvent(event))
    }

    /// `event` as AppKit is handed it: a left press or release carrying the count
    /// ``ZPDFClickCounter`` gives it, every other event untouched. Runs once per event, from
    /// ``sendEvent(_:)``; public so the tests and the off-screen click probe can run the rule on
    /// real events, because a window that is never ordered in — every test window — does not
    /// dispatch a mouse event at all.
    public func clickCountedEvent(_ event: NSEvent) -> NSEvent {
        switch event.type {
        case .leftMouseDown:
            let count = clickCounter.countForPress(
                systemCount: event.clickCount,
                timestamp: event.timestamp,
                location: event.locationInWindow,
                interval: NSEvent.doubleClickInterval
            )
            return Self.event(event, withClickCount: count)
        case .leftMouseUp:
            return Self.event(event, withClickCount: clickCounter.countForRelease(systemCount: event.clickCount))
        default:
            return event
        }
    }

    /// `event` with another click count — its type, place, modifiers, time, window, event number
    /// and pressure kept, built the way AppKit builds the single presses it substitutes for a
    /// double-click itself (a tablet's extra fields are not carried). The same event when the
    /// count already matches, which is every press but a far one counted 2 or more.
    static func event(_ event: NSEvent, withClickCount count: Int) -> NSEvent {
        guard count != event.clickCount else { return event }
        return NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: count,
            pressure: event.pressure
        ) ?? event
    }

    public override func toggleToolbarShown(_ sender: Any?) {
        guard let layout else {
            super.toggleToolbarShown(sender)
            return
        }
        layout.toggleTopBandShown()
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleToolbarShown(_:)), let layout {
            menuItem.title = Self.toolbarMenuTitle(isShown: layout.isTopBandShown)
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    /// The View menu's title for the toolbar command.
    static func toolbarMenuTitle(isShown: Bool) -> String {
        isShown
            ? NSLocalizedString("Hide Toolbar", comment: "View menu command")
            : NSLocalizedString("Show Toolbar", comment: "View menu command")
    }
}
