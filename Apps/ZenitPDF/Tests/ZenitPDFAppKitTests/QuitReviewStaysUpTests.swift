import AppKit
import Foundation
import Testing
@testable import ZenitPDFAppKit

/// LT-17, 2026-08-29: the ⌘Q per-document takeoff review dismissed
/// itself before any button was pressed, and the documents closed without an explicit
/// choice. Two mechanisms could do that, and both are closed here:
///
/// 1. **A second quit restarted the review.** `ZenitApplication.terminate` ran the
///    pre-termination sweep again — which ends every attached sheet, the review's own
///    included — and `reviewEditedDocuments` overwrote the pending completion and drove a
///    second `canClose` at the same document. Now a pending review is joined, never
///    restarted, and `terminate` refuses re-entry while one is up.
/// 2. **The reviewed tab that owned the window controller closed the whole window.** The
///    delegate's per-document `close()` took the shared window — and every other tab's
///    drawing — off the screen while a later tab's review was still pending. Now the close
///    goes through the window controller's tab-aware teardown while other tabs remain.
///
/// The review itself is injected (`unsavedTakeoffReview`), so nothing here can put a sheet
/// on screen; the captured completion **is** the open dialog.
@MainActor
@Suite(.appTierSerialised)
struct QuitReviewStaysUpTests {

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    @Test("A second quit joins the pending review instead of restarting or dismissing it")
    func secondQuitJoinsThePendingReview() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }

        let url = try AppTestSupport.writeFixturePDF(named: "QuitReview.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer {
            document.updateChangeCount(.changeCleared)
            NSDocumentController.shared.removeDocument(document)
            document.close()
        }
        #expect(await wait { document.core != nil && !document.isLoading })
        NSDocumentController.shared.addDocument(document)
        document.updateChangeCount(.changeDone)

        // The captured completion is the review dialog: while it is unanswered, the
        // dialog is up. LT-17's rule: it stays up until *answered*.
        var reviewConsultations = 0
        var pendingAnswer: (@MainActor (ZenitPDFProjectDocument.UnsavedTakeoffDecision) -> Void)?
        document.unsavedTakeoffReview = { _, answer in
            reviewConsultations += 1
            pendingAnswer = answer
        }

        let delegate = ZenitApplicationDelegate()
        var firstVerdict: Bool?
        var secondVerdict: Bool?

        delegate.reviewEditedDocuments { firstVerdict = $0 }
        #expect(await wait { pendingAnswer != nil })
        #expect(reviewConsultations == 1)
        #expect(delegate.isReviewingEditedDocuments,
                "the terminate override reads this to refuse a re-entrant quit")

        // The second ⌘Q. Before the fix this overwrote the pending completion and drove a
        // second canClose — a second sheet — at the same document.
        delegate.reviewEditedDocuments { secondVerdict = $0 }
        #expect(reviewConsultations == 1,
                "LT-17: a second quit must join the pending review, not present it again")
        #expect(firstVerdict == nil && secondVerdict == nil,
                "no verdict may exist before the person answers")
        #expect(NSDocumentController.shared.documents.contains(document),
                "LT-17: the document closed without an explicit choice")
        #expect(document.isDocumentEdited, "the takeoff must still be intact")

        // The person finally answers: Cancel. Both quit requests hear the same verdict.
        pendingAnswer?(.cancel)
        #expect(await wait { firstVerdict != nil && secondVerdict != nil })
        #expect(firstVerdict == false && secondVerdict == false)
        #expect(!delegate.isReviewingEditedDocuments)
        #expect(NSDocumentController.shared.documents.contains(document))
        #expect(document.isDocumentEdited, "Cancel keeps the work")
    }

    @Test("Reviewing the tab that owns the window keeps the window alive for the next tab's review")
    func reviewedOwnerTabDoesNotCloseTheSharedWindow() async throws {
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let previousTabHost = ProjectWindowController.tabHost
        defer { ProjectWindowController.tabHost = previousTabHost }

        let firstURL = try AppTestSupport.writeFixturePDF(named: "OwnerTab.pdf")
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        let secondURL = try AppTestSupport.writeFixturePDF(named: "SecondTab.pdf")
        defer { try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent()) }

        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let second = try AppTestSupport.makeDocument(opening: secondURL)
        let host = ProjectWindowController(document: first)
        first.addWindowController(host)
        #expect(await wait { first.core != nil && first.shell != nil })
        host.attach(document: second)
        #expect(await wait { second.core != nil && second.shell != nil })
        host.activateTab(id: first.documentIdentity)
        #expect(host.document === first, "the first tab owns the window controller")

        defer {
            second.updateChangeCount(.changeCleared)
            NSDocumentController.shared.removeDocument(second)
            NSDocumentController.shared.removeDocument(first)
            host.window?.close()
            second.close()
            first.close()
        }

        NSDocumentController.shared.addDocument(first)
        NSDocumentController.shared.addDocument(second)
        first.updateChangeCount(.changeDone)
        second.updateChangeCount(.changeDone)

        // The first tab's review is answered — Don't Save — like a person would. The
        // second tab's review is captured and left pending: it is the dialog that used to
        // land on a window that had just closed underneath it.
        first.unsavedTakeoffReview = { _, answer in answer(.discard) }
        var secondReviewPending: (@MainActor (ZenitPDFProjectDocument.UnsavedTakeoffDecision) -> Void)?
        second.unsavedTakeoffReview = { _, answer in secondReviewPending = answer }

        var windowClosed = false
        let observation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: host.window,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { windowClosed = true }
        }
        defer { NotificationCenter.default.removeObserver(observation) }

        let delegate = ZenitApplicationDelegate()
        var verdict: Bool?
        delegate.reviewEditedDocuments { verdict = $0 }

        // The chain reviews the first tab, closes it, and moves on to the second.
        #expect(await wait { secondReviewPending != nil },
                "the second tab's review never ran — the chain died with the first tab")
        #expect(verdict == nil, "the review chain must still be waiting on the person")
        #expect(!windowClosed,
                "LT-17: closing the reviewed owner tab closed the shared window under the next review")
        #expect(host.documents.contains(where: { $0 === second }),
                "the unreviewed tab must still be attached to the surviving window")
        #expect(second.hostWindowController === host)
        #expect(host.document === second, "window-controller ownership migrated to the survivor")

        // Cancel keeps the second tab open and the application running.
        secondReviewPending?(.cancel)
        #expect(await wait { verdict != nil })
        #expect(verdict == false)
        #expect(!windowClosed)
        #expect(host.documents.contains(where: { $0 === second }))
    }
}
