import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// I-35: the snap chip's 0.09 s fade re-rendered the whole loupe as fast as the run loop turned
/// (the test window is never on screen, so nothing paced it), about 19 lens layouts per pointer
/// frame. The chip now animates in a native layer of its own. Kept in the application tier: it
/// needs a window, and only a serialised tier may touch AppKit's process globals.
@Suite("Loupe snap-chip animation (I-35)", .appTierSerialised)
@MainActor
struct MeasurementLoupeAnimationTests {
    private final class LensHost: NSHostingView<AnyView> {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    private func lens(_ snap: SnapFeedbackSnapshot?) -> AnyView {
        AnyView(MeasurementLoupe(pagePoint: PDFPointValue(x: 120, y: 230), snapCandidate: snap) {
            Color.white
        })
    }

    @Test("Snap transitions stay inside the chip host instead of repeatedly laying out the lens")
    func animationDoesNotRelayoutLens() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = LensHost(rootView: lens(nil))
        window.contentView = host // Deliberately never ordered onto the screen.
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let pageID = UUID()
        for kind in [SnapCandidateKind.endpoint, .midpoint] {
            host.rootView = lens(SnapFeedbackSnapshot(kind: kind,
                pagePoint: PDFPointValue(x: 120, y: 230), sourceLabel: "wall", pageID: pageID))
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let before = host.layouts
            try await Task.sleep(for: .milliseconds(120))
            let idleLayouts = host.layouts - before
            print("loupe animation: \(idleLayouts) outer layouts during 120 ms")
            #expect(idleLayouts <= 2, "chip animation must not drive whole-lens layout ticks")
        }
        #expect(!window.isVisible)
    }
}
