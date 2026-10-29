import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows

// CR-202: every workflow panel's rendered close control closes the panel.
//
// `DismissibilityTests.everyPanelViewIsConstructibleWithClose` used to call its own close closure
// and assert that the closure ran — green against a view that ignored `onClose`. Its replacement
// in ZPDFUIWorkflowsTests renders each panel off screen and proves the Escape route; it cannot
// prove the click, because inside `xctest` (current-SDK stamp) SwiftUI takes no synthetic mouse
// event in a window that is never ordered in — measured 2026-10-27: a direct `mouseDown`/`mouseUp`
// to the hit view, `NSWindow.sendEvent` and `NSApplication.sendEvent` all left a known-good close
// button's action unrun. In this binary, stamped like the shipped app, SwiftUI takes the click the
// way it takes the Inspector's, so the click half lives here.
//
// For each panel: render it in a window that is never ordered in, find the close button through
// the marker behind it (`WorkflowPanelCloseButton.markerIdentifier`), click its centre through
// hit-testing, and require exactly one call of the panel's `onClose`. Controls first, so a pass
// means something: a close button whose action does nothing must close nothing, and a click on
// empty space beside it must close nothing.

#if DEBUG || ZPDF_MOCKS

@MainActor
private final class CloseCounter {
    private(set) var count = 0
    func close() { count += 1 }
}

@MainActor
private func hostPanel(_ view: some View, size: NSSize) -> NSWindow {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -12_000, y: -12_000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    spin(0.3)
    return window
}

/// Renders the panel around a counting close action, clicks the one marked control, and returns
/// (closes, markers found).
@MainActor
private func clickClose(
    marker: String,
    size: NSSize,
    _ make: (@escaping () -> Void) -> AnyView
) -> (closes: Int, markers: Int) {
    let counter = CloseCounter()
    let window = hostPanel(make { counter.close() }, size: size)
    defer { window.close() }
    let frames = allViews(window.contentView!)
        .filter { $0.identifier?.rawValue == marker && !$0.isHiddenOrHasHiddenAncestor }
        .map { $0.convert($0.bounds, to: nil) }
    guard frames.count == 1, let frame = frames.first else { return (counter.count, frames.count) }
    click(NSPoint(x: frame.midX, y: frame.midY), in: window)
    return (counter.count, frames.count)
}

@MainActor
func panelCloseScenario() {
    print("\n[CR-202] each workflow panel's rendered close control closes it")
    let marker = WorkflowPanelCloseButton.markerIdentifier

    // Controls.
    let strip = NSSize(width: 240, height: 80)
    func probeButton(_ action: @escaping () -> Void) -> AnyView {
        AnyView(HStack { Spacer(); WorkflowPanelCloseButton(panelName: "Probe", action: action) }.padding(8))
    }
    let working = clickClose(marker: marker, size: strip) { probeButton($0) }
    check(working.markers == 1 && working.closes == 1, "[CR-202 control] a click on a close button runs its action once (markers \(working.markers), closes \(working.closes))")
    let ignored = clickClose(marker: marker, size: strip) { _ in probeButton({}) }
    check(ignored.markers == 1 && ignored.closes == 0, "[CR-202 control] a close button that ignores its action closes nothing when clicked (closes \(ignored.closes))")
    do {
        let counter = CloseCounter()
        let window = hostPanel(probeButton { counter.close() }, size: strip)
        click(NSPoint(x: 12, y: strip.height / 2), in: window)
        window.close()
        check(counter.count == 0, "[CR-202 control] a click on empty space beside the button closes nothing (closes \(counter.count))")
    }

    // The panels.
    let env = MockPresenters.makeEnvironment()
    let panels: [(name: String, size: NSSize, make: (@escaping () -> Void) -> AnyView)] = [
        ("Tool Library", NSSize(width: 380, height: 640), { close in
            AnyView(ToolLibraryPanelView(
                presenter: env.toolLibrary,
                model: ToolLibraryEditingModel(presets: env.project.presets),
                onClose: close
            ))
        }),
        ("Read Text from Scanned Pages (header)", NSSize(width: 560, height: 720), { close in
            AnyView(OCRRunSheet(model: OCRRunModel(pages: env.project.pages), onClose: close))
        }),
        ("Revision Compare", NSSize(width: 1_100, height: 760), { close in
            AnyView(RevisionCompareView(presenter: env.compare, model: RevisionCompareModel(), onClose: close) { _ in Color.clear })
        }),
        ("Revision Overlay", NSSize(width: 1_100, height: 760), { close in
            AnyView(RevisionOverlayView(model: RevisionOverlayModel(revisions: env.project.revisions), onClose: close) { Color.clear })
        }),
        ("Split Canvas", NSSize(width: 900, height: 56), { close in
            AnyView(SplitCanvasControls(controller: SplitCanvasController(layout: .twoColumns), onClose: close))
        })
    ]
    for panel in panels {
        let result = clickClose(marker: marker, size: panel.size, panel.make)
        check(result.markers == 1, "[CR-202] \(panel.name) renders exactly one close button (found \(result.markers))")
        check(result.closes == 1, "[CR-202] a click on \(panel.name)'s rendered close button runs its onClose once (ran \(result.closes))")
    }

    let footer = clickClose(marker: OCRRunSheet.footerCloseMarkerIdentifier, size: NSSize(width: 560, height: 720)) { close in
        AnyView(OCRRunSheet(model: OCRRunModel(pages: env.project.pages), onClose: close))
    }
    check(footer.markers == 1, "[CR-202] the OCR sheet renders one footer Close button (found \(footer.markers))")
    check(footer.closes == 1, "[CR-202] a click on the OCR footer Close button runs its onClose once (ran \(footer.closes))")
}

#endif
