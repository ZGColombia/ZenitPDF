import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// nl-ux: the app-tier UX bugs. Windows are built and never ordered on screen (Fix2Harness).
@MainActor
@Suite("nl-ux app bugs", .appTierSerialised)
struct NLUXAppBugTests {

    // MARK: - LT3-06

    /// LT3-06. Old output: with Area armed, Measure ▸ Calibrate Scale… (the app command, which
    /// calls `beginPageCalibration` without passing the toolbar) left
    /// `toolbar.activeTool == .area` — the Area chip stayed lit while the canvas calibrated.
    @Test("Calibrating from the Measure menu lights Calibrate and nothing else")
    func menuCalibrationArmsTheCalibrateChip() async throws {
        let harness = try await Fix2Harness.make("NLUX Calibrate.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.shell.toolbar.activateMeasurement(.area)
        #expect(harness.shell.toolbar.activeTool == .area)

        // NL-MEASURE-01 (nl-measure, 2026-09-23): the menu command opens the calibration sheet
        // instead of arming two-click picking, so the canvas is not calibrating and the Area
        // chip is still the only lit chip — the LT3-06 invariant, one lit chip, holds.
        ZenitAppCommandTable.perform(.calibrateScale, controller: harness.controller, document: harness.document)
        #expect(ScaleSheetCoordinator.active(for: harness.document) != nil, "the menu opened no calibration sheet")
        #expect(!harness.canvas.isCalibrating)
        #expect(harness.shell.toolbar.activeTool == .area)
        ScaleSheetCoordinator.active(for: harness.document)?.cancel()

        // The two-click path — the toolbar's Calibrate and the Scale Regions flow, which reach
        // `beginCalibration` — still lights Calibrate and nothing else.
        harness.controller.beginPageCalibration(for: harness.document)
        #expect(harness.canvas.isCalibrating)
        #expect(harness.shell.toolbar.activeTool == .calibrate)
        #expect(harness.canvas.armedMode == .calibrate)
        #expect(harness.core.measurement.activeKind == nil, "the Area tool was disarmed")

        harness.canvas.endCalibration()
        #expect(harness.shell.toolbar.activeTool == .select)
    }

    // MARK: - ⌘A

    /// A responder that swallows the keys the page view passes on, so a test never beeps.
    private final class Swallower: NSResponder {
        override func keyDown(with event: NSEvent) {}
    }

    /// Design decision 2026-09-23. Old output: the page view mapped ⌘A to `.area` in
    /// `keyDown`, which AppKit reached whenever the menu's Select All was disabled (a page
    /// without markups), so ⌘A armed Area there and selected everything elsewhere.
    @Test("⌘A on the canvas never arms Area; the menu bar's only ⌘A is Select All")
    func commandAIsSelectAll() async throws {
        let harness = try await Fix2Harness.make("NLUX CommandA.pdf")
        defer { harness.tearDown() }
        let pageView = harness.canvas.pageViewForTesting
        var keys: [CanvasKey] = []
        let original = pageView.onKey
        pageView.onKey = { key in keys.append(key); return true }
        let next = pageView.nextResponder
        pageView.nextResponder = Swallower()
        defer {
            pageView.onKey = original
            pageView.nextResponder = next
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pageView.window?.windowNumber ?? 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        pageView.keyDown(with: event)
        #expect(keys.isEmpty, "⌘A reached the canvas as \(keys)")
        #expect(harness.shell.toolbar.activeTool != .area)

        let bar = ZenitMenuBar.make()
        let commandA = bar.items.compactMap(\.submenu).flatMap(\.items).filter {
            $0.keyEquivalent == "a" && $0.keyEquivalentModifierMask == .command
        }
        #expect(commandA.count == 1)
        #expect(commandA.first?.action == #selector(NSResponder.selectAll(_:)))
    }

    // MARK: - Export chip

    /// Old output: the toolbar Export chip ran `.export`, the ledger export only; the drawing
    /// exports were reachable from File ▸ Export Drawing and nowhere near the chip.
    @Test("The Export chip's chooser lists the ledger and every drawing export, with File-menu rules")
    func exportChooserListsEveryExport() async throws {
        let harness = try await Fix2Harness.make("NLUX Export.pdf")
        defer { harness.tearDown() }
        #expect(harness.shell.onPresentExportChooser != nil, "the chip is wired to the chooser")

        var menu = harness.controller.makeExportChooserMenu(for: harness.document)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.first == "Quantity Ledger…")
        for command in ProjectWindowController.exportChooserCommands {
            #expect(titles.contains(ZenitAppCommandTable.spec(for: command).title), "\(command) missing")
        }
        // Nothing measured yet: the ledger row is off and says why; the drawing exports are on.
        #expect(menu.items.first?.isEnabled == false)
        #expect(menu.items.first?.toolTip?.isEmpty == false)
        let marked = try #require(menu.items.first { $0.title == ZenitAppCommandTable.spec(for: .exportFlattenedPDF).title })
        #expect(marked.isEnabled)
        // A snippet needs a selection.
        let snippet = try #require(menu.items.first { $0.title == ZenitAppCommandTable.spec(for: .exportSnippet).title })
        #expect(!snippet.isEnabled)

        try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }
        await harness.core.ledger.refresh()
        menu = harness.controller.makeExportChooserMenu(for: harness.document)
        #expect(menu.items.first?.isEnabled == true)
    }

