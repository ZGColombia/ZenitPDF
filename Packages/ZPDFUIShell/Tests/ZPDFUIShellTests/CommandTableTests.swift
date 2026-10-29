import Foundation
import Testing
@testable import ZPDFUIShell

/// Asserts that the menu and keyboard table is installable: no chord is claimed twice in the
/// same context, every deliberate override of a broader binding is written down, and every
/// shortcut the keyboard map fixes is actually present with the printed form the map shows.
@Suite("Command table", .shellTierSerialised)
struct CommandTableTests {

    private let table = ZPDFCommandTable.standard

    @Test("No two commands claim the same chord in the same context")
    func noDuplicateShortcuts() {
        let conflicts = table.conflicts()
        #expect(conflicts.isEmpty, "\(conflicts.map(\.description))")
    }

    @Test("Every command identity appears at most once")
    func noDuplicateIdentities() {
        let ids = table.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every reuse of a broader chord is declared as a deliberate override")
    func shadowsAreDeclared() {
        let undeclared = table.undeclaredShadows()
        #expect(undeclared.isEmpty, "\(undeclared.map(\.rawValue))")
    }

    /// nl-ux (decided 2026-09-23): Area no longer shadows Select All's ⌘A.
    /// Old output: `[.measureArea, .removeLastVertex]`.
    @Test("Only the intended command shadows a broader binding")
    func expectedShadowsOnly() {
        let shadows = Set(table.commands.filter(\.shadowsBroaderBinding).map(\.id))
        #expect(shadows == [.removeLastVertex])
    }

    @Test("No application-scope command steals a chord macOS reserves")
    func doesNotStealSystemShortcuts() {
        let takeovers = table.systemShortcutTakeovers()
        #expect(takeovers.isEmpty, "\(takeovers.map(\.rawValue))")
    }

    @Test("Section 21.8 base shortcuts are present, with the printed form the plan shows")
    func planShortcutsArePresent() {
        let expected: [ZPDFCommandID: String] = [
            .openDocument: "\u{2318}O",
            .save: "\u{2318}S",
            .saveAs: "\u{21E7}\u{2318}S",
            .print: "\u{2318}P",
            .find: "\u{2318}F",
            .undo: "\u{2318}Z",
            .redo: "\u{21E7}\u{2318}Z",
            .zoomIn: "\u{2318}+",
            .zoomOut: "\u{2318}-",
            .fitWidth: "\u{2318}0",
            .actualSize: "\u{2318}1",
            .fitPage: "\u{2318}2",
            .measureLength: "\u{2318}L",
            .measurePolylength: "\u{21E7}\u{2318}L",
            .measureArea: "A",
            .measureCount: "\u{2318}K",
            .cancelTool: "\u{238B}",
            .finishGeometry: "\u{21A9}"
        ]
        for (id, printed) in expected {
            let command = table.command(id)
            #expect(command != nil, "missing command \(id.rawValue)")
            #expect(command?.binding?.displayString == printed, "wrong chord for \(id.rawValue)")
        }
    }

    /// ⌘A is Select All everywhere (decided 2026-09-23). Old output: Area was
    /// bound to ⌘A on the canvas, the same chord as Select All, so AppKit's menu-first key
    /// routing made ⌘A select on a page with markups and arm Area on a page without.
    @Test("⌘A is Select All only; Area is the canvas letter A")
    func commandAIsSelectAll() {
        #expect(table.command(.measureArea)?.context == .canvas)
        #expect(table.command(.selectAll)?.context == .application)
        #expect(table.command(.selectAll)?.binding?.chord == ZPDFKeyBinding.character("a", [.command]).chord)
        #expect(table.command(.measureArea)?.binding?.chord != table.command(.selectAll)?.binding?.chord)
        let commandA = table.boundCommands.filter { $0.binding?.chord == ZPDFKeyBinding.character("a", [.command]).chord }
        #expect(commandA.map(\.id) == [.selectAll])
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "a", modifiers: [], in: table) == .measureArea)
        #expect(CanvasToolShortcut.command(forCharactersIgnoringModifiers: "a", modifiers: [.command], in: table) == nil)
    }

    @Test("Delete removes a vertex while drawing and a markup otherwise")
    func deleteIsContextSplit() {
        #expect(table.command(.removeLastVertex)?.context == .canvasDrawing)
        #expect(table.command(.deleteSelection)?.context == .canvas)
        #expect(
            table.command(.removeLastVertex)?.binding?.chord
                == table.command(.deleteSelection)?.binding?.chord
        )
    }

    @Test("Every command has a non-empty title")
    func everyCommandIsLabelled() {
        for command in table.commands {
            #expect(!command.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test("Every declared command identity is in the table")
    func tableCoversEveryIdentity() {
        let ids = Set(table.commands.map(\.id))
        let missing = ZPDFCommandID.allCases.filter { !ids.contains($0) }
        #expect(missing.isEmpty, "\(missing.map(\.rawValue))")
    }

    @Test("Menus are built in menu-bar order and none is empty")
    func menusAreOrderedAndPopulated() {
        let menus = table.menus
        #expect(menus.map(\.group) == ZPDFCommandGroup.allCases.sorted { $0.menuOrder < $1.menuOrder })
        #expect(menus.allSatisfy { !$0.commands.isEmpty })
    }

    @Test("Every bound command can be spoken, chord included")
    func shortcutsAreSpeakable() {
        for command in table.boundCommands {
            let spoken = command.binding?.spokenString ?? ""
            #expect(!spoken.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!spoken.contains("\u{2318}"), "\(command.id.rawValue) spells a glyph out loud")
            #expect(command.accessibilityLabel.contains(command.title))
        }
    }

    @Test("Modifier glyphs are printed in Apple's canonical order")
    func modifierOrderMatchesAppKit() {
        let all: ZPDFModifierFlags = [.command, .shift, .option, .control]
        #expect(all.displayString == "\u{2303}\u{2325}\u{21E7}\u{2318}")
        #expect(ZPDFModifierFlags([.command, .shift]).displayString == "\u{21E7}\u{2318}")
        #expect(ZPDFModifierFlags([]).displayString.isEmpty)
    }

    @Test("A synthetic duplicate is actually detected")
    func detectsAnInjectedDuplicate() {
        // Guards the guard: a conflict check that never fires is not a check.
        let clash = ZPDFCommand(
            id: .toolLibrary,
            title: "Clash",
            group: .panels,
            binding: .character("s", [.command]),
            context: .application
        )
        let broken = ZPDFCommandTable(commands: [
            ZPDFCommandTable.standard.command(.save)!,
            clash
        ])
        #expect(broken.conflicts().count == 1)
        #expect(broken.conflicts().first?.shortcut == "\u{2318}S")
    }

    @Test("A synthetic undeclared override is actually detected")
    func detectsAnUndeclaredShadow() {
        let shadow = ZPDFCommand(
            id: .measureArea,
            title: "Area",
            group: .measure,
            binding: .character("a", [.command]),
            context: .canvas
        )
        let broken = ZPDFCommandTable(commands: [
            ZPDFCommandTable.standard.command(.selectAll)!,
            shadow
        ])
        #expect(broken.undeclaredShadows() == [.measureArea])
    }

    // MARK: - Page navigation

    /// Reported 2026-08-26: a 23-sheet elevation set opened, and there was no way to reach
    /// sheet 2 from the keyboard. The table had no page-navigation command of any kind.
    @Test("The four page-navigation commands exist, in the View menu, with printable shortcuts")
    func pageNavigationIsInTheTable() throws {
        let expected: [(ZPDFCommandID, String, String)] = [
            (.previousPage, "Previous Page", "\u{2318}\u{2191}"),
            (.nextPage, "Next Page", "\u{2318}\u{2193}"),
            (.firstPage, "First Page", "\u{2325}\u{2318}\u{2191}"),
            (.lastPage, "Last Page", "\u{2325}\u{2318}\u{2193}")
        ]
        for (id, title, printed) in expected {
            let command = try #require(table.command(id), "\(id) is not in the command table")
            #expect(command.title == title)
            #expect(command.group == .view, "\(id) is not in the View menu")
            let binding = try #require(command.binding, "\(id) has no shortcut")
            #expect(binding.displayString == printed, "\(id) prints \(binding.displayString)")
            // Every one of these must carry Command, or it never becomes a menu key equivalent
            // and the shortcut is invisible to anyone reading the menu.
            #expect(binding.modifiers.contains(.command))
        }
    }

    @Test("The arrow bindings use the function-key code NSMenuItem expects")
    func arrowBindingsUseFunctionKeys() throws {
        // U+2191 is the printed glyph; U+F700 is what `keyEquivalent` must actually hold. Using
        // the printed glyph as the key equivalent produces a menu item whose shortcut never
        // fires, which looks correct in a picture and is broken in the hand.
        let previous = try #require(table.command(.previousPage)?.binding)
        #expect(previous.key == "\u{F700}")
        let next = try #require(table.command(.nextPage)?.binding)
        #expect(next.key == "\u{F701}")
    }
}
