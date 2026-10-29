import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Review fix (ADR-0030 §5.7, r2-arcs-fix): the window's A-key claim follows the canvas's own rule.
@MainActor
@Suite("The window leaves A to the canvas whenever the canvas owns it (ADR-0030 §5.7)", .shellTierSerialised)
struct ArcReviewFixKeyClaimTests {

    /// The window's router with its letter shortcuts wired, as the application window wires them.
    /// The measurement presenter is idle — no measurement point placed — so the old claim, which
    /// read only the measurement presenter, gave A to the Area shortcut while a markup shape or a
    /// first click still resolving was in progress on the canvas, and the shape was discarded.
    @Test("A shape the canvas reports keeps A from the Area shortcut; otherwise A arms Area")
    func claimFollowsTheCanvas() {
        let store = ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "arc-claim")
        let layout = ProjectWindowLayoutController(environment: .mock(), store: store)
        let router = layout.toolSlotRouter
        var performed: [ZPDFCommandID] = []
        router.performCommand = { performed.append($0) }

        var canvasShape = true
        layout.canvasOwnsToolKey = { _, _ in canvasShape }
        #expect(!router.handleKey(characters: "a", modifiers: [], focus: .canvas), "A goes on to the canvas")
        #expect(performed.isEmpty)

        canvasShape = false
        #expect(router.handleKey(characters: "a", modifiers: [], focus: .canvas))
        #expect(performed == [.measureArea])

        // Without the application's canvas the window falls back to the measurement presenter.
        layout.canvasOwnsToolKey = nil
        #expect(router.handleKey(characters: "a", modifiers: [], focus: .canvas))
        #expect(performed == [.measureArea, .measureArea])
    }
}
