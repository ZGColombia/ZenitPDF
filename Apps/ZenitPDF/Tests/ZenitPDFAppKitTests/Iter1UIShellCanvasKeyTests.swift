import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// K-02, iteration-1 re-fix: the window's tool-key router with the claim the shipping
/// `ProjectWindowController` wires (`canvasOwnsToolKey` → the canvas's `ownsToolKey`), against the
/// shipping canvas. A key the router leaves alone is then delivered to the canvas's own `keyDown`,
/// as AppKit delivers a key the local monitor did not consume. No window is ordered front.
@MainActor
@Suite(.appTierSerialised)
struct Iter1UIShellCanvasKeyTests {

    /// Every letter tool key but A (A has its own canvas meaning, covered by ArcReviewFixAppTests),
    /// plus a number slot, with the virtual key code AppKit reports for it.
    private static let toolKeys: [(characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16)] = [
        ("p", [], 35), ("m", [], 46), ("s", [], 1), ("z", [], 6), ("t", [], 17), ("c", [], 8),
        ("r", [], 15), ("x", [], 7), ("C", [.shift], 8), ("2", [], 19),
    ]

    private static func keyDown(_ characters: String, _ modifiers: NSEvent.ModifierFlags, _ keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    /// Presses one key the way the application does: the window's router first, then — when the
    /// router did not take it — the canvas's `keyDown`. Returns whether the router took it.
    private static func press(
        _ characters: String, _ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16,
        router: ToolSlotKeyRouter, canvas: PDFCanvasViewController
    ) throws -> Bool {
        if router.handleKey(characters: characters, modifiers: ZPDFModifierFlags(modifiers), focus: .canvas) {
            return true
        }
        canvas.pageViewForTesting.keyDown(with: try keyDown(characters, modifiers, keyCode))
        return false
    }

    /// Old output (K-02 fix, before this re-fix): `handleKey("p", …)` → `true`, the toolbar lit
    /// Pan — and M, S, Z, T, C, R, X, ⇧C and slot 2 armed their tools — while `isCalibrating`
    /// stayed `true` and the next click still went to the pick.
    @Test("K-02: during a two-point pick no tool key changes the toolbar, and the canvas says why")
    func noToolSwitchDuringAPick() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1r Pick Keys.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        let layout = try #require(harness.controller.layoutController(for: harness.document))
        let router = layout.toolSlotRouter
        #expect(layout.canvasOwnsToolKey != nil, "the shipping window wires the canvas's rule")

        harness.controller.beginCalibration(for: harness.document)
        #expect(canvas.isCalibrating)
        let before = harness.shell.toolbar.activeSelection
        let preset = harness.shell.toolLibrary.activePresetID

        for key in Self.toolKeys {
            #expect(!(try Self.press(key.characters, key.modifiers, keyCode: key.keyCode, router: router, canvas: canvas)),
                    "\(key.characters) was taken as a tool shortcut during the pick")
            #expect(harness.shell.toolbar.activeSelection == before, "\(key.characters) changed the tool")
            #expect(harness.shell.toolLibrary.activePresetID == preset, "\(key.characters) armed a preset")
            #expect(canvas.isCalibrating)
            #expect(canvas.armedMode == .calibrate, "\(key.characters): the armed mode left the pick")
        }
        #expect(await AppTestSupport.wait {
            harness.core.status.snapshot.activeToolNote == PDFCanvasViewController.twoPointPickToolNote
        }, "\(String(describing: harness.core.status.snapshot.activeToolNote))")

        // The pick ends: the letters are tool shortcuts again.
        canvas.endCalibration()
        #expect(router.handleKey(characters: "p", modifiers: [], focus: .canvas))
        #expect(harness.shell.toolbar.activeTool == .pan)
    }

    /// Old output (K-02 fix, before this re-fix): typing "25" then "c" mid-Length gave
    /// `handleKey("c", …)` → `true`, Callout armed, and the canvas's tool switch dropped the placed
    /// point (`placedPoints` 1 → 0) and the entry; "12ft" lost the shape the same way on "t".
    @Test("K-02: mid-shape with a typed length, C and T neither switch tools nor drop the shape")
    func typedLengthKeepsItsShape() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1r Typed Keys.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        harness.shell.toolbar.activateMeasurement(.length)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .length })
        let router = try #require(harness.controller.layoutController(for: harness.document)).toolSlotRouter
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        let before = harness.shell.toolbar.activeSelection

        // "25": the digits go on to the canvas and start the typed length.
        #expect(!(try Self.press("2", keyCode: 19, router: router, canvas: canvas)))
        #expect(!(try Self.press("5", keyCode: 23, router: router, canvas: canvas)))
        #expect(canvas.typedEntry == "25")

        for (letter, code) in [("c", UInt16(8)), ("t", UInt16(17))] {
            #expect(!(try Self.press(letter, keyCode: code, router: router, canvas: canvas)),
                    "\(letter) was taken as a tool shortcut mid-shape")
            canvas.refresh()
            #expect(harness.shell.toolbar.activeSelection == before, "\(letter) changed the tool")
            #expect(core.measurement.activeKind == .length)
            #expect(core.measurement.placedPoints.count == 1, "\(letter) dropped the placed point")
            #expect(canvas.typedEntry == "25", "\(letter) dropped the typed entry")
        }
        #expect(await AppTestSupport.wait {
            core.status.snapshot.activeToolNote?.contains("before choosing another tool") == true
        }, "\(String(describing: core.status.snapshot.activeToolNote))")

        // With the entry cleared the shape still holds the letters: a switch would discard it.
        #expect(canvas.handle(key: .escape))
        #expect(canvas.typedEntry.isEmpty)
        #expect(!(try Self.press("c", keyCode: 8, router: router, canvas: canvas)))
        canvas.refresh()
        #expect(core.measurement.placedPoints.count == 1)
        #expect(harness.shell.toolbar.activeSelection == before)
    }

    /// The boundary of the rule: a count group is committed by a tool switch (2026-08-26),
    /// so mid-count a letter still switches tools — and the marks are kept, not lost.
    @Test("K-02: mid-count a letter still switches tools, and the count is committed")
    func countGroupStillSwitches() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1r Count Keys.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        harness.shell.toolbar.activateMeasurement(.count)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .count })
        let router = try #require(harness.controller.layoutController(for: harness.document)).toolSlotRouter
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 200, y: 200))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })

        #expect(canvas.ownsToolKey(characters: "a", modifiers: []), "A, the arc key, stays with the count")
        #expect(!canvas.ownsToolKey(characters: "p", modifiers: []))
        #expect(router.handleKey(characters: "p", modifiers: [], focus: .canvas))
        #expect(harness.shell.toolbar.activeTool == .pan)
        canvas.refresh()
        var committed = 0
        for _ in 0..<150 {
            committed = await core.session.orderedMarkups.filter { $0.tool == .count }.count
            if committed == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(committed == 1, "the count group was committed by the switch")
    }
}
