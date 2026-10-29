import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ZenitPDFAppKit

/// The gate that hung instead of failing.
///
/// `sample(1)` on two hung runs of `Scripts/build-app-package.sh` gave the same stack both
/// times — an `NSDocument` autosave failure escalating to `-[NSDocument presentError:]`,
/// which ran `-[NSAlert runModal]` inside a headless test process. A modal loop with no
/// user never ends, so the run sat there forever and the "flakiness" reported earlier
/// (9 green of 13) was this same defect: the runs that "failed" were the runs somebody
/// killed by hand.
///
/// These tests pin the fix at its two levels. The structural one is that a process which is
/// not the assembled bundle *cannot* run a modal, so no future test can reintroduce the
/// hang by forgetting to inject anything. The behavioural one is that the document's error
/// path — including the one AppKit calls, not only our own call sites — goes through
/// ``ZenitErrorPresenter``.
///
/// A test that fails here fails in milliseconds. A test that hangs here is the bug.
/// Serialized because `ZenitErrorPresenter` is process-wide state, as the thing it guards
/// — AppKit's error presentation — necessarily is. Two of these running at once would each
/// reset the other's recorder.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ErrorPresentationTests {

    private func makeProjectDocument() throws -> (ZenitPDFProjectDocument, URL) {
        // A project-mode document with nothing loaded: exactly the state the hung runs were
        // in, where `performSave` refuses with `documentNotReady`.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Takeoff.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: ZenitAppInfo.projectTypeIdentifier)
        document.fileURL = url
        return (document, directory)
    }

    @Test("A test process can never run a modal alert, injected presenter or not")
    func theTestProcessCannotPresentModally() {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        // The structural guarantee. `Bundle.main` in `swift test` is the runner's, never
        // the app's, so the modal branch is unreachable here by construction rather than
        // by every test remembering to opt out.
        #expect(!ZenitErrorPresenter.canPresentModally,
                "a swift-test process must not be able to reach NSAlert.runModal")
        #expect(Bundle.main.bundleIdentifier != ZenitAppInfo.bundleIdentifier)
    }

    @Test("An error handed to the presenter is recorded instead of blocking")
    func anErrorIsRecordedRatherThanPresented() {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady)
        #expect(ZenitErrorPresenter.recorded.count == 1)
        #expect(ZenitErrorPresenter.lastRecorded is ZenitDocumentError)
    }

    @Test("An injected presenter receives the error and nothing modal runs")
    func anInjectedPresenterReceivesTheError() {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        var seen: [String] = []
        ZenitErrorPresenter.handler = { error, _ in seen.append(String(describing: error)) }
        ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady)
        #expect(seen.count == 1)
        #expect(ZenitErrorPresenter.recorded.isEmpty, "an injected presenter takes the error outright")
    }

    /// The exact call AppKit made from `_saveIfNecessaryWithDelegate:`. Overriding our own
    /// call sites would not have caught it; overriding `presentError` is what does.
    @Test("NSDocument.presentError is routed, answers true, and does not block")
    func documentPresentErrorIsRouted() throws {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        let (document, directory) = try makeProjectDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var seen = 0
        ZenitErrorPresenter.handler = { _, _ in seen += 1 }

        let handled = document.presentError(ZenitDocumentError.documentNotReady)
        #expect(!handled, "nothing was recovered, and claiming otherwise lets AppKit carry on")
        #expect(seen == 1, "AppKit's own error path must reach ZenitErrorPresenter")
    }

    @Test("The sheet form of presentError is routed too, and still answers its delegate")
    func documentSheetPresentErrorIsRouted() throws {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        let (document, directory) = try makeProjectDocument()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // `NSWindow` created in code defaults to releasing itself when closed, which is an
        // over-release under ARC and crashed this test outright.
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var seen = 0
        ZenitErrorPresenter.handler = { _, presentedIn in
            seen += 1
            #expect(presentedIn === window)
        }
        document.presentError(
            ZenitDocumentError.documentNotReady,
            modalFor: window,
            delegate: nil,
            didPresent: nil,
            contextInfo: nil
        )
        #expect(seen == 1)
    }

    /// The whole failure, end to end: the save AppKit's autosave cycle performs fails, the
    /// completion handler receives the error, and reporting it does not block.
    @Test("A refused save reports its error and the run continues")
    func aRefusedSaveDoesNotHang() async throws {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        let (document, directory) = try makeProjectDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }

        var completed = false
        var reported: (any Error)?
        document.save(
            to: document.fileURL ?? directory,
            ofType: ZenitAppInfo.projectTypeIdentifier,
            for: .autosaveInPlaceOperation
        ) { error in
            completed = true
            reported = error
            // What AppKit does next, and the line that used to hang the whole suite.
            if let error { _ = document.presentError(error) }
        }
        #expect(await AppTestSupport.wait { completed },
                "the save must complete rather than sit behind a modal alert")
        #expect(reported != nil, "a project with nothing loaded cannot be saved, and says so")
        #expect(ZenitErrorPresenter.recorded.count == 1,
                "the refusal is reported once, without a modal")
    }
}
