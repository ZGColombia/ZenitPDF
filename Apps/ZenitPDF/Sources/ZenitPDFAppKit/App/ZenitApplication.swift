import AppKit

/// The application class, existing for exactly one reason: quitting must always work.
///
/// `NSApplication.terminate(_:)` cancels the whole termination request — before
/// `applicationShouldTerminate` is ever consulted, and reporting AppleEvent error -128
/// ("user cancelled") to a scripted quit — while any window has a document-modal sheet
/// session running. With the Revision Compare or Tool Library sheet open, `⌘Q`, the menu's
/// Quit and Dock > Quit all died in that pre-delegate check; the first assembled build had
/// to be killed with a signal.
///
/// The override ends every panel, mode and sheet through the delegate's normal
/// pre-termination sweep *first*, and when a sheet session was in fact torn down it re-enters
/// termination on the next run-loop turn so AppKit sees the app sheet-free.
public final class ZenitApplication: NSApplication {

    public override func terminate(_ sender: Any?) {
        Self.terminationFlow(
            application: self,
            delegate: delegate as? ZenitApplicationDelegate,
            terminateNow: { super.terminate(sender) }
        ).terminate()
    }

    /// The quit flow ``terminate(_:)`` runs, wired to `application` and its delegate; only
    /// AppKit's own `terminate` is handed in, so a test drives this very wiring.
    static func terminationFlow(
        application: NSApplication,
        delegate: ZenitApplicationDelegate?,
        terminateNow: @escaping @MainActor () -> Void
    ) -> TerminationFlow {
        TerminationFlow(
            isReviewing: { delegate?.isReviewingEditedDocuments ?? false },
            hasSheet: { application.windows.contains { $0.attachedSheet != nil } },
            prepareWindows: { delegate?.prepareWindowsForTermination(application) },
            needsReview: { delegate?.hasEditedDocumentsRequiringReview ?? false },
            review: { completion in delegate?.reviewEditedDocuments(completion: completion) },
            cancelled: { delegate?.quitCancelledByReview(application) },
            terminateNow: terminateNow
        )
    }

    /// Runs `body` — a call that reaches `super.terminate` — on the main run loop's next pass,
    /// outside every main-queue job (L-18).
    ///
    /// `super.terminate` asks the delegate, and the delegate answers `.terminateLater` whenever a
    /// project still has storage to close: AppKit then runs the run loop in the modal-panel mode
    /// until the reply, and the reply comes from a main-actor task that awaits the storage
    /// shutdown. Main-actor tasks run as jobs on the main dispatch queue, and the main queue is
    /// never drained re-entrantly: while one of its jobs is running, a nested run loop services
    /// everything but the main queue. The unsaved-changes review answers from exactly such a job —
    /// Don't Save retires the takeoff in a task — and `terminate` used to be re-entered straight
    /// from that answer, as it was from a `DispatchQueue.main.async` block after a sheet was
    /// ended: the reply's task could never run, and the application stayed up with its window
    /// open after Don't Save. A run-loop block runs from the run loop itself, where
    /// the modal wait does drain the main queue.
    static func reenterTermination(_ body: @escaping @MainActor () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(loop)
    }
}

/// The quit sequence ``ZenitApplication/terminate(_:)`` runs, with AppKit's side handed in — the
/// sheets, the delegate's review, and AppKit's own `terminate` — so a test drives the very code
/// the application runs (it5r L-18). Every re-entry goes through
/// ``ZenitApplication/reenterTermination(_:)``; nothing here is injectable about *how* it
/// re-enters, which is the part L-18 is about.
@MainActor
struct TerminationFlow {
    /// Whether a quit review is waiting on the person right now.
    var isReviewing: @MainActor () -> Bool
    /// Whether any window has a sheet attached.
    var hasSheet: @MainActor () -> Bool
    /// The delegate's pre-termination sweep: ends every panel, mode and sheet.
    var prepareWindows: @MainActor () -> Void
    /// Whether any document has unsaved changes to review.
    var needsReview: @MainActor () -> Bool
    /// The unsaved-changes review; its completion says whether everything was saved or discarded.
    var review: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    /// The review was cancelled, so the quit is over before AppKit was asked: whatever
    /// ``prepareWindows`` froze must follow the windows again, and a suspended scripted quit
    /// must hear -128 (W-018).
    var cancelled: @MainActor () -> Void
    /// AppKit's own `terminate`, which asks the delegate and may wait for its terminate-later reply.
    var terminateNow: @MainActor () -> Void

    func terminate() {
        // A quit whose review is already waiting on the person needs no second entrance
        // (LT-17). Running the pre-termination sweep again from here would end every
        // attached sheet — the review's own sheet included — so the question the person
        // was about to answer dismissed itself, and a restarted review would queue a
        // second identical sheet at the same document. The pending review's answer either
        // cancels the quit or re-enters this method with nothing left to review.
        if isReviewing() { return }
        let hadSheet = hasSheet()
        prepareWindows()
        guard hadSheet else {
            reviewEditedDocumentsThenTerminate()
            return
        }
        // The sheet sessions just ended; give AppKit the rest of this run-loop turn to
        // retire them, then ask again. Calling straight through would still be cancelled.
        ZenitApplication.reenterTermination { reviewEditedDocumentsThenTerminate() }
    }

    /// Runs the unsaved-changes review *before* AppKit's terminate, because AppKit never
    /// gets that far: with `autosavesInPlace` on, `-[NSApplication _shouldTerminate]`
    /// autosaves and **closes** every document before `applicationShouldTerminate` is
    /// consulted — instrumented live: by the time the delegate ran, `documents == 0`.
    /// For an edited Quick PDF whose NSDocument autosave is a deliberate no-op, that
    /// pre-delegate sweep silently discarded the takeoff. So any
    /// edited document is reviewed here, through its `canClose` — where the Quick PDF's
    /// Save / Don't Save / Cancel review lives — and only a fully reviewed application
    /// re-enters termination.
    func reviewEditedDocumentsThenTerminate() {
        guard needsReview() else {
            terminateNow()
            return
        }
        review { reviewedAll in
            // Cancel used to end here with nothing more: every window stayed frozen (tabs closed
            // afterwards stayed in the stored session) and a scripted quit was never answered.
            guard reviewedAll else { cancelled(); return }
            // Everything edited is now saved or discarded; re-enter, which falls through to
            // AppKit's terminate above — from the run loop, never from inside the review's own
            // answer, which arrives on a main-queue job (L-18).
            ZenitApplication.reenterTermination { terminate() }
        }
    }
}
