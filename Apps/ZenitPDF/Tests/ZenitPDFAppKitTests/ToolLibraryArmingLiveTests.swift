import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// RT-8, retest of LT-37 (2026-08-31): picking a Tool Library preset left the status bar on
/// "Tool Select" and the canvas unarmed, in the shipping build. The presenter's `onArm` was
/// proven; what was never proven end-to-end is that the ARMING REACHES THE TOOLBAR AND THE
/// STATUS BAR through the application's own wiring, which is the only thing a person can see.
@MainActor
@Suite(.appTierSerialised)
struct ToolLibraryArmingLiveTests {

    @Test("Picking a Draw preset arms the tool, the toolbar and the status bar")
    func pickingAPresetArmsEverything() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "LibraryArm.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        // The everyday gesture: the Draw tab, then a preset tile.
        let preset = try #require(
            core.toolLibrary.presets.first { $0.measurementKind != nil },
            "the default library must ship a measuring preset"
        )
        core.toolLibrary.setMode(.draw, for: preset.panel)
        core.toolLibrary.activatePreset(id: preset.id)

        #expect(core.measurement.activeKind == preset.measurementKind,
                "RT-8: the measurement presenter did not arm")
        #expect(shell.toolbar.activeSelection.mode == .measure(try #require(preset.measurementKind)),
                "RT-8: the toolbar still shows the old tool, so the chips lie about the armed tool")
        #expect(core.status.snapshot.activeToolName != ZenitToolMode.select.displayName,
                "RT-8: the status bar still says Select after a Tool Library pick")

        document.close()
    }

    /// The tile's own call path, exactly: the sheet builds a `ToolLibraryEditingModel` copy
    /// of the presenter's presets, the tile closure calls `activatePreset` through the
    /// GENERIC `ToolLibraryPresenting` parameter, with the id taken from the MODEL's copy.
    @Test("The sheet's tile path — generic dispatch, model-copied id — still arms")
    func tilePathArms() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "LibraryArmTile.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        func clickTile<P: ToolLibraryPresenting>(_ presenter: P, id: ToolPresetSummary.ID) {
            presenter.activatePreset(id: id)
        }
        let model = ToolLibraryEditingModel(presets: core.toolLibrary.presets)
        let preset = try #require(model.presets.first { $0.measurementKind != nil })
        clickTile(core.toolLibrary, id: preset.id)

        #expect(core.measurement.activeKind == preset.measurementKind)
        #expect(shell.toolbar.activeSelection.mode == .measure(try #require(preset.measurementKind)))
        document.close()
    }
}
