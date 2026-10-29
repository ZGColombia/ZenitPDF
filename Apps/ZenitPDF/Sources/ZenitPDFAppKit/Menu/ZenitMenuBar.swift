import AppKit
import ZPDFUIShell

/// Commands the responder chain answers directly, rather than through ``ZPDFCommandID``.
///
/// The four Edit commands and the six File commands map onto selectors AppKit already routes:
/// `undo:` reaches an `NSTextView`'s own undo stack when a field is editing and the document's
/// only when it is not, `saveDocument:` reaches `NSDocument`, and so on. Re-implementing them as
/// Zenit commands would take the text fields' behaviour away from them.
@MainActor
@objc public protocol ZenitCommandResponding: AnyObject {
    /// Runs one shell command. `sender.representedObject` carries the ``ZPDFCommandID``.
    ///
    /// `@objc` because the menu bar targets `nil` and lets the responder chain find whoever can
    /// answer, and a responder chain is dispatched by selector.
    @objc func performZenitCommand(_ sender: NSMenuItem)
}

/// Builds the application menu bar from ``ZPDFCommandTable``.
///
/// The table is the single source of titles, grouping and shortcuts, so a
/// command cannot exist in the toolbar and be missing from the menu bar. This type adds only what
/// a table of *document* commands cannot know about: the application menu, the standard Edit
/// clipboard items, the Window menu and full-screen. The application's own commands come from
/// their table too, ``ZenitAppCommandTable`` (IM-183): this type decides only where each slot of
/// that table sits among the shell's rows.
@MainActor
public enum ZenitMenuBar {

    /// The standard-selector command commands are routed through, when there is one.
    ///
    /// Returning `nil` means the command is a Zenit command and goes to
    /// ``ZenitCommandResponding/performZenitCommand(_:)``.
    static func systemSelector(for id: ZPDFCommandID) -> Selector? {
        switch id {
        case .openDocument: return #selector(NSDocumentController.openDocument(_:))
        case .save: return #selector(NSDocument.save(_:))
        case .saveAs: return #selector(NSDocument.saveAs(_:))
        case .print: return #selector(NSDocument.printDocument(_:))
        // `.closeTab` deliberately has no system selector. `NSWindow.performClose(_:)`
        // closes the *window* — every tab at once — and on a tabbed window the per-tab
        // File ▸ Close read as inert. Routing it through
        // `performZenitCommand` reaches `ProjectWindowController`'s `.closeTab`, which
        // reviews and closes exactly the active tab.
        case .undo: return Selector(("undo:"))
        case .redo: return Selector(("redo:"))
        case .selectAll: return #selector(NSResponder.selectAll(_:))
        case .deleteSelection: return #selector(NSText.delete(_:))
        default: return nil
        }
    }

    /// Whether the command's shortcut belongs in the menu bar at all.
    ///
    /// Two kinds are withheld. A command that declares `shadowsBroaderBinding` deliberately reuses
    /// a broader command's chord in a narrower context — `⌘A` is *Area* on the canvas and *Select
    /// All* everywhere else — and a menu key equivalent is context-free, so putting the narrow one
    /// in the menu bar would take the chord from the broad one everywhere. A command bound without
    /// `⌘` (Return, Escape, Tab, Delete) would swallow the key from every sheet and text field in
    /// the application. Both kinds are served by the canvas's own key handling instead.
    static func allowsMenuKeyEquivalent(_ command: ZPDFCommand) -> Bool {
        guard let binding = command.binding, !command.shadowsBroaderBinding else { return false }
        return binding.modifiers.contains(.command)
    }

    /// Builds the whole menu bar.
    ///
    /// - Parameters:
    ///   - table: the command table. Defaults to the shipping table.
    ///   - applicationName: the name shown in the application menu.
    public static func make(
        table: ZPDFCommandTable = .effective,
        applicationName: String = ZenitAppInfo.displayName
    ) -> NSMenu {
        let bar = NSMenu()
        bar.addItem(applicationMenuItem(applicationName: applicationName))
        for entry in table.menus {
            bar.addItem(menuItem(for: entry.group, commands: entry.commands))
        }
        bar.addItem(windowMenuItem())
        bar.addItem(helpMenuItem())
        return bar
    }

    /// The identifiers the three menus AppKit gives a role to carry, so ``install(_:on:)`` can
    /// find them in a built bar without the builders touching `NSApplication`.
    enum SpecialMenu: String, CaseIterable {
        case services = "zenit.menu.services"
        case windows = "zenit.menu.window"
        case help = "zenit.menu.help"

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    /// The menu of `bar` that plays `role`, found by its identifier.
    static func specialMenu(_ role: SpecialMenu, in bar: NSMenu) -> NSMenu? {
        for item in bar.items {
            guard let submenu = item.submenu else { continue }
            if item.identifier == role.identifier { return submenu }
            if let nested = specialMenu(role, in: submenu) { return nested }
        }
        return nil
    }

    /// Makes `bar` the application's menu bar and gives its Services, Window and Help menus
    /// their AppKit roles.
    ///
    /// The builders used to assign `servicesMenu`, `windowsMenu` and `helpMenu` themselves, so
    /// every bar anybody built took the roles over — including the throwaway bar Help ▸
    /// Keyboard Shortcuts built to read chords from, which left the real Window menu without
    /// its window list and Help without its search field (R-017). The roles are now given only
    /// here, to the bar that is actually installed.
    static func install(_ bar: NSMenu, on application: NSApplication = .shared) {
        application.mainMenu = bar
        if let services = specialMenu(.services, in: bar) { application.servicesMenu = services }
        if let windows = specialMenu(.windows, in: bar) { application.windowsMenu = windows }
        if let help = specialMenu(.help, in: bar) { application.helpMenu = help }
    }

    // MARK: - Application menu

    private static func applicationMenuItem(applicationName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: applicationName)

