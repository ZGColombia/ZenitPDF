import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// A canvas stand-in that can hold the keyboard, so the focus rule can be driven against a real
/// first responder rather than against a boolean a test made up.
@MainActor
private final class FocusableCanvasController: NSViewController {

    /// An `NSView` that refuses first responder cannot stand in for a canvas: the whole rule
    /// under test is *"the canvas has focus"*.
    final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    override func loadView() {
        let container = FocusableView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container
    }
}

@MainActor
private func makeWindow(
    environment: ProjectShellEnvironment,
    canvas: NSViewController,
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
    // Same reason as every other shell test that builds a window: a programmatically created
    // `NSWindow` releases itself on close and over-releases the reference the test holds.
    window.isReleasedWhenClosed = false
    window.contentViewController = layout
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// The number-key tool slots and the mode cursors, at the tier that owns them.
///
/// | Area | Rule | Test |
/// |---|---|---|
/// | Slots | A bare digit arms the slot | ``aNumberKeyArmsItsSlot()`` |
/// | Slots | …only while the canvas has focus | ``aNumberKeyIsIgnoredAwayFromTheCanvas()`` |
/// | Slots | …and never while text is being edited | ``aNumberKeyIsIgnoredWhileTextIsEdited()`` |
/// | Slots | A modified digit is not a slot | ``modifiedDigitsAreNotSlots()`` |
/// | Slots | The slots are in the keyboard map's conflict audit | ``noCommandFightsASlotKey()`` |
/// | Cursor | Apply and Place get their own drawn cursor | ``theTwoModeCursorsAreDrawnAndDistinct()`` |
/// | Cursor | The status bar names the armed mode, not the stale tool | ``theStatusBarNamesTheArmedMode()`` |
@Suite("Number-key tool slots and mode cursors", .shellTierSerialised)
@MainActor
struct ToolSlotAndCursorTests {

    /// AppKit's **system** cursors do not exist until `NSApplication` does.
    ///
    /// Measured 2026-08-26 outside Swift Testing entirely, with a two-line
    /// AppKit binary:
    ///
    /// ```
    /// bare                      arrow.image.isValid=false  size=(0.0, 0.0)
    /// after NSApplication.shared arrow.image.isValid=true   size=(28.0, 40.0)
    /// ```
    ///
    /// `NSCursor.arrow` comes from the window server and is empty in a process that has never
    /// asked for the shared application; `NSCursor.openHand` is a framework resource and is
    /// valid either way, which is why only some of these assertions were ever affected. The
    /// consequence in a test process was not a clean failure: dereferencing that empty image
    /// inside Swift Testing's expression capture **traps**, taking the whole
    /// `ZPDFUIShellPackageTests` process down with `SIGTRAP` and reddening
    /// `build-ui-packages.sh` — twice in six runs of the gate, because in a full parallel run
    /// some *other* test in this file makes an `NSWindow` (which boots `NSApplication`) and
    /// whether it gets there first is a scheduling race. Run alone, the two cursor tests below
    /// failed **ten times in ten**.
    ///
    /// The two cursors Zenit *draws* — Apply and Place — were never the ones that failed. This
    /// is a dependency on process-global state the test does not own — the same class as a
    /// test that reads shared `UserDefaults`, with AppKit in its place; it is removed here by asking
    /// for the thing rather than by hoping another test asked first.
    private static let systemCursorsAreAvailable: Bool = {
        _ = NSApplication.shared
        return true
    }()

    // MARK: - The map

    @Test("Nine slots, bare digits, and the map's conflict audit is clean")
    func noCommandFightsASlotKey() {
        #expect(ToolSlotShortcut.bindings.count == 9)
        #expect(ToolSlotShortcut.binding(slot: 1)?.displayString == "1")
        #expect(ToolSlotShortcut.binding(slot: 9)?.displayString == "9")
        #expect(ToolSlotShortcut.binding(slot: 0) == nil)
        #expect(ToolSlotShortcut.binding(slot: 10) == nil)
        #expect(ToolSlotShortcut.context == .canvas)
        // The slots must honour the keyboard map. This is that rule, checked:
        // nothing reachable while the canvas has focus already claims a bare digit.
        let conflicts = ToolSlotShortcut.conflicts(with: .standard)
        #expect(conflicts.isEmpty, "\(conflicts.map(\.rawValue))")
    }

    @Test("A modified digit is not a slot, and neither is anything else on the keyboard")
    func modifiedDigitsAreNotSlots() {
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "3", modifiers: []) == 3)
        // Shift alone is no longer in this list (BH-283, fix round 2 D2): a shifted press that
        // still reports a digit only happens on a layout whose digit row needs Shift, and there it
        // is the slot. See Fix2D2ToolbarAndCommandTests.shiftedDigitRowsReachTheSlots.
        for modifiers: ZPDFModifierFlags in [[.command], [.option], [.control], [.command, .shift], [.option, .shift]] {
            #expect(
                ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "3", modifiers: modifiers) == nil,
                "\(modifiers.displayString)3 must not be a tool slot"
            )
        }
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "0", modifiers: []) == nil)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "a", modifiers: []) == nil)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "12", modifiers: []) == nil)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: nil, modifiers: []) == nil)
        #expect(ToolSlotShortcut.slot(forCharactersIgnoringModifiers: "", modifiers: []) == nil)
    }

    @Test("Only the four modelled modifiers are read, so Caps Lock cannot break a slot")
    func exoticModifierBitsAreIgnored() {
        // The number row sets the numeric-pad bit on some layouts and Caps Lock is a
        // device-independent flag of its own. Either one leaking in would make the slots stop
        // working for reasons nobody would ever guess.
        #expect(ZPDFModifierFlags([.capsLock, .numericPad, .function]).isEmpty)
        #expect(ZPDFModifierFlags([.capsLock, .command]) == [.command])
        #expect(ZPDFModifierFlags([.shift, .option]) == [.shift, .option])
    }

    // MARK: - The router

    @Test("A bare digit arms the preset in that slot of the active set")
    func aNumberKeyArmsItsSlot() throws {
        let presenter = MockToolLibraryPresenter()
        let router = ToolSlotKeyRouter(presenter: presenter)
        let second = try #require(router.preset(inSlot: 2))
        presenter.clearActivePreset()

        #expect(router.handleKey(characters: "2", modifiers: [], focus: .canvas))
        #expect(presenter.activePresetID == second.id)
    }

    @Test("A number key away from the canvas is not a tool slot")
    func aNumberKeyIsIgnoredAwayFromTheCanvas() {
        let presenter = MockToolLibraryPresenter()
        let router = ToolSlotKeyRouter(presenter: presenter)
        presenter.clearActivePreset()

        #expect(!router.handleKey(characters: "2", modifiers: [], focus: .elsewhere))
        #expect(presenter.activePresetID == nil)
    }

    @Test("A number key while text is being edited types a number")
    func aNumberKeyIsIgnoredWhileTextIsEdited() {
        // `.editingText` has the canvas as first responder *and* text being edited, which is
        // exactly the canvas's own Text markup editor. Both halves of the rule are needed and
        // this is the case that proves the second one is doing work.
        let presenter = MockToolLibraryPresenter()
        let router = ToolSlotKeyRouter(presenter: presenter)
        presenter.clearActivePreset()

        #expect(!router.handleKey(characters: "2", modifiers: [], focus: .editingText))
        #expect(presenter.activePresetID == nil)
    }

    @Test("A slot the set does not fill arms nothing and does not swallow the key")
    func anEmptySlotIsNotSwallowed() {
        let presenter = MockToolLibraryPresenter()
        let router = ToolSlotKeyRouter(presenter: presenter)
        let filled = (1...ToolSlotOrder.slotCount).compactMap { presenter.toolSlotPreset($0) }.count
        #expect(filled < ToolSlotOrder.slotCount, "the fixture must leave a slot empty to test one")
        let before = presenter.activePresetID

        #expect(!router.handleKey(characters: "9", modifiers: [], focus: .canvas))
        #expect(presenter.activePresetID == before)
    }

    // MARK: - The focus reading, against a real first responder

    @Test("The window reads focus off the real responder chain")
    func focusIsReadOffTheResponderChain() throws {
        let environment = ProjectShellEnvironment.mock()
        let canvas = FocusableCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.slots.focus")
        defer { window.close() }

        #expect(window.makeFirstResponder(canvas.view))
        #expect(layout.currentToolSlotFocus() == .canvas)

        // A text view *inside* the canvas — the Text markup editor's shape — refuses the slots
        // while still being "on the canvas".
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        canvas.view.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        let editing = layout.currentToolSlotFocus()
        #expect(editing.isEditingText)
        #expect(!editing.acceptsToolSlotKeys)
        editor.removeFromSuperview()

        // Focus outside the canvas — a panel, the filter field's host — is not the canvas.
        let elsewhere = FocusableCanvasController.FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        layout.view.addSubview(elsewhere)
        #expect(window.makeFirstResponder(elsewhere))
        #expect(!layout.currentToolSlotFocus().isCanvasFirstResponder)
        elsewhere.removeFromSuperview()
    }

    @Test("A canvas view mode covering the canvas takes the number keys with it")
    func aCanvasModeSuspendsTheSlots() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = FocusableCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.slots.mode")
        defer { window.close() }

        #expect(window.makeFirstResponder(canvas.view))
        #expect(layout.currentToolSlotFocus().acceptsToolSlotKeys)

        layout.canvasPane?.present(mode: NSViewController())
        #expect(!layout.currentToolSlotFocus().acceptsToolSlotKeys)
        layout.canvasPane?.dismissMode()
    }

    @Test("The key monitor is installed while the window is up and removed when it goes")
    func theMonitorFollowsTheWindow() {
        let environment = ProjectShellEnvironment.mock()
        let canvas = FocusableCanvasController()
        let (layout, window) = makeWindow(environment: environment, canvas: canvas, key: "t.slots.monitor")
        defer { window.close() }

        #expect(!layout.isToolSlotKeyMonitorInstalled)
        layout.viewDidAppear()
        #expect(layout.isToolSlotKeyMonitorInstalled)
        // Idempotent: a second appearance must not leave two monitors racing one key press.
        layout.viewDidAppear()
        #expect(layout.isToolSlotKeyMonitorInstalled)
        layout.viewWillDisappear()
        #expect(!layout.isToolSlotKeyMonitorInstalled)
        layout.viewWillDisappear()
        #expect(!layout.isToolSlotKeyMonitorInstalled)
    }

    // MARK: - The cursors

    @Test("Apply and Place are drawn cursors, distinct from Select and from each other")
    func theTwoModeCursorsAreDrawnAndDistinct() {
        #expect(Self.systemCursorsAreAvailable)
        let apply = CanvasCursorKind.apply.nsCursor
        let place = CanvasCursorKind.place.nsCursor
        #expect(apply !== place)
        #expect(apply !== NSCursor.arrow)
        #expect(place !== NSCursor.arrow)
        #expect(CanvasCursorKind.select.nsCursor === NSCursor.arrow)
        #expect(CanvasCursorKind.pan.nsCursor === NSCursor.openHand)

        for cursor in [apply, place] {
            #expect(cursor.image.size == NSSize(width: 24, height: 24))
            // The hot spot is the crosshair centre. A stamp dropped at the badge instead of at
            // the crosshair would be a few points off on every single placement.
            #expect(cursor.hotSpot == ZenitCanvasCursor.hotSpot)
            #expect(cursor.image.accessibilityDescription?.isEmpty == false)
            #expect(cursor.image.isValid)
        }
        #expect(apply.image.accessibilityDescription != place.image.accessibilityDescription)
    }

    @Test("Every cursor verb resolves to a cursor, and no verb is missing artwork")
    func everyVerbHasACursor() {
        #expect(Self.systemCursorsAreAvailable)
        for kind in CanvasCursorKind.allCases {
            let cursor = kind.nsCursor
            #expect(cursor.image.isValid, "\(kind) has no usable image")
        }
    }

    // MARK: - The status bar

    @Test("The status bar names the armed mode instead of the tool it disarmed")
    func theStatusBarNamesTheArmedMode() throws {
        let environment = ProjectShellEnvironment.mock()
        let library = environment.toolLibrary
        let preset = try #require(library.presets.first { $0.panel == .projectTools })
        library.setMode(.place, for: .projectTools)
        library.activatePreset(id: preset.id)

        var snapshot = environment.status.snapshot
        // What the core leaves behind in Place: the drawing families are disarmed, so the name
        // is stale and the note carries the mode's help (`AppCoreEnvironment.onArm`).
        snapshot.activeToolName = "Select"
        snapshot.activeToolNote = ToolSetMode.place.shortHelp

        let armed = try #require(library.armedModeState)
        let text = StatusBarDisplay.toolText(snapshot, armed: armed)
        #expect(text.contains(ToolSetMode.place.displayName))
        #expect(text.contains(preset.name))
        #expect(!text.hasPrefix("Select"), "the segment must not open with a tool the canvas is not in")
        #expect(StatusBarDisplay.toolAccessibilityText(snapshot, armed: armed).contains(preset.name))

        // Draw leaves every existing surface alone.
        library.setMode(.draw, for: .projectTools)
        #expect(library.armedModeState == nil)
        #expect(StatusBarDisplay.toolText(snapshot, armed: nil) == snapshot.toolIndicatorText)
    }
}
