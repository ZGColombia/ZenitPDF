import AppKit
import Foundation
import Testing
@testable import ZenitPDFAppKit

/// Escape backs out of a workflow sheet through the sheet's window, not through an invisible
/// control (the LT3-01 sweep).
///
/// The chrome used to carry a zero-sized Cancel button at opacity 0 whose only job was
/// `.keyboardShortcut(.cancelAction)` — the same "invisible control relied on to act" trick as
/// the colour well that could not be clicked. `verify-hosted-hit-targets.sh` refuses that
/// pattern now, and this suite pins its replacement. No sheet is begun and no window is ordered
/// in: `NSWindow.beginSheet` hangs a headless process and nothing may reach the screen.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct WorkflowSheetEscapeTests {

    private func key(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    private var escape: NSEvent { key(53, characters: "\u{1b}") }

    private func window() -> WorkflowSheetWindow {
        let window = WorkflowSheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("Escape ends a sheet whose panel does not own Escape")
    func escapeEndsTheSheet() {
        let sheet = window()
        defer { sheet.close() }
        var ended = 0
        sheet.onEscape = { ended += 1 }
        #expect(sheet.performKeyEquivalent(with: escape))
        #expect(ended == 1)
        sheet.cancelOperation(nil)
        #expect(ended == 2, "cancelOperation reaching the window backs out too")
    }

    @Test("A panel that owns Escape keeps it: the window does not take the key")
    func panelOwnedEscapeIsLeftAlone() {
        let sheet = window()
        defer { sheet.close() }
        #expect(sheet.onEscape == nil)
        #expect(!sheet.performKeyEquivalent(with: escape))
    }

    @Test("Only a plain Escape backs out")
    func onlyPlainEscape() {
        #expect(WorkflowSheetWindow.isPlainEscape(escape))
        #expect(!WorkflowSheetWindow.isPlainEscape(key(53, characters: "\u{1b}", modifiers: .command)))
        #expect(!WorkflowSheetWindow.isPlainEscape(key(36, characters: "\r")))
        #expect(WorkflowSheetWindow.isPlainEscape(key(53, characters: "\u{1b}", modifiers: .capsLock)))
    }

    @Test("The sheet window wires Escape exactly when the panel does not own the keyboard")
    func sheetWindowWiring() {
        let closer = SheetCloser()
        let chrome = WorkflowSheet.makeSheetWindow(
            hosting: NSViewController(nibName: nil, bundle: nil).withView(),
            closer: closer, ownsKeyboardActions: false
        )
        defer { chrome.close() }
        #expect(chrome.onEscape != nil)
        let owned = WorkflowSheet.makeSheetWindow(
            hosting: NSViewController(nibName: nil, bundle: nil).withView(),
            closer: closer, ownsKeyboardActions: true
        )
        defer { owned.close() }
        #expect(owned.onEscape == nil)
    }

    @Test("No invisible cancel control is left in the chrome")
    func noInvisibleCancelButton() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZenitPDFAppKit/Workflows/WorkflowSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains(".keyboardShortcut(.cancelAction)"))
        #expect(!text.contains(".opacity(0)"))
    }
}

private extension NSViewController {
    func withView() -> NSViewController {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        return self
    }
}
