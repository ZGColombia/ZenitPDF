import AppKit
import QuartzCore

/// The display link a zoom gesture's frames run on (NL-PERF-04), made once per canvas and paused
/// between gestures.
///
/// ## Why it is kept (K-14)
///
/// The canvas made a new `CADisplayLink` on the first event of every gesture and invalidated it
/// when the fingers lifted. The gesture replay's began-frame breakdown (iteration 1 re-fix, debug
/// build) put that one call — `NSView.displayLink(target:selector:)` and adding it to the run
/// loop — at 0.13–2.14 ms, the largest and most variable part of the gesture's first frame and
/// the whole difference between the slowest Z11 frames and the others: a 3.157 ms began frame
/// spent 2.143 ms making its link, and the same frame of the next gesture 0.130. The markup count
/// had nothing to do with it (the 500-area replay's began frames drew nothing). A paused link
/// costs nothing, so the link is made on the first gesture and paused, not destroyed, after each.
///
/// ## Lifetime
///
/// The link retains its target, and the run loop retains the link. The target is this small
/// object, never the canvas, and it reaches the canvas through a closure that holds it weakly —
/// so a kept link can never keep a closed canvas alive. The canvas invalidates the link when it
/// leaves the screen (`viewDidDisappear`) and when it is deallocated.
@MainActor
final class CanvasFrameClock: NSObject {

    private var link: CADisplayLink?
    /// What a frame does. The canvas sets it holding itself weakly.
    var onFrame: (@MainActor () -> Void)?

    /// How many links this clock has made. A test seam: one per canvas on screen, not one per
    /// gesture (K-14).
    private(set) var linkCreationCount = 0

    /// Whether frames are being delivered: a link exists and is not paused.
    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// Delivers frames for `view`'s display: resumes the kept link, or makes it the first time.
    func start(for view: NSView) {
        if let link {
            link.isPaused = false
            return
        }
        let made = view.displayLink(target: self, selector: #selector(fire(_:)))
        made.add(to: .main, forMode: .common)
        link = made
        linkCreationCount &+= 1
    }

    /// Stops delivering frames and keeps the link for the next gesture.
    func pause() {
        link?.isPaused = true
    }

    /// Removes the link from the run loop. The next `start(for:)` makes a new one.
    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        onFrame?()
    }
}
