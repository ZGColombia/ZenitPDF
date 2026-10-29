import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

@MainActor
private func makeWindow(key: String) -> (ProjectWindowLayoutController, NSWindow, ProjectShellEnvironment) {
    let environment = ProjectShellEnvironment.mock()
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key)
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    // A programmatically created `NSWindow` releases itself on close and would over-release the
    // reference this test still holds — the same reason every other shell window test says so.
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    // The window is never displayed, so nothing forces a layout pass at the real content size:
    // without this the split views come up at the fitting size and every divider position the
    // test asks for is clamped to a minimum thickness.
    window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window, environment)
}

/// **A rule enforced rather than remembered.**
///
/// > Every closable surface must also be openable from a persistent affordance and from a menu
/// > item, and the test must fail if a new panel is added without both.
///
/// The earlier "no dead ends" work checked only the way *out*: every panel could be closed with
/// Escape and every mode had an exit route. Yet closing the Navigator and the Quantity Ledger
/// left no way to get either back, because the View menu held two items — `Hide Toolbar`
/// and `Enter Full Screen` — and nothing anywhere restored a pane.
///
/// So this suite walks ``ZPDFClosableSurface/allCases`` and demands, for every one of them:
///
/// | Requirement | Test |
/// |---|---|
/// | A View-menu item, with a shortcut a menu can carry | ``everySurfaceHasAMenuItem()`` |
/// | A title that flips with the pane's state | ``everyMenuTitleFlips()`` |
/// | An ear, in this window's view tree, on the pane's own edge | ``everySurfaceHasAnEar()`` |
/// | The ear appears exactly when the pane is gone | ``closingAPaneRaisesItsEar()`` |
/// | …including both bottom tabs at once | ``closingTheBottomPaneRaisesBothEars()`` |
/// | Restoring gives back the size the pane had | ``theEarRestoresThePreviousSize()`` |
/// | A double-clicked divider collapses and restores | ``doubleClickingADividerCollapsesAndRestores()`` |
///
/// Adding a surface without either affordance cannot pass: the enum's `switch`es make the
/// compiler demand an edge and a command, and these tests make the command be a real, bound
/// View-menu entry with an ear behind it.
@Suite("Closable surface affordances", .shellTierSerialised)
@MainActor
struct ClosableSurfaceAffordanceTests {

    private let table = ZPDFCommandTable.standard

    // MARK: - The menu item