    // MARK: - Inspector Project Zone

    /// Old output: the Inspector's Project Zone row was text, and no Inspector path reached
    /// `setMarkupZone`; `inspectorEditing.onSetZone` did not exist.
    @Test("The Inspector files markups into a zone and out again, one undo step each")
    func inspectorZoneAssignment() async throws {
        let harness = try await Fix2Harness.make("NLUX Zone.pdf")
        defer { harness.tearDown() }
        let panel = harness.shell.projectZones
        panel.beginZone()
        panel.setDraftName("Kitchen")
        panel.setDraftKind(.room)
        #expect(panel.commitDraft())
        #expect(await AppTestSupport.wait { panel.zones.count == 1 })
        let zoneID = try #require(panel.zones.first?.id)
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }
        let assign = try #require(harness.shell.inspectorEditing.onSetZone)

        assign([record.id.rawValue], zoneID)
        #expect(await AppTestSupport.wait {
            harness.core.snapshot.markups.first { $0.id == record.id.rawValue }?.zone == "Kitchen"
        })
        #expect(harness.document.undoManager?.undoActionName == "Assign Zone")

        assign([record.id.rawValue], nil)
        #expect(await AppTestSupport.wait {
            harness.core.snapshot.markups.first { $0.id == record.id.rawValue }?.zone == nil
        })
        harness.document.undoManager?.undo()
        #expect(await AppTestSupport.wait {
            harness.core.snapshot.markups.first { $0.id == record.id.rawValue }?.zone == "Kitchen"
        })
    }

    // MARK: - Tool Library

    /// Old output: `presentToolLibrary` began a 720 × 520 sheet on the project window
    /// (`window.attachedSheet != nil`), so the canvas and toolbar took no clicks while it was
    /// open, and the chip — covered by the sheet — could not close it.
    @Test("The Tool Library is a non-modal panel the chip opens and closes")
    func toolLibraryIsNonModal() async throws {
        let harness = try await Fix2Harness.make("NLUX Tools.pdf")
        defer { harness.tearDown() }
        let window = try #require(harness.controller.window)

        harness.shell.perform(.toolLibrary)
        #expect(window.attachedSheet == nil, "nothing modal covers the window")
        #expect(harness.shell.isPanelOpen(.toolLibrary))
        let chest = try #require(ToolChestPanel.open[ObjectIdentifier(harness.document)])
        #expect(chest.model.onChange != nil, "the panel's edits still reach the document")
        #expect(!chest.isOnScreen, "a test process never draws the panel")
        #expect(!(chest.panel.canBecomeMain))

        // The canvas stays armed-able while the panel is open.
        harness.shell.toolbar.activateMeasurement(.length)
        #expect(harness.core.measurement.activeKind == .length)

        // The chip again is the way back.
        harness.shell.perform(.toolLibrary)
        #expect(!harness.shell.isPanelOpen(.toolLibrary))
        #expect(chest.isClosed)
        #expect(ToolChestPanel.open[ObjectIdentifier(harness.document)] == nil)

        // Escape closes it too.
        harness.shell.perform(.toolLibrary)
        let second = try #require(ToolChestPanel.open[ObjectIdentifier(harness.document)])
        second.panel.cancelOperation(nil)
        #expect(!harness.shell.isPanelOpen(.toolLibrary))
    }

    @Test("The panel sits inside the window's right edge, below the top band")
    func toolChestFrame() {
        let parent = NSRect(x: 100, y: 100, width: 1400, height: 900)
        let frame = ToolChestPanel.frame(besides: parent, size: ToolChestPanel.defaultSize)
        #expect(frame.maxX == parent.maxX - 12)
        #expect(frame.maxY == parent.maxY - 96)
        #expect(frame.width == ToolChestPanel.defaultSize.width)
        #expect(parent.contains(frame))
    }

    // MARK: - Layers on every page

    /// A two-page drawing whose both pages draw inside one optional-content group, "Walls"
    /// (`/L0` on each page): page 1 a horizontal line at y = 100, page 2 a vertical line at
    /// x = 500. Written by hand so the xref offsets are exact.
    static func twoPageLayeredPDF() -> Data {
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [3 0 R] /D << /ON [3 0 R] /Order [3 0 R] >> >> >>")
        objects.append("<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>")
        objects.append("<< /Type /OCG /Name (Walls) >>")
        let page1 = "/OC /L0 BDC 2 w 100 100 m 500 100 l S EMC"
        let page2 = "/OC /L0 BDC 2 w 500 100 m 500 700 l S EMC"
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Properties << /L0 3 0 R >> >> /Contents 5 0 R >>")
        objects.append("<< /Length \(page1.utf8.count) >>\nstream\n\(page1)\nendstream")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Properties << /L0 3 0 R >> >> /Contents 7 0 R >>")
        objects.append("<< /Length \(page2.utf8.count) >>\nstream\n\(page2)\nendstream")
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// Old output: hiding Walls on
    /// page 2 produced a filter built from **page 0**'s extraction (`cacheKey.pageIndex == 0`)
    /// and page 0's hidden names, which the canvas then drew on page 2; the snap index was
    /// rebuilt for page 1 only; and turning the page recomputed nothing.
    @Test("Hiding a layer filters the page on screen, and a page turn refilters the new page")
    func layerToggleFollowsThePage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-nlux-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Two Sheets.pdf")
        try Self.twoPageLayeredPDF().write(to: url)

        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil })
        #expect(await AppTestSupport.wait { document.layerVisibility.hasLayers })
        let shell = try #require(document.shell)
        let core = try #require(document.core)
        #expect(await AppTestSupport.wait { !shell.navigatorLayers.rows.isEmpty })
        var renders: [LayerFilteredPageRenderer.Filtering?] = []
        document.onLayerRenderingChange = { renders.append($0) }

        core.document.goToPage(index: 1)
        #expect(document.layerPageIndex(on: core) == 1)
        let walls = try #require(shell.navigatorLayers.rows.first)
        shell.navigatorLayers.setVisible(false, layerID: walls.id)
        #expect(await AppTestSupport.wait { !renders.isEmpty })
        let onSecond = try #require(renders.last ?? nil)
        #expect(onSecond.pageIndex == 1)
        #expect(onSecond.extraction.cacheKey.pageIndex == 1)
        #expect(onSecond.applies(toPageIndex: 1) && !onSecond.applies(toPageIndex: 0))
        #expect(onSecond.hiddenLayerIDs.contains("L0"))

        renders = []
        core.document.goToPage(index: 0)
        #expect(await AppTestSupport.wait { !renders.isEmpty })
        let onFirst = try #require(renders.last ?? nil)
        #expect(onFirst.pageIndex == 0)
        #expect(onFirst.extraction.cacheKey.pageIndex == 0)

        // Back to the document default: page turns stop recomputing anything.
        shell.navigatorLayers.setVisible(true, layerID: walls.id)
        #expect(await AppTestSupport.wait { renders.last.flatMap { $0 } == nil })
        renders = []
        core.document.goToPage(index: 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(renders.isEmpty)
    }

    // MARK: - LT3-09

    /// Walks the accessibility tree the way an assistive client does: from the window through
    /// `accessibilityChildren`, collecting (role, label) pairs of every element.
    static func accessibilityInventory(of root: Any, depth: Int = 0, into found: inout [(role: String, label: String)]) {
        guard depth < 40 else { return }
        guard let element = root as? NSAccessibilityProtocol else { return }
        let role = element.accessibilityRole()?.rawValue ?? ""
        let label = element.accessibilityLabel() ?? ""
        found.append((role, label))
        for child in element.accessibilityChildren() ?? [] {
            accessibilityInventory(of: child, depth: depth + 1, into: &found)
        }
    }

    /// LT3-09: "the window reports no accessibility elements". A project window, built and never
    /// ordered on screen, exposes its top band, the tool chips, the panels and the canvas.
    @Test("The project window exposes its toolbar, tool chips, panels and canvas to accessibility")
    func windowExposesAccessibilityElements() async throws {
        try await Self.expectWindowExposesAccessibilityElements(fixture: "NLUX Accessibility.pdf")
    }

    /// L-04 re-check (iteration 2): the guard above was red whenever it ran after a suite that
    /// left a collapsed Navigator in the process layout store — `NLUXAppProposalTests
    /// .workspaceMenu` recalls a "Review" workspace with the Navigator collapsed, and the window
    /// persists it — and green alone. Every Fix2Harness window inherited the layout the previous
    /// test's window wrote. This stores exactly that leftover (both side panels collapsed) and
    /// then runs the same guard.
    ///
    /// Old output: "no element labelled Navigator" and "no element labelled Inspector" — the
    /// harness restored the stored layout, so the panels were collapsed before the walk began.
    @Test("LT3-09 guard: a collapsed layout an earlier test stored does not reach the next harness window")
    func accessibilityGuardIgnoresAStoredLayout() async throws {
        var leftover = ProjectWindowLayoutState.firstLaunch
        leftover.isNavigatorCollapsed = true
        leftover.isInspectorCollapsed = true
        let store = ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout)
        #expect(store.save(leftover))
        #expect(store.load().isNavigatorCollapsed, "the leftover was stored")
        try await Self.expectWindowExposesAccessibilityElements(fixture: "NLUX Accessibility Leftover.pdf")
    }

    private static func expectWindowExposesAccessibilityElements(fixture: String) async throws {
        let harness = try await Fix2Harness.make(fixture)
        defer { harness.tearDown() }
        let window = try #require(harness.controller.window)
        window.layoutIfNeeded()
        var found: [(role: String, label: String)] = []
        Self.accessibilityInventory(of: window, into: &found)
        let roles = Set(found.map(\.role))
        let labels = Set(found.map(\.label))
        #expect(found.count > 20, "only \(found.count) elements: \(found.prefix(10))")
        #expect(roles.contains(NSAccessibility.Role.toolbar.rawValue), "no toolbar in \(roles)")
        #expect(roles.contains(NSAccessibility.Role.button.rawValue))
        #expect(roles.contains(NSAccessibility.Role.layoutArea.rawValue), "no canvas in \(roles)")
        // Chips beyond the window's width sit in the overflow ("More toolbar items"), so only the
        // leading tools are asserted by name.
        for name in ["Select", "Area", "Calibrate", "More toolbar items", "Inspector", "Navigator"] {
            #expect(labels.contains(name), "no element labelled \(name)")
        }
    }
}
