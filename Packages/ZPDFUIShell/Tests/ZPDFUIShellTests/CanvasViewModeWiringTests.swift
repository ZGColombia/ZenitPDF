import AppKit
import Foundation
import Testing
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

/// A canvas stand-in the tests can identify by object identity and interrogate for the
/// viewport it was left holding.
@MainActor
private final class StandInCanvasController: NSViewController {

    /// What a real canvas would call its scroll offset and zoom. Nothing here changes them,
    /// which is the point: entering and leaving a mode must not touch them.
    var scrollOffset = CGPoint(x: 412, y: 907)
    var zoom = 3.25
    private(set) var viewLoadCount = 0

    override func loadView() {
        viewLoadCount += 1
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
    }
}

@MainActor
private func makeWindow(
    environment: ProjectShellEnvironment,
    canvas: StandInCanvasController,
    key: String
) -> (ProjectWindowLayoutController, NSWindow) {
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key),
        canvasProvider: { canvas }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    // A programmatically created NSWindow releases itself on close, which over-releases the
    // local reference the test still holds — a segfault at the end of the test rather than a
    // failure that says anything.
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// Split Canvas and Revision Overlay: reachable, and leaving them gives the drawing back.
@Suite("Canvas view modes are reachable and reversible", .shellTierSerialised)
@MainActor
struct CanvasViewModeWiringTests {

    @Test("Split Canvas and Revision Overlay are real commands with no chord conflict")
    func theCommandsExist() {
        let table = ZPDFCommandTable.standard
        for id in [ZPDFCommandID.splitCanvas, .revisionOverlay, .closeCanvasMode] {
            let command = table.command(id)
            #expect(command != nil, "missing command \(id.rawValue)")
            #expect(command?.group == .tools)
            #expect(command?.title.isEmpty == false)
        }
        #expect(table.conflicts().isEmpty)
        #expect(table.undeclaredShadows().isEmpty)
        #expect(table.systemShortcutTakeovers().isEmpty)
    }

    @Test("Split Canvas puts a mode over the canvas and registers the way out first")
    func enteringSplitCanvas() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.split")
        defer { window.close() }

        #expect(!layout.isShowingCanvasMode)
        environment.perform(.splitCanvas)

