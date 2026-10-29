import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The Quantity Ledger in its own window: out, back, and — the missing settle guard — quiet
/// while it is out.
///
/// `PanelSweepTests` proves every docked panel opens, closes and settles. Detaching is the one
/// layout move that panel sweep cannot reach: it removes the split item, reparents the ledger's
/// view controller into an `NSWindow`, and re-docks it later. The canvas refresh loop
/// lived in exactly this kind of transition code, and nothing yet proved the detached state
/// settles.
///
/// The window is real and **never ordered on screen**: the presentation seam is injected as a
/// counter, and the frame-autosave name as `""`, so this suite can run while someone works —
/// no window, no sheet, no write into the user's real preferences.
@MainActor
@Suite("Detached ledger", .shellTierSerialised)
struct DetachedLedgerTests {

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
    ) -> (ProjectWindowLayoutController, PanelSweepTests.CountingDefaults, presented: () -> Int) {
        let defaults = PanelSweepTests.CountingDefaults()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: defaults, key: "detached.ledger.layout")
        )
        environment.layoutController = layout
        var presentations = 0
        layout.presentDetachedLedgerWindow = { _ in presentations += 1 }
        layout.detachedLedgerAutosaveName = ""
        _ = layout.view
        return (layout, defaults, { presentations })
    }

    @Test("Detach moves the ledger to its own window and re-dock brings it home")
    func detachAndReattachRoundTrip() {
        let environment = makeEnvironment()
        let (layout, _, presented) = makeLayout(environment)

        #expect(!layout.isQuantityLedgerDetached)
        layout.detachQuantityLedger()
        #expect(layout.isQuantityLedgerDetached, "detach did not take")
        #expect(presented() == 1, "the window was never handed to the presentation seam")

        layout.attachQuantityLedger()
        #expect(!layout.isQuantityLedgerDetached, "the ledger did not come home")
        #expect(layout.isVisible(.quantityLedger), "re-docking must leave the ledger visible")

        // And out again: the round trip must not be single-use.
        layout.detachQuantityLedger()
        #expect(layout.isQuantityLedgerDetached)
        #expect(presented() == 2)
    }

    @Test("Closing the detached window re-docks the ledger instead of losing it")
    func closingTheWindowReDocks() {
        let environment = makeEnvironment()
        let (layout, _, _) = makeLayout(environment)

        layout.detachQuantityLedger()
        #expect(layout.isQuantityLedgerDetached)

        // The user clicks the close button: AppKit closes the window, `windowWillClose` fires,
        // and the controller must dock the ledger rather than strand it in a dead window.
        // A pane that closes and cannot be reopened is the defect the ears exist for.
        layout.detachedLedgerControllerForTesting?.window?.close()
        #expect(!layout.isQuantityLedgerDetached, "closing the window stranded the ledger")
        #expect(layout.isVisible(.quantityLedger), "the ledger never came back into the shell")
    }

    @Test("A detached ledger settles — no write loop while it sits in its own window")
    func detachedLedgerSettles() async {
        let environment = makeEnvironment()
        let (layout, defaults, _) = makeLayout(environment)

        layout.detachQuantityLedger()
        try? await Task.sleep(for: .milliseconds(200))

        let before = defaults.writeCount
        try? await Task.sleep(for: .milliseconds(600))
        let during = defaults.writeCount - before

        #expect(during < 20, """
        A detached ledger left the shell writing its layout \(during) times in 0.6 idle \
        seconds. The canvas refresh loop is the precedent: an observed property assigned during layout \
        must be assigned only when its value actually changes.
        """)
    }
}
