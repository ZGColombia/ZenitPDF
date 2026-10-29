import AppKit
import Foundation

/// The one door every error in the application tier is shown through.
///
/// This exists because of a hang found by `sample(1)` on two hung runs of
/// `Scripts/build-app-package.sh`. `NSDocument`'s autosave cycle reported a save failure,
/// AppKit escalated it to `-[NSDocument presentError:]`, and that ran an `NSAlert` modally
/// inside a headless test process — a modal loop with no user, no event source able to
/// dismiss it, and therefore no end. The gate did not fail; it *hung*, which is worse,
/// because a hung gate is indistinguishable from a slow one.
///
/// The rule this type enforces is structural rather than disciplined: **a modal alert is
/// only ever run from the assembled application bundle.** A `swift test` process cannot be
/// the assembled bundle — `Bundle.main.bundleIdentifier` is the test runner's, never
/// ``ZenitAppInfo/bundleIdentifier`` — so no test can present a modal even if it forgets
/// to inject anything. Errors raised in a test are recorded in ``recorded`` and can be
/// asserted on, which is strictly more useful than an alert nobody sees.
///
/// `Scripts/build-app-package.sh` gates on this: no source file other than this one may
/// call `presentError`, so a new modal cannot be added back by accident.
@MainActor
public enum ZenitErrorPresenter {

    /// How one error is shown. Injected by a test that wants to assert on the presentation
    /// itself; `nil` uses the built-in behaviour.
    public typealias Handler = @MainActor (any Error, NSWindow?) -> Void

    /// The injected presenter, or `nil` for the built-in behaviour.
    public static var handler: Handler?

    /// Every error the presenter has been handed since ``reset()``, oldest first.
    ///
    /// Only recorded when the modal path is *not* taken, which is exactly the test case.
    /// The assembled app does not accumulate errors here.
    public private(set) static var recorded: [any Error] = []

    /// Whether this process is allowed to run a modal alert.
    ///
    /// True only when the code is running from the shipping application bundle. Everything
    /// else — `swift test`, `swift run`, a command-line tool linking the framework —
    /// reports the error without blocking.
    public static var canPresentModally: Bool {
        Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier
    }

    /// Shows an error, or records it when this process must not block.
    ///
    /// - Parameters:
    ///   - error: what went wrong.
    ///   - window: the window to sheet the alert onto, when there is one.
    public static func present(_ error: any Error, in window: NSWindow? = nil) {
        if let handler {
            handler(error, window)
            return
        }
        guard canPresentModally else {
            recorded.append(error)
            // A test run still says what happened, in one line, where the gate's log will
            // show it. Silence here would trade a hang for a mystery.
            NSLog("ZENIT-ERROR (not presented, no bundle): %@", String(describing: error))
            return
        }
        if let window, window.isVisible {
            window.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            NSApplication.shared.presentError(error)
        }
    }

    /// Whether AppKit's own error presentation may run.
    ///
    /// True only in the assembled bundle with no injected handler. `NSDocument`'s alert is
    /// better than anything reconstructed here — it is sheeted on the document's window and
    /// carries the recovery attempter — so the shipping app keeps it, and only the process
    /// that must not block is diverted.
    public static var presentsThroughAppKit: Bool {
        canPresentModally && handler == nil
    }

    /// Forgets every recorded error. A test calls this in its setup.
    public static func reset() {
        recorded = []
        handler = nil
    }

    /// The most recent recorded error, or `nil`.
    public static var lastRecorded: (any Error)? { recorded.last }
}
