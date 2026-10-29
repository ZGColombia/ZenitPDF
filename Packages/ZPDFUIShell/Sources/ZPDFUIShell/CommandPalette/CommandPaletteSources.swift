import Foundation
import ZPDFUIPresentation

/// The rows the shell contributes to the command palette (NL-UX-05).
extension ProjectShellEnvironment {

    /// Every row the palette offers right now: the command table, the Tool Library's presets,
    /// the pages, "select every markup with this subject on the page", and whatever the app
    /// tier adds.
    public func commandPaletteItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        let validator = commandPaletteValidator
        for command in commands.commands {
            let id = command.id
            items.append(CommandPaletteItem(
                id: "command:\(id.rawValue)",
                title: Self.paletteTitle(command.title),
                detail: command.group.displayName,
                category: command.group == .tools || command.group == .measure ? .tool : .command,
                shortcut: command.binding?.displayString,
                keywords: Self.paletteKeywords(for: id),
                isEnabled: validator?(id) ?? true,
                perform: { [weak self] in self?.perform(id) }
            ))
        }
        for preset in toolLibrary.presets {
            let presetID = preset.id
            items.append(CommandPaletteItem(
                id: "preset:\(presetID.uuidString)",
                title: preset.name,
                detail: NSLocalizedString("Tool Library", comment: "Sheet title"),
                category: .preset,
                keywords: preset.defaultSubject.isEmpty ? [] : [preset.defaultSubject],
                perform: { [weak self] in self?.toolLibrary.activatePreset(id: presetID) }
            ))
        }
        for (index, page) in document.pages.enumerated() {
            items.append(CommandPaletteItem(
                id: "page:\(page.id)",
                title: String(
                    format: NSLocalizedString("Go to %@", comment: "Command palette row: go to a page; the placeholder is the sheet's number and name, or the page label"),
                    Self.paletteSheetName(page)
                ),
                detail: NSLocalizedString("Page", comment: "Command palette row category"),
                category: .page,
                keywords: Self.paletteKeywords(forPage: page, position: index),
                perform: { [weak self] in self?.goToPage(index: index) }
            ))
        }
        let bySubject = Dictionary(grouping: canvas.visibleMarkups.filter { !$0.subject.isEmpty }, by: \.subject)
        for subject in bySubject.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let ids = Set(bySubject[subject]?.map(\.id) ?? [])
            items.append(CommandPaletteItem(
                id: "subject:\(subject)",
                title: String(
                    format: NSLocalizedString(
                        "Select All “%@” on This Page",
                        comment: "Command palette row: select every markup with this subject on the page"
                    ),
                    subject
                ),
                detail: String(
                    format: NSLocalizedString("%ld markups", comment: "Command palette row detail: how many markups a selection row selects"),
                    ids.count
                ),
                category: .selection,
                keywords: [subject],
                perform: { [weak self] in self?.canvas.select(markupIDs: ids, additive: false) }
            ))
        }
        items.append(contentsOf: commandPaletteExtraItems?() ?? [])
        return items
    }

    /// How a page row names its sheet (S-058, NL-DOCS-05): the sheet number the set gives it,
    /// else the PDF label, then the sheet's name when it says more — "A-101 · SITE PLAN" for a
    /// sheet whose PDF label is "3", where the row used to read "Go to 3".
    static func paletteSheetName(_ page: PageDescriptor) -> String {
        let identity = page.sheetNumber.flatMap { $0.isEmpty ? nil : $0 } ?? page.label
        guard let name = NavigatorPageCard.sheetName(for: page) else { return identity }
        // A name that already carries the number ("A-102 Floor Plan") says everything.
        if name.range(of: identity, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return name }
        return String(
            format: NSLocalizedString("%1$@ · %2$@", comment: "Command palette page row: sheet number or label, sheet name"),
            identity, name
        )
    }

    /// What a page row answers to: the PDF label, the position, the sheet number (also as the
    /// core compares it, so "a101" finds "A-101") and the sheet's name (S-058).
    static func paletteKeywords(forPage page: PageDescriptor, position: Int) -> [String] {
        var keywords = [page.label, String(position + 1)]
        if let number = page.sheetNumber, !number.isEmpty {
            keywords.append(number)
            let normalised = PageDescriptor.normalisedSheetNumber(number)
            if normalised != number { keywords.append(normalised) }
        }
        if let title = page.sheetTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            keywords.append(title)
        }
        return keywords
    }

    /// A menu title without its trailing ellipsis, so "Export…" reads "Export" in a list
    /// that is itself the place you chose it from.
    public static func paletteTitle(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// Words a person may type for a command that its title does not contain.
    static func paletteKeywords(for id: ZPDFCommandID) -> [String] {
        switch id {
        case .calibrateScale:
            return [NSLocalizedString("scale", comment: "Command palette keyword for Calibrate")]
        case .measureArea:
            return [NSLocalizedString("square", comment: "Command palette keyword for Area")]
        case .find:
            return [NSLocalizedString("search", comment: "Command palette keyword for Find")]
        case .toggleQuantityLedger:
            return [NSLocalizedString("quantities", comment: "Command palette keyword for the Quantity Ledger")]
        default:
            return []
        }
    }
}
