import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// CR-202: the rendered close controls, not the test's own closure.
///
/// `PanelCloseTests.everyPanelViewIsConstructibleWithClose` used to construct each panel view,
/// call the *test's* `close()` closure and assert that the closure ran — a tautology that passed
/// against a view which ignored `onClose` entirely. The finding was left open because proving
/// the real controls needs a rendered view and "no window in a test" forbids putting one on the
/// screen. This harness renders the view without putting anything on the screen: it is hosted
/// in an `NSHostingView` inside a borderless window at (-12 000, -12 000) that is **never ordered
/// in** — nothing is shown, nothing takes focus, nothing activates.
///
/// Two halves, in two binaries:
///
/// - **Escape, here.** The key goes through the window's key-equivalent path, where SwiftUI's
///   `.keyboardShortcut(.cancelAction)` is matched, so a pass means the rendered panel's cancel
///   control ran the panel's `onClose`.
/// - **The click, in `zpdf-hit-probe`** (`CR202CloseScenarios.swift`, run by
///   `Scripts/verify-hosted-hit-targets.sh`). Inside `xctest` SwiftUI takes no synthetic mouse
///   event in a window that is never ordered in — measured 2026-10-27 on a known-good close
///   button: a direct `mouseDown`/`mouseUp` to the view `hitTest` finds, `NSWindow.sendEvent` and
///   `NSApplication.sendEvent` all left its action unrun, in a window claiming to be visible and
///   key as well. The probe is stamped like the shipped app, where the same delivery reaches
///   SwiftUI's buttons; it finds each close button through the ``ZPDFViewMarker`` behind it
///   (``WorkflowPanelCloseButton/markerIdentifier``) and clicks it there. The marker check below
///   is the xctest half of that: each panel renders exactly one close button for the probe to find.
@MainActor
enum RenderedPanel {

    /// A counter a close action can bump; a class so a SwiftUI closure can capture it.
    final class Closes {
        private(set) var count = 0
        func close() { count += 1 }
    }

    /// Hosts `view` off screen. The caller closes the returned window.
    static func host(_ view: some View, size: NSSize) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -12_000, y: -12_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        spin(0.3)
        return window
    }

    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    /// The window-coordinate frames of every marker with `identifier`.
    static func markerFrames(_ identifier: String, in window: NSWindow) -> [NSRect] {
        guard let content = window.contentView else { return [] }
        window.layoutIfNeeded()
        return allViews(content)
            .filter { $0.identifier?.rawValue == identifier && !$0.isHiddenOrHasHiddenAncestor }
            .map { $0.convert($0.bounds, to: nil) }
    }

    /// Escape, through the window's key-equivalent path — where a `.cancelAction` shortcut is
    /// matched. Returns whether anything in the window took it.
    @discardableResult
    static func pressEscape(in window: NSWindow) -> Bool {
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return false }
        let handled = window.performKeyEquivalent(with: escape)
        spin(0.1)
        return handled
    }

    /// How many close buttons a fresh rendering of the panel draws under `identifier`.
    static func markerCount(_ identifier: String, size: NSSize, _ make: (@escaping () -> Void) -> AnyView) -> Int {
        let window = host(make {}, size: size)
        defer { window.close() }
        return markerFrames(identifier, in: window).count
    }

    /// How many times a fresh rendering of the panel closed on Escape.
    static func closesOnEscape(size: NSSize, _ make: (@escaping () -> Void) -> AnyView) -> Int {
        let closes = Closes()
        let window = host(make { closes.close() }, size: size)
        defer { window.close() }
        pressEscape(in: window)
        return closes.count
    }
}

/// The harness itself, against controls whose behaviour is known — so a pass elsewhere means
/// the panel's control did the closing, not the harness.
@Suite("CR-202 rendered-control harness", .workflowsTierSerialised)
@MainActor
struct CR202HarnessTests {

    private static let size = NSSize(width: 240, height: 80)

    private static func closeButton(escapeRouted: Bool, action: @escaping () -> Void) -> AnyView {
        AnyView(HStack {
            Spacer()
            WorkflowPanelCloseButton(panelName: "Probe", isEscapeRouted: escapeRouted, action: action)
        }.padding(8))
    }

    @Test("The close button is found where it is drawn, once")
    func markerIsFound() {
        #expect(RenderedPanel.markerCount(WorkflowPanelCloseButton.markerIdentifier, size: Self.size) {
            Self.closeButton(escapeRouted: true, action: $0)
        } == 1)
    }

    @Test("A close button that ignores its action is caught: Escape lands and nothing closes")
    func ignoredActionIsCaught() {
        // The shape of the defect CR-202 says the old test could not see: a view that renders
        // its close control but never calls `onClose`.
        let ignoredEscape = RenderedPanel.closesOnEscape(size: Self.size) { _ in
            Self.closeButton(escapeRouted: true, action: {})
        }
        #expect(ignoredEscape == 0)
    }

    @Test("Escape reaches a cancel-routed close button, and only a cancel-routed one")
    func escapeFollowsTheCancelRoute() {
        #expect(RenderedPanel.closesOnEscape(size: Self.size) { Self.closeButton(escapeRouted: true, action: $0) } == 1)
        #expect(RenderedPanel.closesOnEscape(size: Self.size) { Self.closeButton(escapeRouted: false, action: $0) } == 0)
    }
}