    @Test("Every closable surface has a View-menu item with a menu-carriable shortcut")
    func everySurfaceHasAMenuItem() throws {
        #expect(ZPDFClosableSurface.allCases.count == 4, "the surface set changed; check the ears too")
        for surface in ZPDFClosableSurface.allCases {
            let command = try #require(
                table.command(surface.command),
                "\(surface.rawValue) has no command in the table"
            )
            #expect(
                command.group == .view,
                "\(surface.rawValue) must be in the View menu, where macOS puts pane visibility"
            )
            let binding = try #require(
                command.binding,
                "\(surface.rawValue) has no shortcut; every closable surface needs one from the keyboard map"
            )
            // The two conditions `ZenitMenuBar.allowsMenuKeyEquivalent` applies before it will
            // print a chord next to a menu item. A pane toggle that fails either would show a
            // menu item with no shortcut on it, which is half the affordance.
            #expect(
                binding.modifiers.contains(.command),
                "\(surface.rawValue)'s chord must contain Command to be a menu key equivalent"
            )
            #expect(
                !command.shadowsBroaderBinding,
                "\(surface.rawValue) must not shadow a broader chord; the menu bar withholds those"
            )
        }
    }

    @Test("Every pane command's title flips with the pane's state")
    func everyMenuTitleFlips() {
        for surface in ZPDFClosableSurface.allCases {
            let shown = surface.menuTitle(isVisible: true)
            let hidden = surface.menuTitle(isVisible: false)
            #expect(shown != hidden, "\(surface.rawValue)'s title must say which way it goes")
            #expect(hidden == surface.showTitle)
            #expect(!shown.isEmpty && !hidden.isEmpty)
            // The command's declared title is the "Show …" form, which is what an unvalidated
            // menu shows and what the ear speaks.
            #expect(table.command(surface.command)?.title == surface.showTitle)
        }
    }

    @Test("No two surfaces share a command, and no chord is claimed twice")
    func theSurfaceCommandsAreDistinct() {
        let commands = Set(ZPDFClosableSurface.allCases.map(\.command))
        #expect(commands.count == ZPDFClosableSurface.allCases.count)
        #expect(table.conflicts().isEmpty, "\(table.conflicts())")
    }

    // MARK: - The ear

    @Test("Every closable surface has an ear in the window's view tree, on its own edge")
    func everySurfaceHasAnEar() throws {
        let (layout, window, _) = makeWindow(key: "test.ears.tree")
        defer { window.contentViewController = nil }

        for surface in ZPDFClosableSurface.allCases {
            let host = try #require(
                layout.paneEarHost(for: surface),
                "\(surface.rawValue) has no ear; every closable surface needs one at the edge it lived on"
            )
            #expect(
                host.isDescendant(of: layout.view),
                "\(surface.rawValue)'s ear is built but not in the window — the six-times bug"
            )
        }
        // Three edges, three strips: two surfaces sharing the bottom edge share one strip, and
        // no edge is left without one.
        let hosts = ZPDFClosableSurface.allCases.compactMap { layout.paneEarHost(for: $0) }
        #expect(Set(hosts.map(ObjectIdentifier.init)).count == ZPDFPaneEdge.allCases.count)
    }

    @Test("Closing a pane raises its ear; opening it puts the ear away")
    func closingAPaneRaisesItsEar() {
        let (layout, window, _) = makeWindow(key: "test.ears.raise")
        defer { window.contentViewController = nil }

        #expect(layout.isVisible(.navigator))
        #expect(!layout.panelState.showsEar(for: .navigator))

        layout.setNavigatorVisible(false)
        #expect(!layout.isVisible(.navigator))
        #expect(layout.panelState.showsEar(for: .navigator), "a closed pane must leave an ear")

        layout.reveal(.navigator)
        #expect(layout.isVisible(.navigator))
        #expect(!layout.panelState.showsEar(for: .navigator))

        layout.setInspectorVisible(false)
        #expect(layout.panelState.showsEar(for: .inspector))
        layout.reveal(.inspector)
        #expect(!layout.panelState.showsEar(for: .inspector))
    }

    @Test("Closing the bottom pane raises both its ears, and either one brings it back")
    func closingTheBottomPaneRaisesBothEars() {
        let (layout, window, _) = makeWindow(key: "test.ears.bottom")
        defer { window.contentViewController = nil }

        layout.toggleBottomPane()
        #expect(!layout.isBottomPaneVisible)
        // The rule about the third edge, in one assertion: an affordance present for
        // one tab of a closed pane and absent for the other teaches a rule and then breaks it.
        #expect(layout.panelState.showsEar(for: .quantityLedger))
        #expect(layout.panelState.showsEar(for: .history))

        layout.reveal(.history)
        #expect(layout.isBottomPaneVisible)
        #expect(layout.panelState.bottomPaneTab == .history)
        #expect(layout.isVisible(.history))
        #expect(!layout.isVisible(.quantityLedger), "the pane shows one tab at a time")
        #expect(!layout.panelState.showsEar(for: .quantityLedger), "its tab is one click away")

        layout.toggleBottomPane()
        #expect(layout.panelState.showsEar(for: .quantityLedger))
        layout.reveal(.quantityLedger)
        #expect(layout.panelState.bottomPaneTab == .quantities)
    }

    @Test("The ear restores the pane at the size it had, not at a default")
    func theEarRestoresThePreviousSize() {
        let (layout, window, _) = makeWindow(key: "test.ears.size")
        defer { window.contentViewController = nil }

        let split = layout.contentSplitController.splitView
        split.setPosition(320, ofDividerAt: 0)
        layout.view.layoutSubtreeIfNeeded()
        // `persistLayoutState` is gated until the window has settled its launch frame, which a
        // headless window never does; `captureLayoutState` is the same read without the gate.
        layout.captureLayoutState()
        let chosen = layout.layoutState.navigatorWidth
        #expect(chosen > ProjectWindowLayoutState.default.navigatorWidth,
                "the test must move the divider off the shipped default to prove anything")

        layout.setNavigatorVisible(false)
        layout.reveal(.navigator)
        layout.view.layoutSubtreeIfNeeded()

        let restored = Double(layout.contentSplitController.splitViewItems[0].viewController.view.frame.width)
        #expect(
            abs(restored - chosen) < 2,
            "a pane that returns at the wrong size teaches the user not to close it: \(restored) vs \(chosen)"
        )
    }

    @Test("The remembered ledger height survives a close and a restore")
    func theBottomPaneRestoresItsHeight() {
        let (layout, window, _) = makeWindow(key: "test.ears.height")
        defer { window.contentViewController = nil }

        let outer = layout.outerSplitController.splitView
        outer.setPosition(outer.bounds.height - 300 - outer.dividerThickness, ofDividerAt: 0)
        layout.view.layoutSubtreeIfNeeded()
        layout.captureLayoutState()
        let chosen = layout.layoutState.ledgerHeight
        #expect(chosen > 240, "the divider move must leave a height worth restoring")

        layout.toggleBottomPane()
        layout.reveal(.quantityLedger)
        layout.view.layoutSubtreeIfNeeded()
        #expect(abs(layout.layoutState.ledgerHeight - chosen) < 4)
    }

    // MARK: - The divider

    @Test("Double-clicking a divider collapses the pane beside it, and restores it")
    func doubleClickingADividerCollapsesAndRestores() {
        let (layout, window, _) = makeWindow(key: "test.ears.divider")
        defer { window.contentViewController = nil }

        let content = layout.contentSplitController!
        let navigatorView = content.splitViewItems[0].viewController.view
        #expect(layout.isVisible(.navigator))

        // The delegate call AppKit makes on a double-clicked divider. `false` is the window
        // saying it handled the collapse itself, at the size it wants to restore to.
        let handled = content.splitView(
            content.splitView,
            shouldCollapseSubview: navigatorView,
            forDoubleClickOnDividerAt: 0
        )
        #expect(!handled, "the window collapses the pane itself so it can remember the size")
        #expect(!layout.isVisible(.navigator))

        _ = content.splitView(
            content.splitView,
            shouldCollapseSubview: navigatorView,
            forDoubleClickOnDividerAt: 0
        )
        #expect(layout.isVisible(.navigator), "the second double-click brings it back")

        // The outer split's only divider is the bottom pane's.
        let outer = layout.outerSplitController!
        let ledgerView = outer.splitViewItems[1].viewController.view
        _ = outer.splitView(
            outer.splitView,
            shouldCollapseSubview: ledgerView,
            forDoubleClickOnDividerAt: 0
        )
        #expect(!layout.isBottomPaneVisible)
        #expect(layout.panelState.showsEar(for: .quantityLedger))
    }

    // MARK: - The commands, end to end

    @Test("Each surface's command reaches the pane through the shell environment")
    func theCommandsReachThePanes() {
        let (layout, window, environment) = makeWindow(key: "test.ears.commands")
        defer { window.contentViewController = nil }

        for surface in ZPDFClosableSurface.allCases {
            // Whatever the pane's state, performing the command must end with the surface
            // visible or hidden — never with nothing having happened, which is what an
            // unrouted command looks like from the outside.
            let before = environment.isSurfaceVisible(surface)
            environment.perform(surface.command)
            let after = environment.isSurfaceVisible(surface)
            #expect(after != before, "\(surface.command.rawValue) did nothing")
            environment.perform(surface.command)
            #expect(environment.isSurfaceVisible(surface) == before,
                    "\(surface.command.rawValue) is not symmetric")
            #expect(layout.panelState.isVisible(surface) == environment.isSurfaceVisible(surface))
        }
    }

    @Test("A toolbar chip that opens a panel reports whether the panel is open")
    func theToolbarChipsReportOpenState() {
        let (layout, window, environment) = makeWindow(key: "test.ears.chips")
        defer { window.contentViewController = nil }

        // Search is the Navigator's own page, so the chip is lit exactly while that page shows.
        #expect(!environment.isPanelOpen(.find))
        environment.perform(.find)
        #expect(layout.panelState.navigatorSection == .search)
        #expect(environment.isPanelOpen(.find), "the Search chip must show that Search is open")

        environment.perform(.projectZones)
        #expect(!environment.isPanelOpen(.find), "another page means Search is no longer showing")
        #expect(environment.isPanelOpen(.projectZones))

        // A sheet panel the app tier owns: the chip reads the mode registry, which is the one
        // record of what is on screen.
        #expect(!environment.isPanelOpen(.toolLibrary))
        environment.modeRegistry.register(
            id: "toolLibrary",
            displayName: "Tool Library",
            exitRoute: ZPDFModeExitRoute(menuTitle: "Close Tool Library", performExit: {})
        )
        #expect(environment.isPanelOpen(.toolLibrary))
        environment.modeRegistry.unregister(id: "toolLibrary")
        #expect(!environment.isPanelOpen(.toolLibrary))
    }
}
