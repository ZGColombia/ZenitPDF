import AppKit
import Foundation
import Testing
@testable import ZenitPDFAppKit

/// Found 2026-08-29: `windowCloseReviewInProgress` latched forever when one
/// document's `canClose` never answered, and every later ⌘W on the window died against
/// the stale latch. The guard is deliberately not a timeout: while the wedged review's
/// document set is unchanged the latch is honest ("a review is pending, answer it"), and
/// only when the document set has moved on — the wedged tab was closed some other way —
/// does the next ⌘W discard the dead latch and review afresh. Nothing is auto-discarded.
@MainActor
@Suite(.appTierSerialised)
struct WindowCloseReviewLatchTests {

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    @Test("A wedged close review cannot brick the window once its document is gone")
    func staleLatchClearsWhenTheDocumentSetMovesOn() async throws {
        let previousTabHost = ProjectWindowController.tabHost
        defer { ProjectWindowController.tabHost = previousTabHost }

        let firstURL = try AppTestSupport.writeFixturePDF(named: "Wedged.pdf")
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Clean.pdf")
        defer { try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent()) }

        let wedged = try AppTestSupport.makeDocument(opening: firstURL)
        let clean = try AppTestSupport.makeDocument(opening: secondURL)
        let host = ProjectWindowController(document: wedged)
        wedged.addWindowController(host)
        #expect(await wait { wedged.core != nil && wedged.shell != nil })
        host.attach(document: clean)
        #expect(await wait { clean.core != nil && clean.shell != nil })
        host.activateTab(id: wedged.documentIdentity)
        let window = try #require(host.window)
        defer {
            window.close()
            clean.close()
            wedged.close()
        }

        // The wedge: an edited Quick PDF whose review never answers — the exact latch
        // described above.
        wedged.updateChangeCount(.changeDone)
        wedged.unsavedTakeoffReview = { _, _ in }

        var windowClosed = false
        let observation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { windowClosed = true }
        }
        defer { NotificationCenter.default.removeObserver(observation) }

        // ⌘W: the review chain starts and wedges on the first document.
        #expect(host.windowShouldClose(window) == false)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!windowClosed)

        // ⌘W again with nothing changed: the latch is honest — the wedged review is
        // still the pending question, so nothing may restart or auto-answer it.
        #expect(host.windowShouldClose(window) == false)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(host.documents.count == 2, "the honest latch closes nothing on its own")
        #expect(!windowClosed)

        // The person deals with the wedged tab themselves: discards the edit and closes
        // the tab. The document set has now moved on under the dead latch.
        wedged.updateChangeCount(.changeCleared)
        host.requestCloseTab(id: wedged.documentIdentity)
        #expect(await wait { host.documents.count == 1 },
                "closing the no-longer-edited tab must work while the latch is stale")

        // ⌘W now: before the guard this returned false forever — the brick. The stale
        // latch clears, the remaining clean document is reviewed, and the window closes.
        _ = host.windowShouldClose(window)
        #expect(await wait { windowClosed },
                "one stuck review must not eat every later ⌘W once its document is gone")
        #expect(host.documents.isEmpty)
    }
}
