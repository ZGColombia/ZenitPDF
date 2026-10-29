import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// A window opened over a stored layout whose ledger was in its own window.
///
/// Old behaviour (crash reports, 2026-09-23/24): every launch for a person who had quit
/// with the ledger detached crashed in the display cycle, "index 1 beyond bounds [0 .. 0]" in
/// `-[NSSplitViewController splitView:shouldHideDividerAtIndex:]`.
@MainActor
@Suite("Launch with a detached ledger", .shellTierSerialised)
struct LaunchWithDetachedLedgerTests {

    @Test("A stored detached ledger opens the window and puts the ledger in its own window")
    func launchWithDetachedLedger() async throws {
        let defaults = ZPDFInMemoryDefaults()
        let store = ProjectWindowLayoutStore(defaults: defaults, key: "launch-detached")
        var state = ProjectWindowLayoutState()
        state.isLedgerDetached = true
        state.isInspectorCollapsed = true
        _ = store.save(state)

        let layout = ProjectWindowLayoutController(environment: .mock(), store: store)
        var presented = false
        layout.presentDetachedLedgerWindow = { _ in presented = true }
        layout.detachedLedgerAutosaveName = ""
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_728, height: 1_084),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = layout
        layout.configure(window: window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1_728, height: 1_084), display: false)
        window.layoutIfNeeded()
        layout.view.layoutSubtreeIfNeeded()
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
        }
        #expect(presented, "the ledger is presented in its own window")
        #expect(layout.isQuantityLedgerDetached)
    }
}
