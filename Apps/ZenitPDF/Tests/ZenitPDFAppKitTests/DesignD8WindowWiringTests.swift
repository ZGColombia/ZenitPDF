import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Design round d8: the app-tier wiring behind the 2026-09-23 window — the canvas bar's Undo and
/// Redo follow the document's real undo stack, so neither is a button that does nothing.
@MainActor
@Suite(.serialized, .appTierSerialised)
struct DesignD8WindowWiringTests {

    /// A target the undo manager can register against. `set(_:)` registers its own inverse, as
    /// every real undoable edit does — without that there is nothing to redo. Selector-based, so
    /// no closure sends the target across an isolation boundary.
    @MainActor
    private final class Target: NSObject {
        private(set) var value = 0
        let undoManager: UndoManager

        init(undoManager: UndoManager) {
            self.undoManager = undoManager
        }

        @objc func restore(_ number: NSNumber) {
            set(number.intValue)
        }

        func set(_ newValue: Int) {
            undoManager.registerUndo(withTarget: self, selector: #selector(restore(_:)), object: NSNumber(value: value))
            undoManager.setActionName("Move Markup")
            value = newValue
        }
    }

    @Test("The canvas bar's Undo and Redo follow the undo stack as it changes")
    func undoFeedFollowsTheStack() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let state = CanvasUndoState()
        let feed = CanvasUndoStateFeed(undoManager: undoManager, state: state)
        #expect(state.canUndo == false, "the feed writes the current answer at once, not 'unknown'")
        #expect(state.canRedo == false)

        let target = Target(undoManager: undoManager)
        undoManager.beginUndoGrouping()
        target.set(1)
        undoManager.endUndoGrouping()
        #expect(state.canUndo == true)
        #expect(state.canRedo == false)
        #expect(state.undoActionName == "Move Markup")

        undoManager.undo()
        #expect(state.canUndo == false)
        #expect(state.canRedo == true)
        #expect(state.redoActionName == "Move Markup")
        #expect(state.undoActionName.isEmpty)

        undoManager.redo()
        #expect(state.canUndo == true)
        #expect(state.canRedo == false)
        withExtendedLifetime(feed) {}
    }

    @Test("Without an undo manager the buttons stay 'unknown' and defer to the Edit menu")
    func noUndoManagerLeavesStateUnknown() {
        let state = CanvasUndoState()
        let feed = CanvasUndoStateFeed(undoManager: nil, state: state)
        #expect(state.canUndo == nil)
        #expect(state.canRedo == nil)
        withExtendedLifetime(feed) {}
    }

    @Test("A released feed stops writing")
    func releasedFeedStops() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let state = CanvasUndoState()
        var feed: CanvasUndoStateFeed? = CanvasUndoStateFeed(undoManager: undoManager, state: state)
        #expect(feed != nil)
        feed = nil
        let target = Target(undoManager: undoManager)
        undoManager.beginUndoGrouping()
        target.set(1)
        undoManager.endUndoGrouping()
        #expect(state.canUndo == false, "a feed outlived by its tab kept writing")
    }

    // MARK: - Settings ▸ Appearance (design decision: dark by default)

    @Test("Appearance defaults to Dark, stores its choice, and survives junk")
    func appearancePreferenceStore() {
        let defaults = ZPDFInMemoryDefaults()
        #expect(ZenitAppearancePreference.load(from: defaults) == .dark)
        ZenitAppearancePreference.light.save(to: defaults)
        #expect(ZenitAppearancePreference.load(from: defaults) == .light)
        ZenitAppearancePreference.system.save(to: defaults)
        #expect(ZenitAppearancePreference.load(from: defaults) == .system)
        defaults.setPersistedData(Data("sepia".utf8), forKey: ZenitAppearancePreference.defaultsKey)
        #expect(ZenitAppearancePreference.load(from: defaults) == .dark, "an unreadable choice falls back to Dark")
        #expect(ZenitAppearancePreference.allCases.map(\.title) == ["Dark", "Light", "Match System"])
    }

    @Test("Each choice installs the right appearance; Match System installs none")
    func appearanceApplies() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        ZenitAppearancePreference.dark.apply(to: window)
        #expect(window.appearance?.name == .darkAqua)
        #expect(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        ZenitAppearancePreference.light.apply(to: window)
        #expect(window.appearance?.name == .aqua)
        #expect(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua)
        ZenitAppearancePreference.system.apply(to: window)
        #expect(window.appearance == nil)
    }

    @Test("The Settings popup shows the stored choice and applies a new one everywhere at once")
    func settingsPopUpDrivesAppearance() {
        let settings = ZenitSettingsWindowController()
        let defaults = ZPDFInMemoryDefaults()
        let target = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        target.isReleasedWhenClosed = false
        defer { target.close() }
        settings.appearanceDefaults = defaults
        settings.appearanceTargets = { [target] }
        settings.refreshAppearancePopUp()

        #expect(settings.appearancePopUp.itemTitles == ["Dark", "Light", "Match System"])
        #expect(settings.selectedAppearance == .dark, "nothing stored: Dark")
        #expect(settings.appearancePopUp.accessibilityLabel() == "Appearance")
        #expect(settings.appearancePopUp.action == #selector(ZenitSettingsWindowController.appearanceChosen(_:)))

        settings.appearancePopUp.selectItem(at: 1)
        settings.appearanceChosen(settings.appearancePopUp)
        #expect(ZenitAppearancePreference.load(from: defaults) == .light)
        #expect(target.appearance?.name == .aqua)

        settings.appearancePopUp.selectItem(at: 2)
        settings.appearanceChosen(settings.appearancePopUp)
        #expect(ZenitAppearancePreference.load(from: defaults) == .system)
        #expect(target.appearance == nil)

        // A fresh pane over the same store shows the remembered choice.
        let again = ZenitSettingsWindowController()
        again.appearanceDefaults = defaults
        again.refreshAppearancePopUp()
        #expect(again.selectedAppearance == .system)
    }

    @Test("AppKit autosaves are keyed to the real bundle, so a test process never writes them")
    func autosavesOnlyInTheAssembledBundle() {
        #expect(ZPDFShellAutosaveName.assembledBundleIdentifier == ZenitAppInfo.bundleIdentifier)
        #expect(ZPDFShellAutosaveName.appKitAutosavesEnabled == ZenitProcessDefaults.isAssembledApplication)
        #expect(!ZPDFShellAutosaveName.appKitAutosavesEnabled)
    }

    @Test("Workflow sheets inherit the window's appearance instead of forcing dark")
    func workflowSheetsFollowTheAppearanceSetting() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZenitPDFAppKit/Workflows/WorkflowSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("NSAppearance(named: .darkAqua)"))
    }

    @Test("The project window is dark chrome from its first frame")
    func projectWindowChromeIsApplied() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        ProjectWindowLayoutController.applyChrome(to: window)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
    }
}