        // About opens ``ZenitAboutWindowController``, not `orderFrontStandardAboutPanel(_:)`.
        // The standard panel shows the icon, the name, the version and the copyright string and
        // offers no way to reach a licence — and this application redistributes qpdf, whose
        // Apache-2.0 §4(d) makes carrying the upstream NOTICE an obligation rather than a
        // courtesy, alongside GRDB, Clipper2 and libxlsxwriter with notices of their own. The
        // acknowledgements surface is where those texts are shown, in full and offline, and
        // `Scripts/verify-licence-notices.sh` fails the build if the bundle lacks any of them.
        let about = menu.addItem(
            withTitle: String(
                format: NSLocalizedString("About %@", comment: "Application menu item"),
                applicationName
            ),
            action: #selector(ZenitAboutWindowController.showAbout(_:)),
            keyEquivalent: ""
        )
        about.target = ZenitAboutWindowController.shared
        menu.addItem(.separator())

        // Settings ▸ General ▸ Author name.
        let settings = menu.addItem(
            withTitle: NSLocalizedString("Settings…", comment: "Application menu item"),
            action: #selector(ZenitSettingsWindowController.showSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = ZenitSettingsWindowController.shared
        menu.addItem(.separator())

        let services = NSMenu(title: NSLocalizedString("Services", comment: "Application menu"))
        let servicesItem = menu.addItem(
            withTitle: NSLocalizedString("Services", comment: "Application menu"),
            action: nil,
            keyEquivalent: ""
        )
        servicesItem.submenu = services
        servicesItem.identifier = SpecialMenu.services.identifier
        menu.addItem(.separator())

        let hide = menu.addItem(
            withTitle: String(
                format: NSLocalizedString("Hide %@", comment: "Application menu item"),
                applicationName
            ),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApplication.shared

        let hideOthers = menu.addItem(
            withTitle: NSLocalizedString("Hide Others", comment: "Application menu item"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApplication.shared

        let showAll = menu.addItem(
            withTitle: NSLocalizedString("Show All", comment: "Application menu item"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = NSApplication.shared
        menu.addItem(.separator())

        let quit = menu.addItem(
            withTitle: String(
                format: NSLocalizedString("Quit %@", comment: "Application menu item"),
                applicationName
            ),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApplication.shared

        item.submenu = menu
        return item
    }

    // MARK: - Table-driven menus

    private static func menuItem(
        for group: ZPDFCommandGroup,
        commands: [ZPDFCommand]
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: group.displayName)
        menu.autoenablesItems = true

        if group == .file {
            menu.addItem(newProjectItem())
            // r2-platform (NL-PLAT-22): New from Template… beside New, then the folder index.
            addAppCommands(in: .fileAfterNew, to: menu)
            menu.addItem(appCommandSubmenuItem(for: .fileIndexedDrawings))
        }

        for command in commands {
            // The four panes are their own section of the View menu, below the zoom commands.
            if group == .view, command.id == .toggleNavigator {
                menu.addItem(.separator())
            }
            if group == .view, command.id == .customizeToolbar {
                menu.addItem(.separator())
            }
            menu.addItem(menuItem(for: command))
            if group == .file, command.id == .openDocument {
                // No hand-built Open Recent. AppKit inserts its own populated submenu right
                // after Open… on modern macOS regardless of the `clearRecentDocuments:`
                // suppression marker our submenu carried — the File menu showed TWO "Open
                // Recent" rows live, twice, across two builds (LT-20 and its retest RT-5,
                // 2026-08-29/31). AppKit's copy is the one wired into
                // `NSDocumentController`, so ours is the one to retire.
                // NL-PDF-11: the system's "Import from iPhone or iPad" (scan a document, take
                // a photo), which AppKit fills in and delivers through the services requestor
                // (`Workflows/DeviceImport.swift`).
                menu.addItem(DeviceImport.menuItem())
                menu.addItem(.separator())
            }
            if group == .file, command.id == .saveAs {
                addAppCommands(in: .fileAfterSaveAs, to: menu)
                menu.addItem(.separator())
            }
            if group == .file, command.id == .export {
                addAppCommands(in: .fileAfterExport, to: menu)
                // L-02: the nine review-exchange rows under one (review annotations, the
                // Shared Review Folder, the review file, XFDF).
                menu.addItem(appCommandSubmenuItem(for: .fileReview))
                menu.addItem(.separator())
                // The export shapes, in the order a person reaches for them: the
                // one that looks like the print, the one somebody else can edit, and the one
                // that carries none of the takeoff.
                // Grouped under one row, so the File menu is not a long flat list (IM-250).
                menu.addItem(appCommandSubmenuItem(for: .fileExportDrawing))
                // L-03: the drawing set outputs and Combine, reachable from the menu bar as well
                // as from the Navigator's ⋯ menu.
                menu.addItem(appCommandSubmenuItem(for: .fileDrawingSet))
            }
        }

        if group == .edit {
            // Anchored on the Undo/Redo pair by what the items *are*, not by position: the
            // block used to be spliced in at hard-coded indices 2 and 3, which silently
            // landed Cut/Copy/Paste inside some other block the day the table's Edit order
            // changed (BH-896).
            let anchor = clipboardInsertionIndex(in: menu)
            menu.insertItem(.separator(), at: anchor)
            let clipboard = [
                (NSLocalizedString("Cut", comment: "Edit menu command"), #selector(NSText.cut(_:)), "x"),
                (NSLocalizedString("Copy", comment: "Edit menu command"), #selector(NSText.copy(_:)), "c"),
                (NSLocalizedString("Paste", comment: "Edit menu command"), #selector(NSText.paste(_:)), "v")
            ]
            for (offset, entry) in clipboard.enumerated() {
                let clip = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: entry.2)
                menu.insertItem(clip, at: anchor + 1 + offset)
            }
            // Directly under Copy, because that is what it is: Copy puts the *rows* on the
            // pasteboard, this puts the *picture* there (ADR-0006 §3, the ten-second path).
            for (offset, snippet) in appCommandItems(in: .editAfterCopy).enumerated() {
                menu.insertItem(snippet, at: anchor + 1 + clipboard.count + offset)
            }
            // Lock and hide through the command bus (IM-023, appcore commands returned done):
            // at the end of Edit, each one undoable and audited.
            menu.addItem(.separator())
            addAppCommands(in: .editSelection, to: menu)
            // r2-markup: group, link, image, and the Arrange and Align submenus.
            menu.addItem(.separator())
            addAppCommands(in: .editGroup, to: menu)
            menu.addItem(appCommandSubmenuItem(for: .editArrange))
            menu.addItem(appCommandSubmenuItem(for: .editAlign))
        }

        if group == .view {
            menu.addItem(.separator())
            // nl-ux: the command palette and Workspaces.
            addAppCommands(in: .viewExtras, to: menu)
            menu.addItem(ZenitWorkspaceMenu.shared.makeMenuItem())
            menu.addItem(.separator())
            // No key equivalent. ⌥⌘T is the Tool Library's in the command table, and this
            // hand-built item sat earlier in menu order, so AppKit's first-match search hid
            // the toolbar instead of opening the panel whose row prints ⌥⌘T (BH-072).
            let toolbar = NSMenuItem(
                title: NSLocalizedString("Hide Toolbar", comment: "View menu command"),
                action: #selector(NSWindow.toggleToolbarShown(_:)),
                keyEquivalent: ""
            )
            menu.addItem(toolbar)
            let fullScreen = NSMenuItem(
                title: NSLocalizedString("Enter Full Screen", comment: "View menu command"),
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f"
            )
            fullScreen.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(fullScreen)
        }

        if group == .tools {
            menu.addItem(.separator())
            addAppCommands(in: .toolsCapture, to: menu)
            // L-02: mark, apply and clear under one row.
            menu.addItem(appCommandSubmenuItem(for: .toolsRedaction))
            menu.addItem(.separator())
            addAppCommands(in: .toolsDrawingData, to: menu)
            // Feature 18 — the whole rig as a named template, and back: the four template
            // commands under one row (IM-250).
            menu.addItem(appCommandSubmenuItem(for: .toolsJobTemplates))
            // r2-platform (NL-PLAT-23): packs of tool sets, templates and profiles.
            addAppCommands(in: .toolsLibrary, to: menu)
        }

        if group == .measure {
            menu.addItem(.separator())
            addAppCommands(in: .measure, to: menu)
            // L-02: the checks, the detectors and the Takeoff Assistant under one row.
            menu.addItem(appCommandSubmenuItem(for: .measureAutomation))
        }

        item.submenu = menu
        return item
    }

    /// Where the Edit menu's clipboard block goes: straight after Redo (or Undo), else at
    /// the top. Internal for tests.
    static func clipboardInsertionIndex(in menu: NSMenu) -> Int {
        let redo = systemSelector(for: .redo)
        let undo = systemSelector(for: .undo)
        if let redo, let index = menu.items.lastIndex(where: { $0.action == redo }) { return index + 1 }
        if let undo, let index = menu.items.lastIndex(where: { $0.action == undo }) { return index + 1 }
        if let index = menu.items.lastIndex(where: {
            ($0.representedObject as? String) == ZPDFCommandID.redo.rawValue
        }) { return index + 1 }
        return 0
    }

    private static func menuItem(for command: ZPDFCommand) -> NSMenuItem {
        // A row that knows its command, so a shortcut change finds it in the installed bar and
        // edits its key equivalent in place rather than rebuilding the bar (L-44).
        let item = ZenitCommandMenuItem(commandID: command.id, title: command.title)
        if let selector = systemSelector(for: command.id) {
            item.action = selector
        } else {
            item.action = #selector(ZenitCommandResponding.performZenitCommand(_:))
            item.representedObject = command.id.rawValue
        }
        if let chord = menuChord(for: command) {
            item.keyEquivalent = chord.key
            item.keyEquivalentModifierMask = chord.modifiers
        }
        if let hint = command.accessibilityHint {
            item.toolTip = hint
        }
        return item
    }

    // MARK: - Shortcut changes, in place (L-44)

    /// The key equivalent a command's row carries in the menu bar, or `nil` when its chord is
    /// served elsewhere (``allowsMenuKeyEquivalent(_:)``).
    static func menuChord(for command: ZPDFCommand) -> ZenitMenuChord? {
        guard allowsMenuKeyEquivalent(command), let binding = command.binding else { return nil }
        return ZenitMenuChord(key: binding.key, modifiers: binding.modifiers.eventModifierFlags)
    }

    /// Every row of `menu`, at any depth, that was built from the shell's command table.
    static func commandItems(in menu: NSMenu) -> [ZenitCommandMenuItem] {
        menu.items.flatMap { item -> [ZenitCommandMenuItem] in
            var found: [ZenitCommandMenuItem] = []
            if let row = item as? ZenitCommandMenuItem { found.append(row) }
            if let submenu = item.submenu { found += commandItems(in: submenu) }
            return found
        }
    }

    /// Gives the rows of an installed bar the key equivalents of `table`, editing only the rows
    /// whose chord differs from `previous` — the table the bar was showing.
    ///
    /// A shortcut change used to rebuild the menu bar from scratch and install the new one. The
    /// File menu of a document application is not only ours: at launch AppKit inserts Open
    /// Recent, Duplicate, Rename…, Move To…, Share and Revert To, and gives Save As the ⌥⇧⌘S it
    /// shows beside Duplicate's ⇧⌘S. None of that is reinserted when a bar is replaced, so after
    /// one rebound-and-restored shortcut all five rows were gone and ⇧⌘S did nothing
    /// (L-44). Editing the rows in place leaves every row AppKit made where it is.
    ///
    /// A row remembers the key equivalent it had before its first edit, together with the
    /// table chord that stood behind it, so choosing that chord again — Restore Default —
    /// gives back exactly that row, including what AppKit made of it at launch, rather than
    /// the table's spelling of it (which for Save As would collide with Duplicate's ⇧⌘S).
    static func applyKeyEquivalents(
        of table: ZPDFCommandTable,
        replacing previous: ZPDFCommandTable,
        in bar: NSMenu
    ) {
        for item in commandItems(in: bar) {
            guard let id = item.commandID, let command = table.command(id) else { continue }
            let wanted = menuChord(for: command)
            let shown = previous.command(id).flatMap(menuChord(for:))
            guard wanted != shown else { continue }
            if let original = item.originalKeyEquivalent, original.tableChord == wanted {
                item.keyEquivalent = original.key
                item.keyEquivalentModifierMask = original.modifiers
                item.isAlternate = original.isAlternate
                item.originalKeyEquivalent = nil
                continue
            }
            if item.originalKeyEquivalent == nil {
                item.originalKeyEquivalent = ZenitCommandMenuItem.OriginalKeyEquivalent(
                    key: item.keyEquivalent,
                    modifiers: item.keyEquivalentModifierMask,
                    isAlternate: item.isAlternate,
                    tableChord: shown
                )
            }
            item.keyEquivalent = wanted?.key ?? ""
            item.keyEquivalentModifierMask = wanted?.modifiers ?? []
            // An alternate shares its primary's key; a rebound chord no longer does, so the row
            // stands on its own rather than hiding behind a primary it no longer matches.
            item.isAlternate = false
        }
    }

    // MARK: - Items with no table entry

    /// File ▸ New Project… (⌘N): the drawing first, then the project made from it. It used to be
    /// AppKit's `newDocument(_:)`, an empty untitled project nothing could be saved from or added
    /// to (L-40); ``NewProjectFromDrawing`` records why New starts from a drawing instead.
    private static func newProjectItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: NSLocalizedString("New Project…", comment: "File menu command: choose a drawing and make a project from it"),
            action: #selector(ZenitDocumentController.newProjectFromDrawing(_:)),
            keyEquivalent: "n"
        )
        item.toolTip = NSLocalizedString(
            "Choose a drawing, then where to keep the project made from it.",
            comment: "Tooltip of File ▸ New Project…"
        )
        return item
    }

    // MARK: - Rows from the application command table (IM-183)

    /// Appends the rows of one table slot to `menu`.
    private static func addAppCommands(in slot: ZenitAppCommandSlot, to menu: NSMenu) {
        for item in appCommandItems(in: slot) { menu.addItem(item) }
    }

    /// The rows of one table slot: every command's visible row in table order, then the hidden
    /// twins that carry a command's further chords, in the same order.
    static func appCommandItems(in slot: ZenitAppCommandSlot) -> [NSMenuItem] {
        let specs = ZenitAppCommandTable.specs(in: slot)
        let visible = specs.map { menuItem(for: $0, keyEquivalent: $0.keyEquivalent) }
        let hidden = specs.flatMap { spec in
            spec.hiddenKeyEquivalents.map { chord -> NSMenuItem in
                let item = menuItem(for: spec, keyEquivalent: chord)
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
                return item
            }
        }
        return visible + hidden
    }

    /// A row that opens the submenu of one table slot, titled by the slot.
    private static func appCommandSubmenuItem(for slot: ZenitAppCommandSlot) -> NSMenuItem {
        let title = slot.submenuTitle ?? ""
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for entry in appCommandItems(in: slot) { submenu.addItem(entry) }
        item.submenu = submenu
        return item
    }

    /// One application command's row. The command travels in `representedObject` to
    /// ``ZenitCommandResponding/performZenitCommand(_:)``, the idiom every `ZenitAppCommand` row
    /// uses, and the responder that answers looks it up in the same table.
    private static func menuItem(for spec: ZenitAppCommandSpec, keyEquivalent: ZenitKeyEquivalent?) -> NSMenuItem {
        let item = NSMenuItem(
            title: spec.title,
            action: #selector(ZenitCommandResponding.performZenitCommand(_:)),
            keyEquivalent: ""
        )
        item.representedObject = spec.command.rawValue
        if let keyEquivalent {
            item.keyEquivalent = keyEquivalent.key
            item.keyEquivalentModifierMask = keyEquivalent.modifiers
        }
        if let toolTip = spec.toolTip {
            item.toolTip = toolTip
        }
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: NSLocalizedString("Window", comment: "Menu bar title"))
        menu.addItem(
            withTitle: NSLocalizedString("Minimize", comment: "Window menu command"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: NSLocalizedString("Zoom", comment: "Window menu command"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let front = menu.addItem(
            withTitle: NSLocalizedString("Bring All to Front", comment: "Window menu command"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        front.target = NSApplication.shared
        // Documents are tabs inside one window, which AppKit's own list cannot see: a way to
        // move between them from the keyboard and the menu (IM-182).
        menu.addItem(.separator())
        addAppCommands(in: .windowTabs, to: menu)
        menu.delegate = WindowMenuTabLister.shared
        item.submenu = menu
        item.identifier = SpecialMenu.windows.identifier
        return item
    }

    /// The Help menu.
    ///
    /// It exists for one reason: **Licences must be reachable by name.** Until 2026-08-26 the
    /// only route to the notices was the About item, which is a place people look for a version
    /// number, not for the terms they are using software under. Licences need a tab a person
    /// can go to; a tab nobody can find from the menu bar is not one.
    ///
    /// `NSApplication.helpMenu` is set (by ``install(_:on:)``) so that AppKit treats this as the
    /// help menu proper — it gets the search field, and macOS stops synthesising its own.
    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: NSLocalizedString("Help", comment: "Menu bar title"))

        let licences = menu.addItem(
            withTitle: NSLocalizedString(
                "Licences", comment: "Help menu item opening the licence notices"
            ),
            action: #selector(ZenitAboutWindowController.showLicences(_:)),
            keyEquivalent: ""
        )
        licences.target = ZenitAboutWindowController.shared

        // Generated from the command table, so it cannot drift from the keys (IM-251).
        let shortcuts = menu.addItem(
            withTitle: NSLocalizedString("Keyboard Shortcuts", comment: "Help menu item opening the shortcut reference"),
            action: #selector(KeyboardShortcutsReference.Opener.showKeyboardShortcuts(_:)),
            keyEquivalent: ""
        )
        shortcuts.target = KeyboardShortcutsReference.Opener.shared

        // NL-UX-11: the shortcuts can be changed, not only read.
        let customise = menu.addItem(
            withTitle: NSLocalizedString("Customize Keyboard Shortcuts…", comment: "Help menu item opening the shortcut settings"),
            action: #selector(ZenitShortcutSettingsWindowController.showShortcutSettings(_:)),
            keyEquivalent: ""
        )
        customise.target = ZenitShortcutSettingsWindowController.shared

        // NL-UX-13: the four-step welcome, on demand.
        menu.addItem(.separator())
        let welcome = menu.addItem(
            withTitle: NSLocalizedString("Welcome to Zenit PDF", comment: "Help menu item opening the onboarding path"),
            action: #selector(ZenitOnboardingController.showWelcome(_:)),
            keyEquivalent: ""
        )
        welcome.target = ZenitOnboardingController.shared

        item.submenu = menu
        item.identifier = SpecialMenu.help.identifier
        return item
    }
}

/// Commands the application owns that are not window-shell commands.
///
/// ``ZPDFCommandID`` is the shell's vocabulary and is frozen by `ZPDFUIShell`. These are
/// application-level. Each one's title, shortcut, enablement and action live in one entry of
/// ``ZenitAppCommandTable`` (IM-183); declaration order is the order of the rows within a menu
/// block.
public enum ZenitAppCommand: String, Sendable, CaseIterable {
    case createProject = "zenit.app.createProject"
    case calibrateScale = "zenit.app.calibrateScale"
    /// Applies the page on screen's scale to other pages in one step (NL-MEASURE-02).
    case applyScaleToPages = "zenit.app.applyScaleToPages"
    /// Every sheet's scale status, with the proposals read from each sheet (NL-MEASURE-02).
    case pageScales = "zenit.app.pageScales"
    /// Proposes Scale Regions for the parts of the sheet drawn at another scale (NL-AUTO-19).
    case findScaleRegions = "zenit.app.findScaleRegions"
    /// Compares a second stated dimension with the page's scale (NL-MEASURE-04).
    case verifyScale = "zenit.app.verifyScale"
    /// Divides the selected area along a drawn line (NL-MEASURE-06).
    case splitArea = "zenit.app.splitArea"
    /// Adds points to the selected polylength or count (NL-MEASURE-06, NL-MEASURE-12).
    case continueMeasurement = "zenit.app.continueMeasurement"
    /// Unions the selected same-subject areas into one (NL-MEASURE-06).
    case mergeAreas = "zenit.app.mergeAreas"
    /// Shows or hides the running numbers of the selected counts' marks (NL-MEASURE-12).
    case numberCountMarks = "zenit.app.numberCountMarks"
    /// Turns the precision magnifier on or off while placing points (NL-MEASURE-15).
    case precisionMagnifier = "zenit.app.precisionMagnifier"
    /// Brings every value kept under an older scale version current (NL-MEASURE-03).
    case recalculateStale = "zenit.app.recalculateStale"
    /// Two clicks draw a fence line that auto-trace treats as a wall (NL-MEASURE-11).
    case drawFenceLine = "zenit.app.drawFenceLine"
    /// Removes the fence lines on the page on screen (NL-MEASURE-11).
    case clearFenceLines = "zenit.app.clearFenceLines"
    /// Bends one edge of the selected polylength or area into an arc (NL-MEASURE-05).
    case curveEdge = "zenit.app.curveEdge"
    /// Opens the recognition sheet. Not a `ZPDFCommandID` because the shell's command table is
    /// frozen by `ZPDFUIShell` and this is the application's own door onto `ZPDFSearch`.
    case readScannedText = "zenit.app.readScannedText"
    /// Reads a `.zpdfjson` ledger export back, reviews it and reconciles it against the ledger
    /// on screen. Application-level for the same reason as the three above: the shell's command
    /// table is frozen by `ZPDFUIShell`, and this is the application's own door onto
    /// `ZPDFExport`'s reader.
    case importLedgerJSON = "zenit.app.importLedgerJSON"
    /// The measurements of this drawing as a `.zpdfoverlay`, for another copy of the same
    /// drawing (the exporter had no caller before this).
    case exportMeasurementOverlay = "zenit.app.exportMeasurementOverlay"
    /// Redraw a `.zpdfoverlay` made on this same drawing, refused otherwise.
    case importMeasurementOverlay = "zenit.app.importMeasurementOverlay"
    /// NL-PLAT-07: read an exported workbook back after it was edited in a spreadsheet, review
    /// the changed cells, apply the accepted ones as one undo. Measured quantities are refused.
    case importSpreadsheetChanges = "zenit.app.importSpreadsheetChanges"
    /// NL-PLAT-10: the project as one `.zip` for a colleague, without this Mac's recovery files.
    case sendProject = "zenit.app.sendProject"
    /// NL-PLAT-10 (r2-platform): the file the last export wrote, through the system share picker.
    case shareLastExport = "zenit.app.shareLastExport"
    /// NL-PLAT-22 (r2-platform): a job template, then the drawing — the takeoff starts set up.
    case newFromTemplate = "zenit.app.newFromTemplate"
    /// NL-DOCS-15: the text of every PDF in a chosen folder, searchable without opening them.
    case indexDrawingFolder = "zenit.app.indexDrawingFolder"
    case searchDrawingFolder = "zenit.app.searchDrawingFolder"
    case forgetDrawingFolder = "zenit.app.forgetDrawingFolder"
    /// NL-PLAT-23 (r2-platform): install a pack of tool sets, templates and profiles; make one.
    case installPack = "zenit.app.installPack"
    case createPack = "zenit.app.createPack"
    /// NL-PLAT-08: the ledger's columns as a `.zpdfprofile` an office adjusts once and shares.
    case saveExportProfile = "zenit.app.saveExportProfile"
    /// NL-PLAT-08: the ledger through a chosen profile, byte for byte what a receiving system expects.
    case exportWithProfile = "zenit.app.exportWithProfile"
    /// NL-COLLAB-08: a reviewer's marked-up copy of the drawing becomes markups, replies and
    /// status changes, previewed first. Application-level: the shell's command table is frozen.
    case importReviewAnnotations = "zenit.app.importReviewAnnotations"
    /// NL-COLLAB-12: connect this project to a Shared Review Folder, sync it, or disconnect.
    case connectSharedReview = "zenit.app.connectSharedReview"
    case syncSharedReview = "zenit.app.syncSharedReview"
    case disconnectSharedReview = "zenit.app.disconnectSharedReview"
    /// NL-COLLAB-10: the whole review as a `.zpdfreview`, and its merge back.
    case exportReviewFile = "zenit.app.exportReviewFile"
    case importReviewFile = "zenit.app.importReviewFile"
    /// The review file through the system's sharing picker.
    case shareReviewFile = "zenit.app.shareReviewFile"
    /// NL-COLLAB-09: the review as XFDF, and an XFDF read back.
    case exportXFDF = "zenit.app.exportXFDF"
    case importXFDF = "zenit.app.importXFDF"
    /// NL-COLLAB-04: every markup in one filterable list, beside the drawing.
    case reviewList = "zenit.app.reviewList"
    /// NL-COLLAB-06: draw every markup in its author's colour, display only.
    case tintByAuthor = "zenit.app.tintByAuthor"
    /// Opens the scoped batch apply sheet. Application-level for the same
    /// reason as the three above: `ZPDFUIShell`'s command table is frozen.
    case batchApply = "zenit.app.batchApply"
    /// ADR-0006's ten-second path: the selected markups as a captioned picture, on the
    /// pasteboard. Application-level for the same reason as the four above.
    case copySnippet = "zenit.app.copySnippet"
    /// The same picture, saved to a file — PNG or the vector PDF variant.
    case exportSnippet = "zenit.app.exportSnippet"
    /// NL-PDF-21: the same picture on a shelf, dragged out as a file or shared.
    case shareSnippet = "zenit.app.shareSnippet"
    /// NL-PDF-18: Word, OpenDocument, rich-text, web and plain-text documents into one PDF.
    case createPDFFromDocuments = "zenit.app.createPDFFromDocuments"
    /// NL-PDF-18: puts Zenit PDF in the print dialog's PDF menu.
    case setUpPrintToZenit = "zenit.app.setUpPrintToZenit"
    /// Arms the canvas to drag the rectangle a snippet is taken of.
    case snippetRegion = "zenit.app.snippetRegion"
    /// The flattened export shape: the drawing with the markups burned into the page
    /// content, which is what the printer puts on paper. Application-level for the same reason
    /// as the six above: `ZPDFUIShell`'s command table is frozen.
    case exportFlattenedPDF = "zenit.app.exportFlattenedPDF"
    /// The editable shape: the markups as standard PDF annotations, still selectable in another
    /// reader.
    case exportAnnotatedPDF = "zenit.app.exportAnnotatedPDF"
    /// The clean shape: the drawing with no Zenit markup on it at all.
    case exportCleanPDF = "zenit.app.exportCleanPDF"
    /// Feature 35: the drawing byte-for-byte, plus the markups as a real optional-content
    /// layer another reader can switch off. Application-level like the exports above.
    case exportLayeredPDF = "zenit.app.exportLayeredPDF"
    /// NL-PDF-08/09: a smaller, cleaned or password-protected copy of the drawing, written by
    /// qpdf inside the repair service. Application-level like the exports above.
    case optimizeCopy = "zenit.app.optimizeCopy"
    /// NL-PDF-13: the recognised words written into a copy as an invisible text layer.
    case saveSearchableCopy = "zenit.app.saveSearchableCopy"
    /// NL-PDF-03 (ADR-0023): the markups and the takeoff appended to the PDF itself, after a
    /// confirmation. Application-level like the exports above.
    case saveMarkupsIntoPDF = "zenit.app.saveMarkupsIntoPDF"
    /// NL-PDF-20: a header, footer or sheet number on every sheet in scope, as one action.
    case batchHeaderFooter = "zenit.app.batchHeaderFooter"
    /// NL-PDF-22: a photographed signature traced into a stamp tool — an image, never a digital signature.
    case newSignatureStamp = "zenit.app.newSignatureStamp"
    /// NL-PDF-12: straighten, rectify, trim, turn and enhance scanned sheets into a new PDF.
    case cleanUpScans = "zenit.app.cleanUpScans"
    /// NL-PDF-14: box an area to remove; apply the boxes to a new, checked copy; forget them.
    case markRedaction = "zenit.app.markRedaction"
    case applyRedactions = "zenit.app.applyRedactions"
    case clearRedactionMarks = "zenit.app.clearRedactionMarks"
    /// NL-PDF-19: the same steps over a folder of PDFs, and its stop.
    case processPDFFiles = "zenit.app.processPDFFiles"
    case stopProcessingPDFFiles = "zenit.app.stopProcessingPDFFiles"
    /// NL-PDF-16: a copy of the drawing signed with a certificate from the person's keychain.
    case signDrawingCopy = "zenit.app.signDrawingCopy"
    /// Feature 18: capture the whole rig — presets, subjects, colours, columns, units —
    /// as a named Job Template.
    case saveJobTemplate = "zenit.app.saveJobTemplate"
    /// Feature 18: apply a stored Job Template to this project. Never its scale — a
    /// template structurally cannot carry one.
    case applyJobTemplate = "zenit.app.applyJobTemplate"
    /// Feature 18: one template as a `.zpdftemplate` file, for the next machine.
    case exportJobTemplate = "zenit.app.exportJobTemplate"
    /// Feature 18: read a `.zpdftemplate` back, digest-checked before it is believed.
    case importJobTemplate = "zenit.app.importJobTemplate"
    /// Feature 13, opt-in: check the page's measurements against the dimensions printed
    /// beside them. Runs only when chosen; silence on everything uncertain.
    case checkDrawnDimensions = "zenit.app.checkDrawnDimensions"
    /// Feature 31: a schedule printed on the sheet becomes read ledger rows (ADR-0012),
    /// through the review panel — never silently.
    case importTableFromDrawing = "zenit.app.importTableFromDrawing"
    /// Feature 12: box one symbol, name it, count every match on the page — with the
    /// skipped and unclassified spoken out loud, never a partial list presented as whole.
    case createSymbolSchedule = "zenit.app.createSymbolSchedule"
    /// NL-AUTO-11: what auto-trace should leave out — dashed lines, fills and hatch, thin
    /// strokes — stated in the status bar whenever it is in force (nl-automation).
    case autoTraceOptions = "zenit.app.autoTraceOptions"
    /// NL-AUTO-17: search the current page for every symbol saved in the local library.
    case findLibrarySymbols = "zenit.app.findLibrarySymbols"
    /// NL-AUTO-24: search the page's geometry — circles, lines of a length, parallel pairs.
    case findGeometry = "zenit.app.findGeometry"
    /// NL-AUTO-08: every room on the page, proposed with names, reviewed, landed in one undo.
    case detectRooms = "zenit.app.detectRooms"
    /// NL-AUTO-20 (r2-platform): wall classes and their centrelines, proposed, added on a tick.
    case findWalls = "zenit.app.findWalls"
    /// NL-AUTO-21 (r2-platform): sheets that are the same drawing — measure once, apply ×N.
    case findRepeatedSheets = "zenit.app.findRepeatedSheets"
    /// NL-AUTO-16 (r2-platform): the Takeoff Assistant — prepare the set; review its inbox.
    case prepareSet = "zenit.app.prepareSet"
    case assistantInbox = "zenit.app.assistantInbox"
    /// NL-AUTO-04: name every sheet from its title block — box the number (and title) once,
    /// review, one undo (nl-automation recognition, nl-documents data model).
    case nameSheetsFromTitleBlock = "zenit.app.nameSheetsFromTitleBlock"
    /// L-03 (NL-DOCS-08/10/13/04): the drawing set outputs and Combine in the menu bar too, run
    /// through the same shell hooks the Navigator's ⋯ menu runs (R-071), in the same order.
    case exportArrangedSet = "zenit.app.exportArrangedSet"
    case linkSheetReferences = "zenit.app.linkSheetReferences"
    /// L-57/L-93: the revised PDF chosen in a file panel and added as a revision — before this a
    /// revision could only arrive by an ⌥ drop from Finder.
    case addRevision = "zenit.app.addRevision"
    case setCompareReport = "zenit.app.setCompareReport"
    case splitIntoSheets = "zenit.app.splitIntoSheets"
    case combineOpenDrawings = "zenit.app.combineOpenDrawings"
    /// Locks the selected markups, or unlocks them when every one is locked (IM-023).
    case toggleLockSelection = "zenit.app.toggleLockSelection"
    /// Hides the selected markups (IM-023).
    case hideSelection = "zenit.app.hideSelection"
    /// Shows every hidden markup of the takeoff (IM-023).
    case showHiddenMarkups = "zenit.app.showHiddenMarkups"
    /// NL-UX-20: a second window on the document in front — its own page, zoom, selection and
    /// armed tool over the same takeoff, undo stack and save.
    case newWindowForProject = "zenit.app.newWindowForProject"
    /// Fronts the next document tab, wrapping (IM-182).
    case showNextTab = "zenit.app.showNextTab"
    /// Fronts the previous document tab, wrapping (IM-182).
    case showPreviousTab = "zenit.app.showPreviousTab"
    /// NL-UX-05: find and run any command, tool, preset, page or subject by typing. ⇧⌘P —
    /// ⌘K is Count. Application-level because `ZPDFUIShell`'s command table is frozen.
    case commandPalette = "zenit.app.commandPalette"
    /// NL-UX-04: the drawing's own annotations become Zenit markups — reviewed first, one undo
    /// step, originals hidden rather than deleted.
    case makeDrawingAnnotationsEditable = "zenit.app.makeDrawingAnnotationsEditable"
    /// NL-PDF-17: the drawing's own form fields, filled into a new file.
    case fillFormFields = "zenit.app.fillFormFields"
    /// NL-UX-07: every markup on the page sharing the selection's subject.
    case selectSameSubject = "zenit.app.selectSameSubject"
    /// NL-UX-07: every markup on the page of the selection's kind (every Area, every cloud).
    case selectSameKind = "zenit.app.selectSameKind"
    /// NL-UX-07: every visible markup on every page (⌥⌘A).
    case selectAllInDocument = "zenit.app.selectAllInDocument"
    /// NL-UX-08: take the look of the selected markup (⌥⌘C).
    case copyStyle = "zenit.app.copyStyle"
    /// NL-UX-08: give the copied look to the selection, one undo step (⌥⌘V).
    case pasteStyle = "zenit.app.pasteStyle"
    /// NL-MARKUP-05 (nl-markup): the copied markups at their own page position (⌥⇧⌘V).
    case pasteInPlace = "zenit.app.pasteInPlace"
    /// NL-MARKUP-05 (nl-markup): the selected markups again, 10 pt down and right (⌘D).
    case duplicateMarkups = "zenit.app.duplicateMarkups"
    /// NL-UX-03 (nl-markup): the copied markups in place on every page selected in the
    /// Navigator, one undo step.
    case pasteToPages = "zenit.app.pasteToPages"
    // r2-markup (ADR-0029): group, link and image (Edit), arrange and align (Edit submenus).
    case groupMarkups = "zenit.app.groupMarkups"
    case ungroupMarkups = "zenit.app.ungroupMarkups"
    case editMarkupLink = "zenit.app.editMarkupLink"
    case insertImage = "zenit.app.insertImage"
    case bringToFront = "zenit.app.bringToFront"
    case bringForward = "zenit.app.bringForward"
    case sendBackward = "zenit.app.sendBackward"
    case sendToBack = "zenit.app.sendToBack"
    case alignLeft = "zenit.app.alignLeft"
    case alignCentres = "zenit.app.alignCentres"
    case alignRight = "zenit.app.alignRight"
    case alignTop = "zenit.app.alignTop"
    case alignMiddles = "zenit.app.alignMiddles"
    case alignBottom = "zenit.app.alignBottom"
    case distributeHorizontally = "zenit.app.distributeHorizontally"
    case distributeVertically = "zenit.app.distributeVertically"
    case makeSameWidth = "zenit.app.makeSameWidth"
    case makeSameHeight = "zenit.app.makeSameHeight"
}

/// Lists the front window's document tabs at the foot of the Window menu, rebuilt each time the
/// menu opens: a checkmark on the tab in front and "Edited" on unsaved ones (IM-182).
@MainActor
final class WindowMenuTabLister: NSObject, NSMenuDelegate {
    static let shared = WindowMenuTabLister()
    static let itemTag = 0x7AB5

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.itemTag { menu.removeItem(item) }
        let controller = NSApplication.shared.keyWindow?.windowController as? ProjectWindowController
            ?? NSApplication.shared.mainWindow?.windowController as? ProjectWindowController
        guard let controller else { return }
        Self.appendTabItems(for: controller, to: menu)
    }

    /// The tab rows for one window. Separate so a test can build them without a key window.
    static func appendTabItems(for controller: ProjectWindowController, to menu: NSMenu) {
        guard controller.documents.count > 1 else { return }
        let separator = NSMenuItem.separator()
        separator.tag = itemTag
        menu.addItem(separator)
        for document in controller.documents {
            let name = document.displayName ?? ""
            let title = document.isDocumentEdited
                ? String(format: NSLocalizedString("%@ — Edited", comment: "Window menu tab row for an edited document"), name)
                : name
            let item = NSMenuItem(title: title, action: #selector(ProjectWindowController.activateTabFromMenu(_:)), keyEquivalent: "")
            item.target = controller
            item.representedObject = document.documentIdentity
            item.state = document === controller.activeDocument ? .on : .off
            item.tag = itemTag
            menu.addItem(item)
        }
    }
}

/// A key equivalent as the menu bar spells it.
struct ZenitMenuChord: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The chord a menu row answers to, read the way AppKit reads it: an upper-case letter as
    /// the key equivalent carries an implied Shift. AppKit's own Duplicate row is "S" with ⌘
    /// alone in its mask, and is drawn and matched as ⇧⌘S; read literally it printed as "⌘S",
    /// the same text as Save (L-97).
    init(menuItem item: NSMenuItem) {
        var key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        let lower = key.lowercased()
        if lower != key, key.uppercased() == key {
            key = lower
            modifiers.insert(.shift)
        }
        self.init(key: key, modifiers: modifiers)
    }

    static func == (lhs: ZenitMenuChord, rhs: ZenitMenuChord) -> Bool {
        lhs.key == rhs.key
            && lhs.modifiers.intersection(.deviceIndependentFlagsMask) == rhs.modifiers.intersection(.deviceIndependentFlagsMask)
    }
}

/// A menu row built from the shell's command table (L-44). It carries the command, so the
/// installed bar can be found and edited in place when a shortcut changes, and the key
/// equivalent it had before the first such edit.
final class ZenitCommandMenuItem: NSMenuItem {

    /// What a row looked like before its key equivalent was first edited, and the table chord
    /// that was in force then.
    struct OriginalKeyEquivalent {
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let isAlternate: Bool
        let tableChord: ZenitMenuChord?
    }

    /// The command the row runs. `nil` only on a row AppKit made through the inherited
    /// initialiser — which a copy does first, and ``copy(with:)`` then fills in.
    private(set) var commandID: ZPDFCommandID?
    var originalKeyEquivalent: OriginalKeyEquivalent?

    init(commandID: ZPDFCommandID, title: String) {
        self.commandID = commandID
        super.init(title: title, action: nil, keyEquivalent: "")
    }

    /// AppKit copies a menu item through this initialiser (`-copyWithZone:` calls
    /// `-initWithTitle:action:keyEquivalent:` on the item's own class), and a Swift subclass
    /// that does not override it traps on the first copy.
    override init(title string: String, action selector: Selector?, keyEquivalent charCode: String) {
        super.init(title: string, action: selector, keyEquivalent: charCode)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let row = copy as? ZenitCommandMenuItem {
            row.commandID = commandID
            row.originalKeyEquivalent = originalKeyEquivalent
        }
        return copy
    }
}
