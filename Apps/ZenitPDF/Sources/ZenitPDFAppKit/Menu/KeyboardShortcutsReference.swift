import AppKit
import ZPDFUIShell

/// Help ▸ Keyboard Shortcuts (IM-251): a reference generated from the same command table the
/// menus are built from, plus the application commands that carry a key equivalent, so it
/// cannot drift from what the keys actually do. Local content only; nothing links out.
@MainActor
enum KeyboardShortcutsReference {

    struct Entry: Equatable, Sendable {
        var title: String
        var shortcut: String
        /// Where the chord is live, when that is narrower than "everywhere".
        var context: String?
    }

    struct Section: Equatable, Sendable {
        var title: String
        var entries: [Entry]
    }

    static let modalIdentifier = "help.keyboardShortcuts"

    /// Every bound shell command, grouped by menu, then the application commands' own chords.
    ///
    /// The chords are read from `menuBar` — the installed bar when the panel is shown — and the
    /// table only fills in what the bar does not carry (the canvas's tool letters). The bar is
    /// the truth because AppKit edits a document application's File menu at launch: Save As
    /// moves to ⌥⇧⌘S and Duplicate takes ⇧⌘S. A reference built from the table alone printed
    /// Save As as ⇧⌘S and left Duplicate out (L-97).
    static func sections(
        // NL-UX-11: the table in force, so a customised shortcut is what the reference prints.
        table: ZPDFCommandTable = .effective,
        menuBar: NSMenu? = nil
    ) -> [Section] {
        // A bar built only to be read when none is installed. Building one no longer touches
        // `NSApplication`'s menu roles (R-017), and it is built from the same `table`, so a
        // customised chord is what the reference prints.
        let menuBar = menuBar ?? ZenitMenuBar.make(table: table)
        let rows = Dictionary(
            ZenitMenuBar.commandItems(in: menuBar).compactMap { row in row.commandID.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first }
        )
        var sections: [Section] = []
        for group in ZPDFCommandGroup.allCases.sorted(by: { $0.menuOrder < $1.menuOrder }) {
            var entries = table.commands(in: group).compactMap { command -> Entry? in
                guard let shortcut = shortcut(for: command, row: rows[command.id]) else { return nil }
                return Entry(
                    title: command.title,
                    shortcut: shortcut,
                    context: command.context == .application ? nil : command.context.displayName
                )
            }
            entries += systemRows(in: menuBar, titled: group.displayName)
            if !entries.isEmpty { sections.append(Section(title: group.displayName, entries: entries)) }
        }
        var appEntries: [Entry] = []
        var seen: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let nested = item.submenu { walk(nested) }
                guard let raw = item.representedObject as? String, ZenitAppCommand(rawValue: raw) != nil,
                      !item.keyEquivalent.isEmpty, !item.isHidden else { continue }
                let shortcut = printed(item)
                guard seen.insert(item.title + shortcut).inserted else { continue }
                appEntries.append(Entry(title: item.title, shortcut: shortcut, context: nil))
            }
        }
        walk(menuBar)
        if !appEntries.isEmpty {
            sections.append(Section(
                title: NSLocalizedString("More Commands", comment: "Keyboard shortcut reference section for application commands"),
                entries: appEntries
            ))
        }
        return sections
    }

    /// A shell command's printed chord: its row's key equivalent when the bar carries one that
    /// differs from the table's (AppKit moved it, L-97), the table's spelling otherwise, `nil`
    /// for a command with no chord.
    private static func shortcut(for command: ZPDFCommand, row: ZenitCommandMenuItem?) -> String? {
        guard let binding = command.binding else { return nil }
        guard let row, let tableChord = ZenitMenuBar.menuChord(for: command) else {
            return binding.displayString
        }
        let rowChord = ZenitMenuChord(menuItem: row)
        if row.keyEquivalent.isEmpty || rowChord == tableChord { return binding.displayString }
        return printed(row)
    }

    /// The rows with a key equivalent that a table menu holds but the table does not describe:
    /// New, Cut, Copy and Paste, Enter Full Screen — and the ones AppKit inserts into a document
    /// application's File menu at launch, Duplicate among them (L-97).
    private static func systemRows(in menuBar: NSMenu, titled title: String) -> [Entry] {
        guard let menu = menuBar.items.first(where: { $0.submenu?.title == title })?.submenu else { return [] }
        return menu.items.compactMap { item -> Entry? in
            guard !(item is ZenitCommandMenuItem), !item.isSeparatorItem, !item.isHidden,
                  !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.contains(.command) else { return nil }
            if let raw = item.representedObject as? String, ZenitAppCommand(rawValue: raw) != nil { return nil }
            return Entry(title: item.title, shortcut: printed(item), context: nil)
        }
    }

    /// A menu row's key equivalent as the menu prints it — an upper-case letter with its
    /// implied ⇧, so AppKit's Duplicate ("S", ⌘ alone in its mask) reads ⇧⌘S, not Save's ⌘S
    /// (L-97).
    static func printed(_ item: NSMenuItem) -> String {
        let chord = ZenitMenuChord(menuItem: item)
        return ZPDFModifierFlags(chord.modifiers).displayString + displayKey(chord.key)
    }

    /// The printable form of a menu key equivalent.
    static func displayKey(_ key: String) -> String {
        switch key {
        case "\t": return "⇥"
        case "\r": return "↩"
        case " ": return NSLocalizedString("Space", comment: "Key name")
        default: return key.uppercased()
        }
    }

    /// The reference as plain text, one line per chord: "⌘S  Save".
    static func text(for sections: [Section]) -> String {
        sections.map { section in
            ([section.title] + section.entries.map { entry in
                let context = entry.context.map { "  (\($0))" } ?? ""
                return "\t\(entry.shortcut)\t\(entry.title)\(context)"
            }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The font the reference is set in. Proportional: in the monospaced face the modifier
    /// glyphs fall back to a wider font and ran into the command names (L-97).
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    /// The gap between the chord column and the command names.
    static let columnGap: CGFloat = 14

    /// Where the command names start: past the widest chord in `sections`, so no chord can run
    /// into its name.
    static func titleColumn(for sections: [Section]) -> CGFloat {
        let widest = sections.flatMap(\.entries).map {
            ($0.shortcut as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(widest) + columnGap
    }

    /// The reference as two aligned columns: each chord right-aligned against a tab stop past
    /// the widest chord, each name left-aligned after it, the section titles bold.
    ///
    /// The panel used to show ``text(for:)`` in a monospaced text view with the default 28 pt
    /// tab stops, so a three-glyph chord such as "⌥⌘N" ran straight into its name ("⌥⌘NShow
    /// Navigator", L-97).
    static func attributedText(for sections: [Section]) -> NSAttributedString {
        let column = titleColumn(for: sections)
        let entryStyle = NSMutableParagraphStyle()
        entryStyle.tabStops = [
            NSTextTab(textAlignment: .right, location: column - columnGap),
            NSTextTab(textAlignment: .left, location: column)
        ]
        entryStyle.headIndent = column
        entryStyle.paragraphSpacing = 2
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 10
        headingStyle.paragraphSpacing = 4
        let result = NSMutableAttributedString()
        for (index, section) in sections.enumerated() {
            result.append(NSAttributedString(
                string: (index == 0 ? "" : "\n") + section.title + "\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: headingStyle
                ]
            ))
            for entry in section.entries {
                result.append(NSAttributedString(
                    string: "\t\(entry.shortcut)\t\(entry.title)",
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: entryStyle]
                ))
                if let context = entry.context {
                    result.append(NSAttributedString(
                        string: "  (\(context))",
                        attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: entryStyle]
                    ))
                }
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: entryStyle]))
            }
        }
        return result
    }

    private static var panel: NSPanel?

    /// The text view the panel shows the reference in. Test affordance.
    static var textView: NSTextView? {
        (panel?.contentView as? NSScrollView)?.documentView as? NSTextView
    }

    /// Shows the reference in a utility panel, through the modal door so a test never puts it
    /// on screen. The chords are the installed menu bar's (L-97).
    static func show(menuBar: NSMenu? = ZenitShortcutSettings.installedMenuBar) {
        let panel = Self.panel ?? makePanel()
        Self.panel = panel
        textView?.textStorage?.setAttributedString(attributedText(for: sections(menuBar: menuBar)))
        _ = ZenitModalPresenter.presentPanel(panel, identifier: modalIdentifier)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = NSLocalizedString("Keyboard Shortcuts", comment: "Keyboard shortcut reference window title")
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(panel.title)
        scroll.documentView = textView
        panel.contentView = scroll
        panel.center()
        return panel
    }

    /// The Help menu's action target.
    @MainActor
    @objc final class Opener: NSObject {
        static let shared = Opener()
        @objc func showKeyboardShortcuts(_ sender: Any?) {
            KeyboardShortcutsReference.show()
        }
    }
}
