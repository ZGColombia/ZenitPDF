import AppKit
import ZPDFAppCore

/// Settings ▸ Measuring (NL-MEASURE-13): the double-count guard, on by default.
extension ZenitSettingsWindowController {

    /// The guard's checkbox, reachable so tests drive the exact action it sends.
    static let doubleCountGuardCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    func measuringSection() -> NSView {
        let heading = NSTextField(labelWithString: NSLocalizedString("Measuring", comment: "Settings section title"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let guardBox = Self.doubleCountGuardCheckbox
        guardBox.title = NSLocalizedString(
            "Warn when two areas of the same subject overlap",
            comment: "Settings ▸ Measuring: the double-count guard"
        )
        guardBox.setAccessibilityLabel(guardBox.title)
        guardBox.target = self
        guardBox.action = #selector(doubleCountGuardToggled(_:))
        guardBox.state = AppCoreEnvironment.doubleCountGuardEnabled() ? .on : .off
        let note = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "Both areas are summed, so the shared part is counted twice. The overlap is hatched on the sheet and named in the warning tray.",
            comment: "Settings ▸ Measuring: what the double-count guard does"
        ))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [heading, guardBox, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    @objc func doubleCountGuardToggled(_ sender: Any?) {
        Self.setDoubleCountGuard(Self.doubleCountGuardCheckbox.state == .on)
    }

    /// Stores the choice and re-runs the guard in every open document, so the tray and the hatch
    /// follow at once.
    static func setDoubleCountGuard(_ enabled: Bool, defaults: UserDefaults = .standard, documents: [NSDocument]? = nil) {
        defaults.set(enabled, forKey: AppCoreEnvironment.doubleCountGuardDefaultsKey)
        for case let document as ZenitPDFProjectDocument in documents ?? NSDocumentController.shared.documents {
            guard let core = document.core else { continue }
            Task { @MainActor in await core.refreshDoubleCountWarnings(enabled: enabled) }
        }
    }
}
