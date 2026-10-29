import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

// Iteration-5 "uishell" items whose cause sits where the shell meets the application
// (iteration-5 findings). No window or sheet reaches the
// screen: the harness window is never ordered front, and the calibration sheet goes through
// `ZenitModalPresenter.beginSheet`, which records it.

@MainActor
@Suite("Iteration 5 uishell fixes (app tier)", .appTierSerialised)
struct Iter5UIShellAppTests {

    /// The chip the toolbar lights: the chips read the armed tool straight from the model.
    private func litChip(_ shell: ProjectShellEnvironment) -> ZenitToolIdentifier {
        shell.toolbar.activeTool
    }

    /// Old output: the canvas ended its two-click pick by arming Select, and the calibration
    /// sheet opened a moment later — so for as long as the sheet was up the toolbar lit Select,
    /// not Calibrate (the zoomed toolbar during the sheet).
    @Test("L-05: the Calibrate chip stays lit while the calibration sheet finishes its pick")
    func calibrateChipStaysLitDuringTheSheet() async throws {
        ZenitModalPresenter.reset()
        let harness = try await Fix2Harness.make("It5 Calibrate Chip.pdf", calibrate: false)
        defer {
            ScaleSheetCoordinator.active(for: harness.document)?.cancel()
            harness.tearDown()
            ZenitModalPresenter.reset()
        }
        // The chip's path: the shell arms Calibrate and the window starts the pick.
        harness.shell.perform(.calibrateScale)
        #expect(harness.canvas.isCalibrating)
        #expect(litChip(harness.shell) == .calibrate)

        // The canvas collects its second point: it ends the pick and hands the points on, as
        // `appendCalibrationPoint` does.
        let points = [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 500, y: 100)]
        harness.canvas.endCalibration(collected: true)
        harness.canvas.onCalibrationPointsCollected?(points)
        let sheet = try #require(ScaleSheetCoordinator.active(for: harness.document))
        #expect(sheet.model.draft.primary.pdfDistance == 400)
        #expect(litChip(harness.shell) == .calibrate, "old output: .select while the sheet was up")
        #expect(sheet.holdsCalibrateTool)

