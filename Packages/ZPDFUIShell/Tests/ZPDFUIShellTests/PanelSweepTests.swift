import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

/// Every panel, opened and closed through the command the menu raises.
///
/// The companion to `WindowToolSweepTests` in the application target, and the second half of a
/// sweep through every function in the product to check that each one really works.
///
/// Two questions per panel, and both have been answered wrongly in this product before:
///
///   * **Does it open, close and reopen?** The Compare panel once had no way back out, and the
///     Navigator and the bottom pane were impossible to restore once closed — the defect the
///     pane "ears" exist for.
///   * **Does opening it settle?** The canvas once refreshed ≈17 000 times a second
///     because a property assigned during layout was published whether or not it changed. That
///     loop was in the canvas. Nothing yet proved it is not in a panel, and a shell in a loop
///     writes its layout store on every pass — which is what is counted here.
///
/// Built on the mock presenters and an **in-memory** defaults store. `ProjectWindowLayoutStore`
/// defaults to `UserDefaults.standard` two default arguments deep, and
/// `WindowLayoutDefaultsIsolationTests` records what that cost: product code writing into the
/// user's real preferences, the same class of shared state that decided five gate outcomes here.
@MainActor
@Suite("Panel sweep", .shellTierSerialised)
struct PanelSweepTests {

    /// Counts writes, so a shell that never settles can be told from one that does.
    final class CountingDefaults: ZPDFDefaultsStoring {
        private let inner = ZPDFInMemoryDefaults()
        private(set) var writeCount = 0

        func persistedData(forKey key: String) -> Data? { inner.persistedData(forKey: key) }

        func setPersistedData(_ data: Data?, forKey key: String) {
            writeCount += 1
            inner.setPersistedData(data, forKey: key)
        }
    }

    private func makeEnvironment() -> ProjectShellEnvironment {
        let mocks = MockPresenters.makeEnvironment()
        return ProjectShellEnvironment(
            document: mocks.document,
            canvas: mocks.canvas,
            ledger: mocks.ledger,
            toolLibrary: mocks.toolLibrary,
            search: mocks.search,
            compare: mocks.compare,
            measurement: mocks.measurement,
            status: mocks.status
        )
    }

