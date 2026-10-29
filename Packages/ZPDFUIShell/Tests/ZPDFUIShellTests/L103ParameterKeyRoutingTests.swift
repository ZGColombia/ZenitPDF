import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

// L-103, the remainder: the auto-route of digits into the empty field from a focused canvas
// was not observed in the running app. The app-tier test
// (`Live8CanvasTests.digitsAtTheCanvasGoIntoTheAskedValue`) calls `ToolSlotKeyRouter.handleKey`
// itself, so the one link no test crossed was the window's key monitor — the path a real key
// takes. These tests send a real `keyDown` through `NSApplication.sendEvent(_:)`, which is where
// AppKit runs local event monitors, with the shell's own options strip and canvas pane in a window
// that is laid out and never ordered in.
//
// They also pin the precedence that most plausibly explains the miss: with the armed tool
// asking for its value, a *click* on the canvas to give it the keyboard places the shape's first
// point, and from then on a digit is the canvas's typed length (NL-MEASURE-18), not the field's
// value. The field takes digits only while no point is placed.

/// A canvas stand-in that can hold the keyboard.
@MainActor
private final class L103FocusableCanvas: NSViewController {
    final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
        private(set) var keyDowns: [String] = []
        override func keyDown(with event: NSEvent) { keyDowns.append(event.charactersIgnoringModifiers ?? "") }
    }

    override func loadView() {
        let container = FocusableView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
    }
}

@MainActor
@Suite("L-103 at the shell: digits at a focused canvas", .shellTierSerialised)
struct L103ParameterKeyRoutingTests {

    private struct Rig {
        let environment: ProjectShellEnvironment
        let layout: ProjectWindowLayoutController
        let window: NSWindow
        let canvas: L103FocusableCanvas.FocusableView
    }