        // Closing the sheet hands the toolbar back to Select, as the end of a pick always did.
        sheet.cancel()
        #expect(litChip(harness.shell) == .select)
        #expect(!harness.canvas.isCalibrating)
    }

    /// The sheet opened without a pick (Set Scale…) leaves the armed tool alone, and a sheet that
    /// stepped aside for "Pick points" comes back holding Calibrate until it is applied.
    @Test("L-05: only a sheet that finishes a pick takes the chip; applying returns to Select")
    func onlyAPickTakesTheChip() async throws {
        ZenitModalPresenter.reset()
        let harness = try await Fix2Harness.make("It5 Calibrate Chip Menu.pdf", calibrate: false)
        defer {
            ScaleSheetCoordinator.active(for: harness.document)?.cancel()
            harness.tearDown()
            ZenitModalPresenter.reset()
        }
        harness.shell.toolbar.activateMeasurement(.area)
        let sheet = try #require(harness.controller.presentScaleSheet(for: harness.document))
        #expect(harness.shell.toolbar.activeTool == .area, "Set Scale… opened no pick")
        #expect(!sheet.holdsCalibrateTool)

        // A page with no scale opens on the drawing ratio; the line is a uniform calibration.
        sheet.model.draft.mode = .uniform
        sheet.pick(.primaryStart)
        #expect(harness.shell.toolbar.activeTool == .calibrate, "the pick itself lights Calibrate")
        harness.canvas.endCalibration(collected: true)
        harness.canvas.onCalibrationPointsCollected?([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 400, y: 0)])
        #expect(sheet.pendingPick == nil)
        #expect(harness.shell.toolbar.activeTool == .calibrate, "old output: .select with the sheet back")

        sheet.model.draft.unitIdentifier = ZPDFUIPresentation.LengthUnit.metre.rawValue
        sheet.model.draft.primary.knownLength = 4
        await sheet.commit()
        #expect(sheet.isFinished)
        #expect(harness.shell.toolbar.activeTool == .select)
    }

    /// Old output: the selection halo was always one continuous round-capped band, 6 pt wider
    /// than the ink. Under a new Length — stored dashed, as the design draws it, and reported
    /// "Dashed" by the Inspector's Style row, which reads the same stored style the canvas
    /// strokes with — the band read as a solid line, so the selected Length looked solid.
    @Test("L-16: a selected dashed markup's halo is dashed in step with its ink")
    func dashedHaloFollowsTheInk() {
        // At fit zoom a 1.5 pt Length strokes at ~0.6 view pt; the ink's unit floors at 1.
        #expect(CanvasPageView.selectionHaloDash(.dashed, strokeWidth: 0.6) == [4, 3], "old output: nil (a solid band)")
        #expect(CanvasPageView.selectionHaloDash(.dashed, strokeWidth: 2) == [8, 6])
        #expect(CanvasPageView.selectionHaloDash(.dotted, strokeWidth: 1) == [1, 2.2])
        #expect(CanvasPageView.selectionHaloDash(.dashDot, strokeWidth: 1) == [4, 2, 1, 2])
        #expect(CanvasPageView.selectionHaloDash(.solid, strokeWidth: 2) == nil)
        #expect(CanvasPageView.selectionHaloDash(.cloud, strokeWidth: 2) == nil)
    }

    // MARK: - L-11: one lit chip after Text -> Select while typing

    /// The share of a chip's own pixels that carry paint (alpha above ~3 %), rendered off screen
    /// from its hosting view in the band. A chip at rest paints only its glyph and caption; a
    /// fill — armed, hover, press or open — covers most of the chip.
    private static func paintedShare(of view: NSView) -> Double {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var painted = 0, total = 0
        var pixel = [Int](repeating: 0, count: 4)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                rep.getPixel(&pixel, atX: x, y: y)
                total += 1
                if pixel[3] > 8 { painted += 1 }
            }
        }
        return total == 0 ? 0 : Double(painted) / Double(total)
    }

    /// Every tool chip in the band that draws a fill, by identifier.
    ///
    /// A window that is never ordered in gets no display cycle, so each hosting view is asked to
    /// run its update itself (a layout pass is where it resolves new @Observable reads). `after`
    /// is how long the chips are left before the render: `.zero` is a render taken right
    /// after the click; the chips' own animations run in real time.
    private static func litChips(
        _ band: ProjectTopBandView,
        after wait: Duration = .zero
    ) async -> (lit: [NSToolbarItem.Identifier], shares: [String: Double]) {
        let chips = band.centreEntries.filter { $0.identifier != .zenitToolSeparator }
        for _ in 0..<2 {
            for chip in chips {
                chip.view.needsLayout = true
                chip.view.layoutSubtreeIfNeeded()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if wait > .zero { try? await Task.sleep(for: wait) }
        var lit: [NSToolbarItem.Identifier] = []
        var shares: [String: Double] = [:]
        for chip in chips {
            chip.view.layoutSubtreeIfNeeded()
            let share = paintedShare(of: chip.view)
            shares[chip.identifier.rawValue] = (share * 100).rounded() / 100
            if share > 0.6 { lit.append(chip.identifier) }
        }
        return (lit, shares)
    }

    /// The reported sequence on the shipping window: arm Text with its chip's action, open a
    /// text box and type, switch to Select with its chip's action — then ask the toolbar, the
    /// canvas, the bar's pointer state and the rendered band what they hold, right after the
    /// click and once everything has settled.
    ///
    /// Found: the model, the canvas and the pointer state all hold one tool — nothing on the app
    /// side re-arms Text behind the chip's click (the commit keeps the chosen tool, L-10), and no
    /// hover or press survives the change. The second lit chip was in the drawing: each chip
    /// faded its armed fill over `.quick` (0.16 s) in its own hosting view, so a render taken
    /// right after the switch had the chip just left still filled beside the chip just armed.
    /// Old output, sampled right after `toolbar.run(.textTool)`: Select and Text both lit
    /// (painted share 0.99 each; Select's fill at alpha 103 of 255, mid-fade) — "two chips lit"
    /// right after switching. Settled 600 ms later: one.
    @Test("L-11: after Text -> Select while typing, one chip is lit at once and stays the only one")
    func textToSelectLeavesOneLitChip() async throws {
        let harness = try await Fix2Harness.make("It5 One Lit Chip.pdf")
        defer { harness.tearDown() }
        let layout = try #require(harness.controller.layoutController(for: harness.document))
        let band = try #require(layout.topBand)
        // A window wide enough that every tool chip is in the band, none in More.
        harness.controller.window?.setContentSize(NSSize(width: 1_672, height: 1_000))
        harness.controller.window?.layoutIfNeeded()
        band.needsLayout = true
        band.layoutSubtreeIfNeeded()
        #expect(band.overflowedCentreIdentifiers.isEmpty, "tools in More: \(band.overflowedCentreIdentifiers.map(\.rawValue))")
        #expect(band.centreEntries.contains { $0.identifier == .zenitText })
        #expect(band.centreEntries.contains { $0.identifier == .zenitSelect })
        let toolbar = harness.shell.toolbar
        let canvas = harness.canvas

        // At rest: Select alone.
        var state = await Self.litChips(band, after: .milliseconds(300))
        #expect(state.lit == [.zenitSelect], "at rest: \(state.shares)")

        // The Text chip's action — `toolbar.run(.textTool)` is exactly the closure the builder
        // gives the chip. Rendered at once, right after the click.
        toolbar.run(.textTool)
        #expect(toolbar.activeTool == .text)
        state = await Self.litChips(band)
        #expect(state.lit == [.zenitText], "right after arming Text: \(state.lit.map(\.rawValue)) \(state.shares)")

        // A text box, typed into, then the Select chip's action while the words are in the box.
        canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        #expect(canvas.activeTextEntry != nil)
        canvas.typeIntoTextEntry("Testtext 123")
        toolbar.run(.selectTool)
        state = await Self.litChips(band)
        #expect(state.lit == [.zenitSelect], "right after the switch: \(state.lit.map(\.rawValue)) \(state.shares)")

        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 1 }, "the switch commits the words (L-10)")
        // Every asynchronous follow-up lands: the core's refresh, the canvas's observation.
        await harness.settle()
        #expect(toolbar.activeTool == .select, "the model re-armed \(toolbar.activeTool) behind the chip's click")
        #expect(canvas.armedMode == .select)
        #expect(canvas.activeTextEntry == nil)
        #expect(toolbar.chipPointer.hovered == nil, "a hover survived the tool change")
        #expect(toolbar.chipPointer.pressed == nil, "a press survived the tool change")
        state = await Self.litChips(band, after: .milliseconds(600))
        #expect(state.lit == [.zenitSelect], "settled: \(state.lit.map(\.rawValue)) \(state.shares)")
    }

    /// V-046's third surface. Old output: the canvas's Move to Layer offered a locked layer's
    /// row enabled, as the Inspector popup did, while the Navigator refused it.
    @Test("V-046: the canvas's Move to Layer refuses a locked layer by the shell's one rule")
    func contextMenuRefusesALockedLayer() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "It5 Locked Layer.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        document.makeWindowControllers()
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let canvas = try #require(controller.canvasController(for: document))
        let core = try #require(document.core)

        await MarkupLayerActions.addLayer(named: "Walls", moving: [], core: core)
        let walls = try #require(core.snapshot.markupLayers.first { $0.name == "Walls" }?.id)
        await MarkupLayerActions.setActive(MarkupLayer.defaultID.rawValue, core: core)
        let page = try #require(core.snapshot.pages.first)
        let pageID = PageID(page.id)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let record = MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: pageID, kind: .rectangle,
            subject: "Wall",
            geometry: MeasurementGeometry(pageID: pageID, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await core.commands.perform(.addMarkup(record))
        await MarkupLayerActions.setLocked(true, layer: walls.rawValue, core: core)
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [record.id.rawValue], additive: false)

        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 150, y: 150)))
        let move = try #require(menu.items.first { $0.title == "Move to Layer" }?.submenu)
        #expect(!move.autoenablesItems)
        let lockedRow = try #require(move.items.first { $0.title == "Walls" })
        #expect(!lockedRow.isEnabled, "old output: enabled")
        #expect(lockedRow.toolTip == MarkupLayerPanelModel.reason(.targetLocked))
        #expect(move.items.first { $0.title == "Default" }?.isEnabled == true)
    }
}