    private func makeLayout(
        _ environment: ProjectShellEnvironment
    ) -> (ProjectWindowLayoutController, CountingDefaults) {
        let defaults = CountingDefaults()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: defaults, key: "panel.sweep.layout")
        )
        environment.layoutController = layout
        _ = layout.view
        return (layout, defaults)
    }

    /// The four surfaces a person can close, and the command that toggles each.
    ///
    /// `nonisolated` so the `@Test` macro can read it while building the argument list, which it
    /// does outside the main actor.
    nonisolated static let closable: [(ZPDFClosableSurface, ZPDFCommandID)] = [
        (.navigator, .toggleNavigator),
        (.inspector, .toggleInspector),
        (.quantityLedger, .toggleQuantityLedger),
        (.history, .toggleHistory)
    ]

    // MARK: - Open, close, reopen

    @Test("Every closable panel toggles off and back on", arguments: PanelSweepTests.closable)
    func everyPanelTogglesBothWays(surface: ZPDFClosableSurface, command: ZPDFCommandID) {
        let environment = makeEnvironment()
        let (layout, _) = makeLayout(environment)

        let opened = layout.isVisible(surface)
        environment.perform(command)
        #expect(
            layout.isVisible(surface) != opened,
            "\(surface) did not change state when \(command.rawValue) was raised"
        )

        environment.perform(command)
        #expect(
            layout.isVisible(surface) == opened,
            """
            \(surface) did not come back. A pane that closes and cannot be reopened is the \
            defect the pane ears exist for, and it has been reported twice.
            """
        )
    }

    @Test("Every closable panel can be reached from a closed state, not only toggled",
          arguments: PanelSweepTests.closable)
    func everyPanelCanBeRestoredFromClosed(surface: ZPDFClosableSurface, command: ZPDFCommandID) {
        let environment = makeEnvironment()
        let (layout, _) = makeLayout(environment)

        // Close it however it starts, then ask for it by command.
        if layout.isVisible(surface) { environment.perform(command) }
        #expect(!layout.isVisible(surface), "\(surface) refused to close")

        environment.perform(command)
        #expect(layout.isVisible(surface), "\(surface) could not be restored once closed")
    }

    // MARK: - Panels that report their own open state

    /// The commands `isPanelOpen(_:)` is defined for. That method is what the toolbar chips read
    /// to light up, so a command missing from it is a chip that cannot show whether its panel is
    /// up — and pressing a lit chip again is the obvious way back.
    ///
    /// One is deliberately absent:
    ///
    ///   * `toolLibrary` is forwarded to the application tier, which presents the sheet. There is
    ///     no application tier in a shell-only harness, so it is covered by the forwarding test
    ///     below instead — asserting it "opens" here would test the harness, not the product.
    nonisolated static let statefulPanels: [ZPDFCommandID] = [
        .find, .projectZones, .scaleRegions, .toggleNavigator, .toggleInspector,
        .toggleQuantityLedger, .toggleHistory
    ]

    @Test("Raising a panel command opens it, and raising it again is the way back",
          arguments: PanelSweepTests.statefulPanels)
    func panelCommandsToggleAndReportTheirState(command: ZPDFCommandID) {
        let environment = makeEnvironment()
        let (layout, _) = makeLayout(environment)

        // Pressed the way a toolbar chip presses it. For every command but `.find` that is
        // `perform(_:)`; ⌘F itself now always reveals and focuses Search (IM-132), and the
        // chip keeps the toggle — which is what this test is about. R-073: for Search that is
        // the real chip's own action — the chip called `perform(.find)` directly, bypassing
        // the toolbar route this test used to press, and never closed Search.
        let searchChip = layout.toolbarBuilder.workspaceChip(.zenitSearch)
        #expect(command != .find || searchChip != nil, "the Search chip exists")
        let press: () -> Void = command == .find
            ? { searchChip?.action() }
            : { environment.toolbar.run(command) }

        // Start closed, whatever the stored layout wanted.
        if environment.isPanelOpen(command) { press() }
        #expect(!environment.isPanelOpen(command), "\(command.rawValue) refused to close")

        press()
        #expect(
            environment.isPanelOpen(command),
            "\(command.rawValue) did not open, or does not report that it did"
        )

        press()
        #expect(
            !environment.isPanelOpen(command),
            """
            \(command.rawValue) does not close on a second press. A chip must show the panel is \
            open, and a second press must be the way back.
            """
        )
        _ = layout
    }

    @Test("A Navigator section command opens the Navigator when it is closed",
          arguments: [ZPDFCommandID.find, .projectZones])
    func navigatorSectionsRevealTheNavigator(command: ZPDFCommandID) {
        let environment = makeEnvironment()
        let (layout, _) = makeLayout(environment)

        if layout.isVisible(.navigator) { environment.perform(.toggleNavigator) }
        #expect(!layout.isVisible(.navigator))

        environment.perform(command)
        #expect(
            layout.isVisible(.navigator),
            """
            \(command.rawValue) did not open the Navigator. Revealing a section inside a closed \
            pane is a command that appears to do nothing at all.
            """
        )
    }

    // MARK: - The settle guard

    @Test("Opening a panel does not put the shell in a write loop",
          arguments: PanelSweepTests.closable)
    func openingAPanelSettles(surface: ZPDFClosableSurface, command: ZPDFCommandID) async {
        let environment = makeEnvironment()
        let (layout, defaults) = makeLayout(environment)

        if !layout.isVisible(surface) { environment.perform(command) }
        try? await Task.sleep(for: .milliseconds(200))

        let before = defaults.writeCount
        try? await Task.sleep(for: .milliseconds(600))
        let during = defaults.writeCount - before

        #expect(during < 20, """
        Opening \(surface) left the shell writing its layout \(during) times in 0.6 idle \
        seconds. The canvas refresh loop is the precedent: an observed property assigned during layout \
        must be assigned only when its value actually changes.
        """)
    }

    // MARK: - Revision Compare

    /// CR-120 — Revision Compare was absent from the sweep.
    ///
    /// Every other panel in this file is opened, closed and reopened; Compare was not touched
    /// at all, and it is the panel that was found with no way back out of it in the first
    /// place. It is not shell-owned — the application tier presents the sheet — so the sweep
    /// needs a **registration harness**: the shell is handed the same registration the app tier
    /// makes, and the two questions are then asked of it exactly as they are of the others.
    ///
    /// There is no "old output" to paste: the case did not exist. `PanelSweepTests` ran without
    /// it, and `isPanelOpen(.revisionCompare)` and the registry's Escape route for Compare were
    /// answered by nothing in this suite. This is **missing coverage closed (CR-120), not a
    /// product regression fixed** — the routing under it passes as it stands, which is the
    /// point of running it.
    ///
    /// The harness is deliberately the *real* registration path — `modeRegistry.register` with
    /// a `ZPDFModeExitRoute`, keyed by `WorkflowPanelKind.revisionCompare.id`, which is exactly
    /// what `ProjectShellEnvironment.isPanelOpen(_:)` reads — so the sweep is testing the
    /// shell's contract with the app tier rather than a stand-in of its own.
    @MainActor
    private final class CompareSheetHarness {

        private let environment: ProjectShellEnvironment
        private(set) var isPresented = false
        private(set) var closeCount = 0

        init(_ environment: ProjectShellEnvironment) {
            self.environment = environment
            environment.externalCommandHandler = { [weak self] command in
                guard command == .revisionCompare else { return }
                self?.toggle()
            }
        }

        /// What the application tier does when the Compare command arrives.
        func toggle() {
            if isPresented { close() } else { present() }
        }

        func present() {
            guard !isPresented else { return }
            isPresented = true
            environment.modeRegistry.register(
                id: WorkflowPanelKind.revisionCompare.id,
                displayName: WorkflowPanelKind.revisionCompare.displayName,
                exitRoute: ZPDFModeExitRoute(
                    menuTitle: "Close Revision Compare",
                    performExit: { [weak self] in self?.close() }
                )
            )
        }

        func close() {
            guard isPresented else { return }
            isPresented = false
            closeCount += 1
            environment.modeRegistry.unregister(id: WorkflowPanelKind.revisionCompare.id)
        }
    }

    @Test("Revision Compare opens, reports itself open, and closes from every route")
    func revisionCompareIsSwept() {
        let environment = makeEnvironment()
        let (layout, _) = makeLayout(environment)
        let sheet = CompareSheetHarness(environment)

        #expect(!environment.isPanelOpen(.revisionCompare), "nothing is up yet")

        // 1. The command opens it, and the chip can see that it is open.
        environment.perform(.revisionCompare)
        #expect(sheet.isPresented)
        #expect(environment.isPanelOpen(.revisionCompare))

        // 2. Pressing again is the way back.
        environment.perform(.revisionCompare)
        #expect(!sheet.isPresented)
        #expect(!environment.isPanelOpen(.revisionCompare))

        // 3. …and it reopens. A panel that closes and cannot come back is the defect found
        //    on this very panel.
        environment.perform(.revisionCompare)
        #expect(environment.isPanelOpen(.revisionCompare))

        // 4. Escape backs out of it, through the registry rather than the chip.
        environment.perform(.cancelTool)
        #expect(!sheet.isPresented, "Escape did not reach the registered exit route")
        #expect(!environment.isPanelOpen(.revisionCompare))
        #expect(environment.modeRegistry.modes.isEmpty)
        _ = layout
    }

    @Test("Revision Compare leaves no exit route behind once it is closed")
    func revisionCompareLeavesNoStaleRoute() {
        let environment = makeEnvironment()
        let (_, _) = makeLayout(environment)
        let sheet = CompareSheetHarness(environment)

        sheet.present()
        #expect(environment.modeRegistry.exitRoute(for: WorkflowPanelKind.revisionCompare.id) != nil)

        // Closed by its own control, not by Escape — the route must go with it, or every later
        // Escape hits a no-op that stays topmost for ever (CR-98's shape).
        sheet.close()
        #expect(environment.modeRegistry.exitRoute(for: WorkflowPanelKind.revisionCompare.id) == nil)
        #expect(!environment.modeRegistry.hasActiveMode)

        // Escape now has nothing to back out of and must not re-close anything.
        environment.perform(.cancelTool)
        #expect(sheet.closeCount == 1)
    }

    @Test("Opening Revision Compare does not put the shell in a write loop")
    func revisionCompareSettles() async {
        let environment = makeEnvironment()
        let (_, defaults) = makeLayout(environment)
        let sheet = CompareSheetHarness(environment)
        sheet.present()
        try? await Task.sleep(for: .milliseconds(200))

        let before = defaults.writeCount
        try? await Task.sleep(for: .milliseconds(600))
        let during = defaults.writeCount - before

        #expect(during < 20, """
        Opening Revision Compare left the shell writing its layout \(during) times in 0.6 idle \
        seconds. The canvas refresh loop is the precedent.
        """)
    }

    @Test("Tool Library is forwarded to the application tier, which owns the sheet")
    func toolLibraryIsForwarded() {
        let environment = makeEnvironment()
        let (layout, _) = makeLayout(environment)
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }

        environment.perform(.toolLibrary)
        #expect(
            forwarded == [.toolLibrary],
            """
            The shell swallowed Tool Library. It does not own that sheet — the application tier \
            presents it — so dropping the forward is a chip that does nothing at all.
            """
        )
        _ = layout
    }
}
