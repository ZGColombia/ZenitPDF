import AppKit
import ZPDFAppCore
import ZPDFUIShell

/// Settings ▸ Markup Tools (nl-markup, NL-MARKUP-04): whether a markup tool draws the style last
/// used for its kind, or only the style set with *Set as Default*.
extension ZenitSettingsWindowController {

    /// The checkbox, reachable so tests can drive the exact action it sends.
    static let remembersToolStyleCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    func markupSection() -> NSView {
        let heading = NSTextField(labelWithString: NSLocalizedString("Markup Tools", comment: "Settings section title"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let remembers = Self.remembersToolStyleCheckbox
        remembers.title = NSLocalizedString(
            "Tools remember the last style I used",
            comment: "Settings ▸ Markup Tools: each markup tool draws the style last given to its kind"
        )
        remembers.target = self
        remembers.action = #selector(remembersToolStyleToggled(_:))
        remembers.state = MarkupStyleDefaultsHost.shared.remembersLastUsed ? .on : .off
        remembers.setAccessibilityHelp(NSLocalizedString(
            "When off, a tool changes its style only through Set as Default.",
            comment: "Settings ▸ Markup Tools: accessibility help of the style memory checkbox"
        ))

        let note = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "When this is off, a markup tool draws the style set with Set as Default for its kind, from the markup's context menu or the Inspector.",
            comment: "Settings ▸ Markup Tools: explanation"
        ))
        note.preferredMaxLayoutWidth = 420
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // NL-UX-14: the units a new project starts in.
        let unitsLabel = NSTextField(labelWithString: NSLocalizedString("Units for new projects:", comment: "Settings: the default units of a new project"))
        let units = Self.newProjectUnitsPopup
        units.removeAllItems()
        for choice in NewProjectUnits.allCases {
            units.addItem(withTitle: choice.title)
            units.lastItem?.representedObject = choice.rawValue
        }
        units.selectItem(at: NewProjectUnits.allCases.firstIndex(of: NewProjectUnits.current) ?? 0)
        units.target = self
        units.action = #selector(newProjectUnitsChosen(_:))
        units.setAccessibilityLabel(NSLocalizedString("Units for new projects", comment: "Settings: accessibility label of the new-project units popup"))
        let unitsRow = NSStackView(views: [unitsLabel, units])
        unitsRow.orientation = .horizontal
        unitsRow.spacing = 8

        let stack = NSStackView(views: [heading, remembers, note, unitsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    /// The new-project units popup, reachable so tests can drive it (NL-UX-14).
    static let newProjectUnitsPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    @objc func newProjectUnitsChosen(_ sender: Any?) {
        guard let raw = Self.newProjectUnitsPopup.selectedItem?.representedObject as? String,
              let choice = NewProjectUnits(rawValue: raw) else { return }
        NewProjectUnits.current = choice
    }

    @objc func remembersToolStyleToggled(_ sender: Any?) {
        MarkupStyleDefaultsHost.shared.remembersLastUsed = Self.remembersToolStyleCheckbox.state == .on
    }
}

/// The units a drawing with no saved takeoff starts in (NL-UX-14, r2-markup). Kept in the
/// process defaults, so a test process never writes the user's preferences.
enum NewProjectUnits: String, CaseIterable, Codable, Sendable {
    case metric
    case imperial

    static let defaultsKey = "Zenit.NewProjectUnits"

    var title: String {
        switch self {
        case .metric: NSLocalizedString("Metric (m, m², m³)", comment: "Settings: metric units for new projects")
        case .imperial: NSLocalizedString("Imperial (ft, ft², yd³)", comment: "Settings: imperial units for new projects")
        }
    }

    var selection: DisplayUnitSelection {
        switch self {
        case .metric: .metric
        case .imperial: .imperial
        }
    }

    @MainActor
    static var current: NewProjectUnits {
        get { ZenitProcessDefaults.layout.decode(NewProjectUnits.self, forKey: defaultsKey) ?? .metric }
        set { ZenitProcessDefaults.layout.encode(newValue, forKey: defaultsKey) }
    }
}
