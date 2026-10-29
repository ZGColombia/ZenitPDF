import AppKit
import Testing
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The menu bar is generated, so what has to be tested is the generation rule, not the menu.
@MainActor
@Suite(.appTierSerialised)
struct MenuBarTests {

    @Test("Every command in the table reaches the menu bar exactly once")
    func everyCommandIsInstalled() {
        let table = ZPDFCommandTable.standard
        let bar = ZenitMenuBar.make(table: table)
        var found: [ZPDFCommandID] = []
        var systemRouted: [ZPDFCommandID] = []

        for item in bar.items {
            guard let submenu = item.submenu else { continue }
            for entry in submenu.items {
                if let raw = entry.representedObject as? String, let id = ZPDFCommandID(rawValue: raw) {
                    found.append(id)
                }
            }
        }
        for command in table.commands where ZenitMenuBar.systemSelector(for: command.id) != nil {
            systemRouted.append(command.id)
        }

        let expected = Set(table.commands.map(\.id)).subtracting(systemRouted)
        #expect(Set(found) == expected)
        #expect(found.count == Set(found).count, "a command must not appear in two menus")
    }

    @Test("Standard AppKit selectors carry the File and Edit commands")
    func systemSelectorsCoverDocumentCommands() {
        let expected: [ZPDFCommandID] = [
            .openDocument, .save, .saveAs, .print, .undo, .redo, .selectAll, .deleteSelection
        ]
        for id in expected {
            #expect(ZenitMenuBar.systemSelector(for: id) != nil, "\(id) must route through AppKit")
        }
        #expect(ZenitMenuBar.systemSelector(for: .measureArea) == nil)
        #expect(ZenitMenuBar.systemSelector(for: .toggleInspector) == nil)
    }

    @Test("File ▸ Close routes to the window's per-tab close, not to performClose")
    func closeTabRoutesToTheWindow() {
        // `NSWindow.performClose(_:)` closes the whole window, and on a
        // tabbed window the per-tab File ▸ Close read as inert. The command must travel
        // through `performZenitCommand` so `ProjectWindowController` closes the active tab.
        #expect(ZenitMenuBar.systemSelector(for: .closeTab) == nil)
    }

