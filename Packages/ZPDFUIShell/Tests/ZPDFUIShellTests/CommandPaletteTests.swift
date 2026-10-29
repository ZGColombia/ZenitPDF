import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-UX-05, the command palette. Acceptance: typing "are" ranks the Area tool
/// first and shows its shortcut; Return performs through `environment.perform`; every
/// `ZPDFCommandID`, tool preset, page label and subject is reachable; Escape dismisses.
@MainActor
@Suite("Command palette", .shellTierSerialised)
struct CommandPaletteTests {

    private func model(_ environment: ProjectShellEnvironment) -> CommandPaletteModel {
        CommandPaletteModel(recents: CommandPaletteMemoryRecents()) { environment.commandPaletteItems() }
    }

    @Test("Typing “are” ranks Area first, with its shortcut")
    func areRanksAreaFirst() throws {
        let environment = ProjectShellEnvironment.mock()
        let palette = model(environment)
        palette.query = "are"
        let first = try #require(palette.results.first)
        #expect(first.id == "command:\(ZPDFCommandID.measureArea.rawValue)", "got \(palette.results.prefix(3).map(\.title))")
        #expect(first.shortcut == "A")
    }

    @Test("Return performs the highlighted row through the shell, and dismisses first")
    func returnPerforms() throws {
        let environment = ProjectShellEnvironment.mock()
        let palette = model(environment)
        var events: [String] = []
        palette.onDismiss = { events.append("dismiss") }
        palette.query = "Area"
        #expect(palette.performSelected())
        events.append("after")
        #expect(environment.toolbar.activeTool == .area)
        #expect(events == ["dismiss", "after"])
    }

    @Test("Every shell command, preset, page and page subject is reachable")
    func everySourceIsReachable() {
        let environment = ProjectShellEnvironment.mock()
        let ids = Set(environment.commandPaletteItems().map(\.id))
        for command in environment.commands.commands {
            #expect(ids.contains("command:\(command.id.rawValue)"), "\(command.id) missing")
        }
        for preset in environment.toolLibrary.presets {
            #expect(ids.contains("preset:\(preset.id.uuidString)"))
        }
        for page in environment.document.pages {
            #expect(ids.contains("page:\(page.id)"))
        }
        for subject in Set(environment.canvas.visibleMarkups.map(\.subject)) where !subject.isEmpty {
            #expect(ids.contains("subject:\(subject)"))
        }
    }

    @Test("A page row turns the page; a subject row selects that subject on the page")
    func pageAndSubjectRows() throws {
        let environment = ProjectShellEnvironment.mock()
        let items = environment.commandPaletteItems()
        if environment.document.pages.count > 1 {
            let last = try #require(environment.document.pages.last)
            let row = try #require(items.first { $0.id == "page:\(last.id)" })
            row.perform()
            #expect(environment.document.currentPageID == last.id)
        }
        let visible = environment.canvas.visibleMarkups.filter { !$0.subject.isEmpty }
        if let subject = visible.first?.subject {
            let row = try #require(environment.commandPaletteItems().first { $0.id == "subject:\(subject)" })
            row.perform()
            #expect(environment.canvas.selectedMarkupIDs == Set(visible.filter { $0.subject == subject }.map(\.id)))
        }
    }

    @Test("Ranking: prefix beats word prefix beats substring beats subsequence; no match is nil")
    func rankingOrder() throws {
        let prefix = try #require(CommandPaletteModel.score(query: "cal", text: "Calibrate"))
        let word = try #require(CommandPaletteModel.score(query: "cal", text: "Scale Calibrate"))
        let substring = try #require(CommandPaletteModel.score(query: "lib", text: "Calibrate"))
        let subsequence = try #require(CommandPaletteModel.score(query: "clb", text: "Calibrate"))
        #expect(prefix > word)
        #expect(word > substring)
        #expect(substring > subsequence)
        #expect(CommandPaletteModel.score(query: "xyz", text: "Calibrate") == nil)
        // Diacritics and case fold: Swedish page labels are found without the accent.
        #expect(CommandPaletteModel.score(query: "ov", text: "Över") != nil)
    }

    @Test("A recently used row rises; a disabled row sinks and does nothing")
    func recentsAndDisabled() {
        let recents = CommandPaletteMemoryRecents()
        var ran: [String] = []
        let items = [
            CommandPaletteItem(id: "a", title: "Zoom In", detail: "View", category: .command) { ran.append("a") },
            CommandPaletteItem(id: "b", title: "Zoom Out", detail: "View", category: .command) { ran.append("b") },
            CommandPaletteItem(id: "c", title: "Zoom Tool", detail: "Tools", category: .tool, isEnabled: false) { ran.append("c") }
        ]
        let palette = CommandPaletteModel(recents: recents) { items }
        palette.query = "zoom"
        #expect(palette.results.map(\.id).first == "a")
        #expect(palette.results.last?.id == "c")
        #expect(!palette.perform(items[2]))
        #expect(palette.perform(items[1]))
        #expect(recents.recentIDs == ["b"])
        palette.reload()
        palette.query = "zoom"
        #expect(palette.results.first?.id == "b")
        #expect(ran == ["b"])
    }

    @Test("Arrow keys move and clamp the highlight; Escape dismisses")
    func keyboard() {
        let environment = ProjectShellEnvironment.mock()
        let palette = model(environment)
        var dismissed = 0
        palette.onDismiss = { dismissed += 1 }
        palette.query = "zoom"
        #expect(palette.results.count > 2)
        palette.moveSelection(by: -1)
        #expect(palette.selectedIndex == 0)
        palette.moveSelection(by: 2)
        #expect(palette.selectedIndex == 2)
        palette.moveSelection(by: 10_000)
        #expect(palette.selectedIndex == palette.results.count - 1)
        palette.dismiss()
        #expect(dismissed == 1)
    }

    @Test("The app's extra rows and the validator reach the palette")
    func appRowsAndValidator() {
        let environment = ProjectShellEnvironment.mock()
        environment.commandPaletteExtraItems = {
            [CommandPaletteItem(id: "app:snippet", title: "Copy Snippet", detail: "Edit", category: .command) {}]
        }
        environment.commandPaletteValidator = { $0 != .export }
        let items = environment.commandPaletteItems()
        #expect(items.contains { $0.id == "app:snippet" })
        #expect(items.first { $0.id == "command:\(ZPDFCommandID.export.rawValue)" }?.isEnabled == false)
        #expect(items.first { $0.id == "command:\(ZPDFCommandID.zoomIn.rawValue)" }?.isEnabled == true)
    }
}