    private func makeRig(key: String) throws -> Rig {
        let environment = ProjectShellEnvironment.mock()
        let canvas = L103FocusableCanvas()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key),
            canvasProvider: { canvas }
        )
        layout.presentDetachedLedgerWindow = { _ in }
        layout.detachedLedgerAutosaveName = ""
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = layout
        window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
        window.layoutIfNeeded()
        layout.view.layoutSubtreeIfNeeded()
        let view = try #require(canvas.view as? L103FocusableCanvas.FocusableView)
        return Rig(environment: environment, layout: layout, window: window, canvas: view)
    }

    private static func spin(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    @Test("A digit at the canvas, through the window's key monitor, goes into the empty value field and arms no preset")
    func digitThroughTheMonitorFillsTheAskedValue() throws {
        let rig = try makeRig(key: "l103.monitor")
        defer { rig.layout.removeToolSlotKeyMonitor(); rig.window.close() }
        let environment = rig.environment
        let measurement = environment.measurement
        let router = rig.layout.toolSlotRouter
        try #require(router.preset(inSlot: 2) != nil, "slot 2 holds a preset the digit could wrongly arm")

        environment.toolbar.activateMeasurement(.slope)
        Self.spin(0.2)
        rig.layout.view.layoutSubtreeIfNeeded()
        #expect(measurement.activeKind == .slope)
        #expect(measurement.isMissingRequiredParameter, "the slope tool is asking for its value")
        #expect(measurement.placedPoints.isEmpty)
        let box = try #require(rig.layout.measurementParameterBox, "the options strip shows the slope field")
        #expect(!box.isEditing)

        rig.layout.installToolSlotKeyMonitor()
        #expect(rig.window.makeFirstResponder(rig.canvas))
        #expect(rig.layout.currentToolSlotFocus() == .canvas)
        let presetBefore = environment.toolLibrary.activePresetID

        // "2" — through NSApplication.sendEvent, so through the local monitor the window installed.
        NSApplication.shared.sendEvent(try Self.key("2", keyCode: 19, in: rig.window))
        Self.spin()
        #expect(rig.canvas.keyDowns.isEmpty, "the monitor spent the key; the canvas never saw it")
        #expect(box.isEditing, "the field took the keyboard")
        #expect(rig.window.firstResponder is NSText, "the field editor is first responder")
        #expect(measurement.parameterText == "2", "the slope reads \(measurement.parameterText)")
        #expect(environment.toolLibrary.activePresetID == presetBefore, "no preset was armed")
        #expect(measurement.activeKind == .slope)

        // The field holds the keyboard now: the next digit is the field's own, through the window.
        rig.window.sendEvent(try Self.key("0", keyCode: 29, in: rig.window))
        Self.spin()
        #expect(measurement.parameterText == "20", "the slope reads \(measurement.parameterText)")
        #expect(!measurement.isMissingRequiredParameter)
        #expect(environment.toolLibrary.activePresetID == presetBefore)
    }

    @Test("Once a point is placed the digit is the canvas's typed length: the field is left alone and no preset is armed")
    func digitMidShapeIsTheCanvasTypedLength() throws {
        let rig = try makeRig(key: "l103.midshape")
        defer { rig.layout.removeToolSlotKeyMonitor(); rig.window.close() }
        let environment = rig.environment
        let measurement = environment.measurement

        environment.toolbar.activateMeasurement(.slope)
        Self.spin(0.2)
        rig.layout.view.layoutSubtreeIfNeeded()
        // What a click on the canvas does with the slope tool armed: it places the first point.
        measurement.placePoint(PDFPointValue(x: 40, y: 40))
        #expect(measurement.isMissingRequiredParameter)
        let box = try #require(rig.layout.measurementParameterBox)

        rig.layout.installToolSlotKeyMonitor()
        #expect(rig.window.makeFirstResponder(rig.canvas))
        let presetBefore = environment.toolLibrary.activePresetID

        NSApplication.shared.sendEvent(try Self.key("2", keyCode: 19, in: rig.window))
        Self.spin()
        // Not spent by the monitor: the window hands it on, and the canvas (the first responder)
        // gets it — where the application's canvas starts a typed length.
        #expect(!box.isEditing, "the field did not take the keyboard mid-shape")
        #expect(measurement.parameterText.isEmpty)
        #expect(environment.toolLibrary.activePresetID == presetBefore, "no preset was armed")
        rig.window.sendEvent(try Self.key("2", keyCode: 19, in: rig.window))
        #expect(rig.canvas.keyDowns == ["2"], "the canvas received the digit: \(rig.canvas.keyDowns)")
    }

    @Test("Over a filled value the digit is the slot, through the monitor, as before")
    func digitOverAFilledValueArmsTheSlot() throws {
        let rig = try makeRig(key: "l103.filled")
        defer { rig.layout.removeToolSlotKeyMonitor(); rig.window.close() }
        let environment = rig.environment
        let measurement = environment.measurement
        let slot2 = try #require(rig.layout.toolSlotRouter.preset(inSlot: 2))

        environment.toolbar.activateMeasurement(.slope)
        Self.spin(0.2)
        measurement.setParameterText("12")
        #expect(!measurement.isMissingRequiredParameter)
        rig.layout.installToolSlotKeyMonitor()
        #expect(rig.window.makeFirstResponder(rig.canvas))

        NSApplication.shared.sendEvent(try Self.key("2", keyCode: 19, in: rig.window))
        Self.spin()
        #expect(environment.toolLibrary.activePresetID == slot2.id, "slot 2 armed")
        #expect(rig.layout.measurementParameterBox?.isEditing != true)
        #expect(rig.canvas.keyDowns.isEmpty, "the monitor spent the key as the slot")
    }

    @Test("A key for another window is not this window's to route")
    func otherWindowsKeysAreIgnored() throws {
        let rig = try makeRig(key: "l103.other")
        defer { rig.layout.removeToolSlotKeyMonitor(); rig.window.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        rig.environment.toolbar.activateMeasurement(.slope)
        Self.spin(0.2)
        rig.layout.installToolSlotKeyMonitor()
        #expect(rig.window.makeFirstResponder(rig.canvas))

        NSApplication.shared.sendEvent(try Self.key("2", keyCode: 19, in: other))
        Self.spin()
        #expect(rig.layout.measurementParameterBox?.isEditing != true)
        #expect(rig.environment.measurement.parameterText.isEmpty)
    }
}
