import AppKit
import ObjectiveC

/// The display a test run pretends to have, so a suite can be run locally as the hosted CI
/// runner runs it: a 1x backing scale on a small screen, where this Mac has 2x and a large one.
///
/// Set in the environment of `swift test`:
///
/// - `ZENIT_TEST_BACKING_SCALE=1` — every window in the test process reports this backing scale
///   (`NSWindow.backingScaleFactor`), so the canvas plans, renders and places its rasters for
///   it exactly as on a display of that scale. Test-only: the getter is exchanged in the test
///   process, never in the product.
/// - `ZENIT_TEST_SCREEN_SIZE=1024x768` — ``Fix2Harness`` fits each window inside a screen of that
///   size (less the menu bar), and ``fittedContentSize(_:for:)`` caps a test's own resize to it,
///   as the runner's screen caps both.
///
/// Unset, nothing changes: the windows report the Mac's own scale and keep their sizes.
enum TestDisplay {

    /// The forced backing scale, or `nil`.
    static let backingScale: CGFloat? = ProcessInfo.processInfo.environment["ZENIT_TEST_BACKING_SCALE"]
        .flatMap(Double.init).map { CGFloat($0) }

    /// The pretended screen, or `nil`.
    static let screenSize: CGSize? = {
        guard let text = ProcessInfo.processInfo.environment["ZENIT_TEST_SCREEN_SIZE"] else { return nil }
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }()

    /// The menu bar the pretended screen loses at the top.
    static let menuBarHeight: CGFloat = 24

    /// Installs the forced backing scale, once. Safe to call from every harness.
    @MainActor
    static func install() {
        guard backingScale != nil, !installed else { return }
        installed = true
        let original = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.backingScaleFactor))
        let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.zenitTestBackingScaleFactor))
        if let original, let replacement { method_exchangeImplementations(original, replacement) }
    }
    @MainActor private static var installed = false

    /// Fits a window inside the pretended screen.
    @MainActor
    static func fit(_ window: NSWindow) {
        guard let screen = screenSize else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height - menuBarHeight)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    /// The content size a window may take for `wanted` on the pretended screen.
    @MainActor
    static func fittedContentSize(_ wanted: NSSize, for window: NSWindow) -> NSSize {
        guard let screen = screenSize else { return wanted }
        let chrome = NSSize(
            width: window.frame.width - window.contentRect(forFrameRect: window.frame).width,
            height: window.frame.height - window.contentRect(forFrameRect: window.frame).height
        )
        return NSSize(
            width: min(wanted.width, screen.width - chrome.width),
            height: min(wanted.height, screen.height - menuBarHeight - chrome.height)
        )
    }
}

extension NSWindow {
    /// Exchanged with `backingScaleFactor` by ``TestDisplay/install()``: after the exchange,
    /// calling this name reaches the original getter.
    @objc func zenitTestBackingScaleFactor() -> CGFloat {
        if let forced = TestDisplay.backingScale { return forced }
        return zenitTestBackingScaleFactor()
    }
}
