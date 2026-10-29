import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The tool style reaches the tool.
///
/// `ZenitToolbarModel.setStyle(_:)` had no caller, so `AppMarkupToolPresenter.style` stayed
/// `.zenitInk` and every new text box, callout and shape was drawn blue at 1.5 pt whatever the
/// person had just chosen. The Inspector now calls it — the tool style card with nothing
/// selected, and a style edit to a drawn markup as "last used". This suite proves the other half
/// in a real project window: a style set on the toolbar arrives at the armed markup presenter
/// through the selection the canvas observes, and a tool armed afterwards draws in it too.
///
/// The window is built and never ordered front; nothing reaches the screen.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ToolStyleReachesTheToolTests {

    /// The tool style is persisted with the window layout in this process's scratch store, so a
    /// style left by an earlier suite would be restored into this window and break the
    /// "starts at the default ink" precondition. Every test starts from an empty store.
    /// The per-kind table (NL-MARKUP-04) is one process-wide object that keeps its own copy,
    /// so it is emptied too; a kind remembered by an earlier suite would otherwise win over
    /// the style this test sets.
    init() {
        ZenitProcessDefaults.discardScratchStore()
        MarkupStyleDefaultsHost.shared.forgetAll()
    }

    private func wait(upTo seconds: Double = 60, for condition: @MainActor () -> Bool) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    @Test("A chosen tool style reaches the armed markup tool, and the next tool armed")
    func toolStyleReachesTheMarkupTool() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Tool Style.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        defer { document.close() }
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        shell.toolbar.selectTool(.text)
        #expect(await wait { core.markup.activeKind == .text })
        #expect(core.markup.style == .zenitInk)

        var style = ToolStyleSelection.zenitInk
        style.stroke = ColorRGBA(red: 0.8, green: 0.19, blue: 0.13, alpha: 1)
        style.lineWidth = 3
        style.fontSize = 18
        shell.toolbar.setStyle(style)
        #expect(await wait { core.markup.style == style }, "the armed Text tool never took the chosen style")
        #expect(core.markup.activeKind == .text)

        shell.toolbar.activateShape(.rectangle)
        #expect(await wait { core.markup.activeKind == .rectangle })
        #expect(core.markup.style == style, "a tool armed afterwards fell back to the default ink")

        let stored = AppMarkupToolPresenter.markupStyle(kind: .rectangle, style: core.markup.style)
        #expect(stored.lineWidth == 3)
        #expect(stored.fontSize == 18)
        #expect(abs(stored.color.red - 0.8) < 0.001)
    }

    @Test("Restyling a drawn markup from the Inspector sets the next markup's style")
    func lastUsedStyleReachesTheTool() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Tool Style Last.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        defer { document.close() }
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        let green = ColorRGBA(red: 0.12, green: 0.48, blue: 0.3, alpha: 1)
        shell.toolbar.rememberStyle(MarkupStyleEdit(color: green, lineWidth: 2))
        shell.toolbar.selectTool(.callout)
        #expect(await wait { core.markup.activeKind == .callout })
        #expect(core.markup.style.stroke == green)
        #expect(core.markup.style.lineWidth == 2)
    }
}
