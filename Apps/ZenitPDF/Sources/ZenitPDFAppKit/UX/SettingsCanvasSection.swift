import AppKit

/// Settings ▸ Canvas (NL-UX-14): whether a mouse wheel zooms, whether pages scroll as one
/// continuous strip, and the doors to the keyboard shortcuts (NL-UX-11) and the welcome guide
/// (NL-UX-13).
extension ZenitSettingsWindowController {

    func canvasSection() -> NSView {
        let heading = NSTextField(labelWithString: NSLocalizedString("Canvas", comment: "Settings section title"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        // The controller's own box (`wheelZoomsCheckbox`), never one shared between controllers (K-13).
        let wheel = wheelZoomsCheckbox
        wheel.title = NSLocalizedString(
            "Mouse wheel zooms",
            comment: "Settings ▸ Canvas: a mouse wheel notch zooms about the pointer instead of scrolling"
        )
        wheel.target = self
        wheel.action = #selector(wheelZoomsToggled(_:))
        wheel.state = ZenitCanvasPreferences.current.wheelZooms ? .on : .off
        wheel.setAccessibilityHelp(NSLocalizedString(
            "When on, turning a mouse wheel zooms the drawing about the pointer. A trackpad still scrolls, and ⌘ with the wheel always zooms.",
            comment: "Settings ▸ Canvas: help for the Mouse wheel zooms checkbox"
        ))
        wheel.toolTip = wheel.accessibilityHelp()
        // The column's note style, wrapped at its width: with no width of its own this note
        // measured its whole sentence on one line, wider than the window (L-35).
        let wheelNote = wrappingNote(NSLocalizedString(
            "A trackpad still scrolls, and ⌘ with the wheel always zooms. Hold Shift to scroll sideways.",
            comment: "Settings ▸ Canvas: note under the Mouse wheel zooms checkbox"
        ))

        // Continuous scrolling (ADR-0045): the View menu's toggle, in the place preferences live.
        let continuous = continuousScrollCheckbox
        continuous.title = NSLocalizedString(
            "Continuous scrolling",
            comment: "Settings ▸ Canvas: scroll through every page of a document as one strip"
        )
        continuous.target = self
        continuous.action = #selector(continuousScrollToggled(_:))
        continuous.state = ZenitCanvasPreferences.scrollsContinuously ? .on : .off
        continuous.setAccessibilityHelp(NSLocalizedString(
            "When on, the pages of a document follow one another in one long strip. When off, the canvas shows one page at a time and scrolling past its edge turns the page.",
            comment: "Settings ▸ Canvas: help for the Continuous scrolling checkbox"
        ))
        continuous.toolTip = continuous.accessibilityHelp()
        let continuousNote = wrappingNote(NSLocalizedString(
            "Also in View ▸ Continuous Scroll. While PDF layers are hidden, pages show one at a time.",
            comment: "Settings ▸ Canvas: note under the Continuous scrolling checkbox"
        ))
        // The View menu changes the same preference while this window is open.
        NotificationCenter.default.removeObserver(self, name: ZenitCanvasPreferences.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(canvasPreferencesDidChange(_:)),
            name: ZenitCanvasPreferences.didChangeNotification,
            object: nil
        )

        let shortcuts = NSButton(
            title: NSLocalizedString("Keyboard Shortcuts…", comment: "Settings ▸ Canvas: open the shortcut settings"),
            target: ZenitShortcutSettingsWindowController.shared,
            action: #selector(ZenitShortcutSettingsWindowController.showShortcutSettings(_:))
        )
        let welcome = NSButton(
            title: NSLocalizedString("Show the Welcome Guide Again", comment: "Settings ▸ Canvas: restart the onboarding guide"),
            target: ZenitOnboardingController.shared,
            action: #selector(ZenitOnboardingController.showWelcome(_:))
        )
        let buttons = NSStackView(views: [shortcuts, welcome])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, wheel, wheelNote, continuous, continuousNote, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: wheel)
        stack.setCustomSpacing(4, after: continuous)
        return stack
    }

    @objc func continuousScrollToggled(_ sender: Any?) {
        var preferences = ZenitCanvasPreferences.current
        preferences.pageLayout = continuousScrollCheckbox.state == .on ? .continuous : .singlePage
        ZenitCanvasPreferences.current = preferences
    }

    /// Keeps the box in step with View ▸ Continuous Scroll.
    @objc func canvasPreferencesDidChange(_ note: Notification) {
        let state: NSControl.StateValue = ZenitCanvasPreferences.scrollsContinuously ? .on : .off
        if continuousScrollCheckbox.state != state { continuousScrollCheckbox.state = state }
    }

    @objc func wheelZoomsToggled(_ sender: Any?) {
        var preferences = ZenitCanvasPreferences.current
        preferences.wheelZooms = wheelZoomsCheckbox.state == .on
        ZenitCanvasPreferences.current = preferences
    }
}