    @Test("The File menu builds NO Open Recent of its own — AppKit's injected one is the only one")
    func openRecentIsLeftToAppKit() throws {
        // LT-20, RT-5: our hand-built submenu carried the
        // `clearRecentDocuments:` suppression marker and AppKit inserted its own populated
        // Open Recent anyway — two identical rows, live, in two consecutive builds. The
        // hand-built one is retired; AppKit's (which NSDocumentController populates) is
        // the single Open Recent, and it only exists at runtime, so the BUILT menu must
        // contain none at all.
        let bar = ZenitMenuBar.make()
        let fileMenu = try #require(bar.items.first { $0.submenu?.title == "File" }?.submenu)
        let openRecentItems = fileMenu.items.filter { $0.title == "Open Recent" }
        #expect(openRecentItems.isEmpty,
                "a hand-built Open Recent will sit beside AppKit's injected one — the RT-5 duplicate")
    }

    @Test("A shadowing or modifier-free shortcut never becomes a menu key equivalent")
    func shortcutPolicy() {
        let table = ZPDFCommandTable.standard
        for command in table.commands {
            guard let binding = command.binding else { continue }
            let allowed = ZenitMenuBar.allowsMenuKeyEquivalent(command)
            if command.shadowsBroaderBinding {
                #expect(!allowed, "\(command.id) shadows a broader chord and must stay off the menu bar")
            }
            if !binding.modifiers.contains(.command) {
                #expect(!allowed, "\(command.id) has no Command modifier and would swallow the key")
            }
        }
        // The two the rule exists for.
        let area = table.command(.measureArea)
        let selectAll = table.command(.selectAll)
        #expect(area.map { ZenitMenuBar.allowsMenuKeyEquivalent($0) } == false)
        #expect(selectAll.map { ZenitMenuBar.allowsMenuKeyEquivalent($0) } == true)
    }

    @Test("Installed key equivalents match the command table")
    func keyEquivalentsMatchTable() {
        let table = ZPDFCommandTable.standard
        let bar = ZenitMenuBar.make(table: table)
        for item in bar.items {
            guard let submenu = item.submenu else { continue }
            for entry in submenu.items {
                guard let raw = entry.representedObject as? String,
                      let id = ZPDFCommandID(rawValue: raw),
                      let command = table.command(id) else { continue }
                if ZenitMenuBar.allowsMenuKeyEquivalent(command), let binding = command.binding {
                    #expect(entry.keyEquivalent == binding.key)
                    #expect(entry.keyEquivalentModifierMask == binding.modifiers.eventModifierFlags)
                } else {
                    #expect(entry.keyEquivalent.isEmpty)
                }
            }
        }
    }

    @Test("The menu bar carries the application, Window, Help and per-group menus")
    func menuStructure() {
        let bar = ZenitMenuBar.make()
        let titles = bar.items.compactMap { $0.submenu?.title }
        for group in ZPDFCommandGroup.allCases {
            #expect(titles.contains(group.displayName), "missing \(group.displayName) menu")
        }
        #expect(titles.first == ZenitAppInfo.displayName)
        // macOS order: Window then Help, and Help last. AppKit places its own search field in
        // whatever menu is `NSApplication.helpMenu`, and a Help menu that is not last reads as
        // a mistake to anyone who uses a Mac.
        #expect(titles.suffix(2) == [
            NSLocalizedString("Window", comment: "Menu bar title"),
            NSLocalizedString("Help", comment: "Menu bar title")
        ])
    }

    @Test("Every closable surface has a real View-menu item, with its shortcut printed on it")
    func theViewMenuCarriesEveryPane() throws {
        // Before this, the View menu held exactly two items — `Hide
        // Toolbar` and `Enter Full Screen` — and closing a pane with its ✕ made it genuinely
        // unreachable. This asserts the menu a person goes looking for actually exists.
        let bar = ZenitMenuBar.make()
        let viewMenu = try #require(
            bar.items.first { $0.submenu?.title == ZPDFCommandGroup.view.displayName }?.submenu
        )
        for surface in ZPDFClosableSurface.allCases {
            let item = try #require(
                viewMenu.items.first { ($0.representedObject as? String) == surface.command.rawValue },
                "the View menu has no item for \(surface.rawValue)"
            )
            #expect(item.title == surface.showTitle)
            #expect(
                item.action == #selector(ZenitCommandResponding.performZenitCommand(_:)),
                "\(surface.rawValue) must reach the window's command router"
            )
            let binding = try #require(ZPDFCommandTable.standard.command(surface.command)?.binding)
            #expect(
                item.keyEquivalent == binding.key,
                "\(surface.rawValue)'s shortcut is not printed on its menu item"
            )
            #expect(item.keyEquivalentModifierMask == binding.modifiers.eventModifierFlags)
        }
        // And the two items that used to be the whole menu are still there, below the panes.
        #expect(viewMenu.items.contains { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
    }

    @Test("The two application-level commands are installed with their own identities")
    func applicationCommands() {
        let bar = ZenitMenuBar.make()
        var found: Set<String> = []
        // Recursive since IM-250 grouped the drawing exports and job templates into submenus.
        func walk(_ menu: NSMenu) {
            for entry in menu.items {
                if let raw = entry.representedObject as? String, ZenitAppCommand(rawValue: raw) != nil {
                    found.insert(raw)
                }
                if let nested = entry.submenu { walk(nested) }
            }
        }
        for item in bar.items {
            guard let submenu = item.submenu else { continue }
            walk(submenu)
        }
        #expect(found == Set(ZenitAppCommand.allCases.map(\.rawValue)))
    }
}