        #expect(layout.isShowingCanvasMode)
        #expect(environment.canvasModes.activeMode == .splitCanvas)
        #expect(environment.modeRegistry.topmost?.id == DismissibleCanvasMode.splitCanvas.rawValue)
        #expect(environment.modeRegistry.exitRoute(for: DismissibleCanvasMode.splitCanvas.rawValue) != nil)
        #expect(environment.canvasModes.returnToken != nil, "the way back is captured on entry")
    }

    @Test("Leaving gives back the same canvas controller, never a rebuilt one")
    func theCanvasIsNeverRebuilt() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.same")
        defer { window.close() }

        let loadsBefore = canvas.viewLoadCount
        let identityBefore = ObjectIdentifier(layout.documentCanvasController!)
        let superviewBefore = canvas.view.superview

        environment.perform(.splitCanvas)
        #expect(canvas.view.superview === superviewBefore,
                "the canvas stays in the hierarchy while a mode covers it")
        environment.perform(.closeCanvasMode)

        #expect(!layout.isShowingCanvasMode)
        #expect(ObjectIdentifier(layout.documentCanvasController!) == identityBefore)
        #expect(canvas.viewLoadCount == loadsBefore, "the canvas view is never reloaded")
        #expect(canvas.view.superview === superviewBefore)
        // Scroll and zoom come back exactly because nothing ever changed them: the mode was a
        // cover, not a replacement.
        #expect(canvas.scrollOffset == CGPoint(x: 412, y: 907))
        #expect(canvas.zoom == 3.25)
    }

    @Test("Escape inside the mode leaves it, and the second Escape has nothing to do")
    func escapeLeavesTheMode() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.esc")
        defer { window.close() }

        environment.perform(.revisionOverlay)
        #expect(layout.isShowingCanvasMode)

        // The AppKit-level Escape: the mode's host controller is in the responder chain in
        // front of the window, and its cancelOperation is the route out.
        let host = try? #require(layout.canvasPane?.modeController)
        host?.cancelOperation(nil)

        #expect(!layout.isShowingCanvasMode)
        #expect(environment.canvasModes.activeMode == nil)
        #expect(!environment.modeRegistry.hasActiveMode)
        #expect(!environment.modeRegistry.escapeBacksOutOneLevel())
    }

    @Test("Escape routed through the shell's Cancel command leaves the mode, not the tool")
    func cancelToolLeavesTheModeFirst() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.cancel")
        defer { window.close() }

        environment.toolbar.activateMeasurement(.area)
        environment.perform(.splitCanvas)
        #expect(layout.isShowingCanvasMode)

        environment.perform(.cancelTool)
        #expect(!layout.isShowingCanvasMode)
        #expect(environment.toolbar.activeSelection.mode == .measure(.area),
                "leaving a view mode must not also disarm the tool underneath it")
    }

    @Test("The mode registry's exit route leaves the mode, so quitting is never blocked")
    func exitAllLeavesTheMode() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.quit")
        defer { window.close() }

        environment.perform(.splitCanvas)
        layout.toggleScaleRegionsPanel()
        #expect(layout.isShowingCanvasMode)
        #expect(layout.isShowingScaleRegionsPanel)

        environment.modeRegistry.exitAll()
        #expect(!environment.modeRegistry.hasActiveMode)
        #expect(!layout.isShowingCanvasMode)
        #expect(!layout.isShowingScaleRegionsPanel, "a floating panel must not outlive the quit path")
    }

    @Test("Asking for the mode that is already on screen leaves it, so the menu item toggles")
    func theCommandToggles() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.toggle")
        defer { window.close() }

        environment.perform(.splitCanvas)
        #expect(layout.isShowingCanvasMode)
        environment.perform(.splitCanvas)
        #expect(!layout.isShowingCanvasMode)
    }

    @Test("Switching modes keeps the original return token")
    func switchingModesKeepsTheFirstToken() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.switch")
        defer { window.close() }

        environment.perform(.splitCanvas)
        let original = environment.canvasModes.returnToken
        environment.perform(.revisionOverlay)
        #expect(environment.canvasModes.activeMode == .revisionOverlay)
        #expect(environment.canvasModes.returnToken == original)
        #expect(layout.canvasPane?.modeController != nil, "one cover at a time")

        // CR-120: this test named the registry in its title and never looked at it, so CR-97
        // shipped underneath it. One mode on the canvas is one exit route in the registry —
        // never two, and never the displaced one.
        #expect(
            environment.modeRegistry.modes.map(\.id) == [DismissibleCanvasMode.revisionOverlay.rawValue],
            "the displaced mode's exit route is still registered"
        )

        environment.perform(.closeCanvasMode)
        #expect(!layout.isShowingCanvasMode)
    }

    /// CR-97 — a mode-to-mode switch leaked the first mode's registration for the life of the
    /// window.
    ///
    /// `CanvasViewModeCoordinator.enter` replaces `activeMode` without running `onLeave`, and
    /// `onLeave` is what unregisters. Escape then closed the overlay and left `splitCanvas` in
    /// the registry with nothing on the canvas — so the Panels menu kept offering "Close Split
    /// Canvas", and `escapeBacksOutOneLevel()` had a stale route sitting on top of the stack.
    /// Old output, against the code before the fix:
    ///
    /// ```
    /// ✘ Test "A mode-to-mode switch retires the first mode's exit route" recorded an issue at
    ///   CanvasViewModeWiringTests.swift:240:9: Expectation failed:
    ///   (environment.modeRegistry.modes.map(\.id) → ["splitCanvas", "revisionOverlay"])
    ///   == ([DismissibleCanvasMode.revisionOverlay.rawValue] → ["revisionOverlay"])
    /// ✘ Test "A mode-to-mode switch retires the first mode's exit route" recorded an issue at
    ///   CanvasViewModeWiringTests.swift:249:9: Expectation failed:
    ///   (environment.modeRegistry.modes → [ZPDFRegisteredMode(id: "splitCanvas", …)]).isEmpty → false
    /// ✘ Test "Switching through all three modes leaves exactly one registration at every step"
    ///   recorded an issue at CanvasViewModeWiringTests.swift:262:13: Expectation failed:
    ///   (environment.modeRegistry.modes.map(\.id)
    ///   → ["splitCanvas", "revisionOverlay", "revisionCompare"]) == ([mode.rawValue]
    ///   → ["revisionCompare"])
    /// ✘ Test "Switching modes keeps the original return token" recorded an issue at
    ///   CanvasViewModeWiringTests.swift:202:9: Expectation failed:
    ///   (environment.modeRegistry.modes.map(\.id) → ["splitCanvas", "revisionOverlay"])
    ///   == ([DismissibleCanvasMode.revisionOverlay.rawValue] → ["revisionOverlay"])
    /// ```
    @Test("A mode-to-mode switch retires the first mode's exit route")
    func switchingModesUnregistersTheDisplacedMode() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (_, window) = makeWindow(environment: environment, canvas: canvas, key: "t.leak")
        defer { window.close() }

        environment.perform(.splitCanvas)
        #expect(environment.modeRegistry.modes.map(\.id) == [DismissibleCanvasMode.splitCanvas.rawValue])

        environment.perform(.revisionOverlay)
        #expect(
            environment.modeRegistry.modes.map(\.id) == [DismissibleCanvasMode.revisionOverlay.rawValue],
            "Split Canvas is no longer on the canvas, so it may not still offer a way out of one"
        )

        // Escape backs out of the overlay, and the registry is then empty — not holding a
        // route to a pane that has not been on screen since the switch.
        environment.perform(.cancelTool)
        #expect(environment.canvasModes.activeMode == nil)
        #expect(environment.modeRegistry.modes.isEmpty)
        #expect(!environment.modeRegistry.hasActiveMode)
    }

    @Test("Switching through all three modes leaves exactly one registration at every step")
    func everyModeSwitchLeavesOneRegistration() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (_, window) = makeWindow(environment: environment, canvas: canvas, key: "t.three")
        defer { window.close() }

        for mode in [DismissibleCanvasMode.splitCanvas, .revisionOverlay, .revisionCompare, .splitCanvas] {
            environment.enterCanvasMode(mode)
            #expect(
                environment.modeRegistry.modes.map(\.id) == [mode.rawValue],
                "after entering \(mode.rawValue) the registry held \(environment.modeRegistry.modes.map(\.id))"
            )
        }
        environment.leaveCanvasMode()
        #expect(environment.modeRegistry.modes.isEmpty)
    }

    @Test("Re-entering the mode already on the canvas registers it once, not twice")
    func reenteringTheSameModeIsIdempotent() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (_, window) = makeWindow(environment: environment, canvas: canvas, key: "t.same")
        defer { window.close() }

        environment.enterCanvasMode(.splitCanvas)
        environment.enterCanvasMode(.splitCanvas)
        #expect(environment.modeRegistry.modes.map(\.id) == [DismissibleCanvasMode.splitCanvas.rawValue])
    }

    @Test("The app tier is told when a mode ends, with the viewport it was entered from")
    func leavingReportsTheReturnToken() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (_, window) = makeWindow(environment: environment, canvas: canvas, key: "t.report")
        defer { window.close() }

        var reported: [(DismissibleCanvasMode, CanvasReturnToken?)] = []
        environment.onLeaveCanvasMode = { reported.append(($0, $1)) }

        environment.perform(.splitCanvas)
        let entered = environment.canvasModes.returnToken
        environment.perform(.closeCanvasMode)

        #expect(reported.count == 1)
        #expect(reported.first?.0 == .splitCanvas)
        #expect(reported.first?.1 == entered)
    }

    @Test("Leaving when no mode is active does nothing at all")
    func leavingWithoutAModeIsHarmless() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.none")
        defer { window.close() }

        var reported = 0
        environment.onLeaveCanvasMode = { _, _ in reported += 1 }
        environment.perform(.closeCanvasMode)
        #expect(reported == 0)
        #expect(!layout.isShowingCanvasMode)
    }

    @Test("Revision Overlay is built over the revisions the compare presenter published")
    func overlayLayersComeFromTheDocument() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (_, window) = makeWindow(environment: environment, canvas: canvas, key: "t.overlay")
        defer { window.close() }

        environment.perform(.revisionOverlay)
        #expect(environment.revisionOverlay.layers.count == environment.compare.revisions.count)
        #expect(Set(environment.revisionOverlay.layers.map(\.colorName)).count
                == min(environment.compare.revisions.count, ZenitMarkupPalette.entries.count),
                "each stacked revision gets a colour with a spoken name")
    }

    @Test("Split Canvas mirrors the pane the person is touching, and never echoes back")
    func splitPanesSynchronise() {
        let environment = ProjectShellEnvironment.mock()
        environment.splitCanvas.setLayout(.twoColumns)
        environment.splitCanvas.syncOptions = .locked

        environment.splitCanvas.setZoom(2.0, in: .first)
        #expect(environment.splitCanvas.pane(.second).zoom == 2.0)
        environment.splitCanvas.setScrollOffset(PDFPointValue(x: 40, y: 90), in: .second)
        #expect(environment.splitCanvas.pane(.first).scrollOffset == PDFPointValue(x: 40, y: 90))

        environment.splitCanvas.syncOptions = .independent
        environment.splitCanvas.setZoom(0.5, in: .first)
        #expect(environment.splitCanvas.pane(.second).zoom == 2.0, "independent means independent")
    }
}

/// The Scale Regions panel: reachable from the shipping window, and closable three ways.
@Suite("Scale Regions panel reachability", .shellTierSerialised)
@MainActor
struct ScaleRegionsPanelReachabilityTests {

    @Test("Show Scale Regions is a real command with a chord and no conflict")
    func theCommandExists() {
        let table = ZPDFCommandTable.standard
        let command = table.command(.scaleRegions)
        #expect(command != nil)
        #expect(command?.group == .panels)
        #expect(command?.binding?.displayString == "\u{2325}\u{2318}R")
        #expect(table.conflicts().isEmpty)
    }

    @Test("The menu command shows the panel and leaves it up; the chip's press is the way back")
    func theCommandShowsAndTheChipToggles() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.regions")
        defer { window.close() }

        environment.perform(.scaleRegions)
        #expect(layout.isShowingScaleRegionsPanel)
        #expect(environment.modeRegistry.topmost?.id == ProjectWindowLayoutController.scaleRegionsModeID)

        // L-94: Panels ▸ Show Scale Regions says "Show"; a second choice does not close it.
        environment.perform(.scaleRegions)
        #expect(layout.isShowingScaleRegionsPanel)
        #expect(environment.modeRegistry.hasActiveMode)

        // The lit chip closes it.
        environment.toolbar.run(.scaleRegions)
        #expect(!layout.isShowingScaleRegionsPanel)
        #expect(!environment.modeRegistry.hasActiveMode)
    }

    @Test("Opening it loads the page's regions and the scales they could be given")
    func thePanelReadsTheDocument() {
        let environment = ProjectShellEnvironment.mock()
        environment.perform(.scaleRegions)

        let expected = environment.document.currentPageID
            .map { environment.document.scaleRegions(onPage: $0) }
            ?? environment.document.scaleRegions
        #expect(environment.scaleRegions.regions.count == expected.count)
        #expect(environment.scaleRegions.pageDefaultScale?.id == environment.document.defaultScale?.id)
        if environment.document.defaultScale != nil {
            #expect(!environment.scaleRegions.availableScales.isEmpty,
                    "a scale already measured on this drawing is offered rather than invented")
        }
    }

    @Test("Escape on the panel host closes it and unregisters the mode")
    func escapeClosesThePanel() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.regesc")
        defer { window.close() }

        layout.toggleScaleRegionsPanel()
        let host = layout.scaleRegionsWindow?.window?.contentViewController
        #expect(host != nil)
        host?.cancelOperation(nil)

        #expect(!layout.isShowingScaleRegionsPanel)
        #expect(!environment.modeRegistry.hasActiveMode)
    }

    @Test("Closing the window by its own control reports the close exactly once")
    func closingTheWindowReportsOnce() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = StandInCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.regwin")
        defer { window.close() }

        layout.toggleScaleRegionsPanel()
        var closes = 0
        layout.scaleRegionsWindow?.onClose = { closes += 1 }
        layout.scaleRegionsWindow?.dismiss()
        #expect(closes == 1)
    }
}
