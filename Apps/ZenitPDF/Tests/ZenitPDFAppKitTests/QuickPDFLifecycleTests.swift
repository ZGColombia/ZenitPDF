import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The quit dead-end. An edited Quick PDF must close and quit through
/// the classic Save / Don't Save / Cancel review; its takeoff data lives in the app
/// container's autosave location; and nothing is ever written next to the user's drawing.
@MainActor
@Suite(.appTierSerialised, .serialized) // the autosave-root override is one static; parallel tests would swap it mid-flight
struct QuickPDFLifecycleTests {

    /// Receives the `canClose` verdict the way AppKit's callers do.
    @MainActor
    final class CloseVerdictRecorder: NSObject {
        var verdict: Bool?
        @objc func document(
            _ document: NSDocument,
            shouldClose: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            verdict = shouldClose
        }
    }

    private static let verdictSelector = #selector(CloseVerdictRecorder.document(_:shouldClose:contextInfo:))

    /// A scratch container root, so the tests never touch real Application Support.
    ///
    /// ### Why the root is not deleted afterwards
    ///
    /// `quickPDFAutosaveRootOverride` is one static for the whole process, and this package runs
    /// three dozen suites at once. Every Quick PDF document any of them edits schedules a
    /// debounced autosave into *whatever the override says at that moment* — so documents
    /// belonging to other suites land in this root, and some of them are still committing when
    /// this function returns. Removing the directory out from under an open SQLite file is not
    /// tidy-up, it is `SQLite error 10: disk I/O error` in an unrelated test, which is exactly
    /// what it was producing.
    ///
    /// The directory is a uniquely named child of the per-user temporary directory, which the
    /// system reclaims. Leaving it is the cheaper of the two mistakes by a wide margin.
    private func withContainerRoot<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-container-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        defer { ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil }
        return try await body(root)
    }

    /// The drawing's own directory must hold exactly the drawing — the sibling
    /// `.zpdfproj` write is the 12.1 bug.
    private func onlyTheDrawing(at url: URL) throws -> Bool {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        return names == [url.lastPathComponent]
    }

    @Test("⌘Q's per-document review: Don't Save discards cleanly and termination proceeds")
    func quitReviewDiscardReachesTermination() async throws {
        try await withContainerRoot { root in
            let url = try AppTestSupport.writeFixturePDF(named: "Roof plan.pdf")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { document.core != nil })
            document.updateChangeCount(.changeDone)
            #expect(document.isDocumentEdited)

            var reviewRan = false
            document.unsavedTakeoffReview = { _, answer in
                reviewRan = true
                answer(.discard)
            }
            let recorder = CloseVerdictRecorder()
            // This is the exact call `reviewUnsavedDocuments` makes for each edited
            // document on ⌘Q — the path that used to die on "error 18".
            document.canClose(
                withDelegate: recorder,
                shouldClose: Self.verdictSelector,
                contextInfo: nil
            )
            #expect(await AppTestSupport.wait { recorder.verdict != nil })
            #expect(reviewRan, "an edited quick PDF must be reviewed, never silent-saved")
            #expect(recorder.verdict == true, "Don't Save must let the close proceed")
            #expect(!document.isDocumentEdited, "the discarded takeoff no longer counts as edited")
            #expect(try onlyTheDrawing(at: url), "nothing may be written next to the drawing")
            _ = root
            document.close()
        }
    }

    @Test("Cancel in the review keeps the document open and edited")
    func quitReviewCancelStops() async throws {
        try await withContainerRoot { _ in
            let url = try AppTestSupport.writeFixturePDF()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { document.core != nil })
            document.updateChangeCount(.changeDone)

            document.unsavedTakeoffReview = { _, answer in answer(.cancel) }
            let recorder = CloseVerdictRecorder()
            document.canClose(
                withDelegate: recorder,
                shouldClose: Self.verdictSelector,
                contextInfo: nil
            )
            #expect(await AppTestSupport.wait { recorder.verdict != nil })
            #expect(recorder.verdict == false, "Cancel keeps the document")
            #expect(document.isDocumentEdited)
            document.updateChangeCount(.changeCleared)
            document.close()
        }
    }

    @Test("File ▸ Close on a tab runs the same review and closes only that tab")
    func fileCloseClosesTheReviewedTab() async throws {
        try await withContainerRoot { _ in
            let firstURL = try AppTestSupport.writeFixturePDF(named: "Edited.pdf")
            let secondURL = try AppTestSupport.writeFixturePDF(named: "Clean.pdf")
            defer {
                try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
            }
            let edited = try AppTestSupport.makeDocument(opening: firstURL)
            let controller = ProjectWindowController(document: edited)
            edited.addWindowController(controller)
            let clean = try AppTestSupport.makeDocument(opening: secondURL)
            controller.attach(document: clean)
            #expect(await AppTestSupport.wait { edited.shell != nil && clean.shell != nil })

            edited.updateChangeCount(.changeDone)
            var reviewRan = false
            edited.unsavedTakeoffReview = { _, answer in
                reviewRan = true
                answer(.discard)
            }
            // File ▸ Close routes through performZenitCommand → .closeTab →
            // requestCloseTab (performClose closed the whole window).
            controller.requestCloseTab(id: edited.documentIdentity)
            #expect(await AppTestSupport.wait { controller.documents.count == 1 })
            #expect(reviewRan)
            #expect(controller.documents.first === clean, "only the reviewed tab closes")
            #expect(controller.window != nil)

            controller.window?.close()
            clean.close()
        }
    }

    @Test("The quick takeoff autosaves into the app container, never beside the drawing")
    func autosaveLandsInTheContainer() async throws {
        try await withContainerRoot { root in
            let url = try AppTestSupport.writeFixturePDF(named: "Plan B-201.pdf")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { document.core != nil })
            document.updateChangeCount(.changeDone)

            let autosaved = try await document.autosaveQuickPDFTakeoff()
            // The path assertion of the quit dead-end fix: inside the container root...
            #expect(autosaved.path.hasPrefix(root.path), "autosave must land in the container: \(autosaved.path)")
            #expect(autosaved.path.hasPrefix(document.quickPDFAutosaveDirectory.path))
            let manager = FileManager.default
            #expect(manager.fileExists(atPath: autosaved.appendingPathComponent("manifest.json").path))
            #expect(manager.fileExists(atPath: autosaved.appendingPathComponent("project.sqlite").path))
            // ...and nothing beside the drawing.
            #expect(try onlyTheDrawing(at: url))

            // Don't Save discards the container storage too.
            document.unsavedTakeoffReview = { _, answer in answer(.discard) }
            let recorder = CloseVerdictRecorder()
            document.canClose(
                withDelegate: recorder,
                shouldClose: Self.verdictSelector,
                contextInfo: nil
            )
            #expect(await AppTestSupport.wait { recorder.verdict == true })
            #expect(
                await AppTestSupport.wait {
                    !manager.fileExists(atPath: document.quickPDFAutosaveDirectory.path)
                },
                "Don't Save leaves nothing behind in the container"
            )
            document.close()
        }
    }

    @Test("A quick PDF's History feed records draw and undo through the container database")
    func historyFeedRecordsInQuickPDFMode() async throws {
        try await withContainerRoot { root in
            let url = try AppTestSupport.writeFixturePDF(named: "Historia.pdf")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { document.core != nil })
            let core = try #require(document.core)
            #expect(
                await AppTestSupport.wait { core.history.isAttached },
                "Quick PDF Mode attaches the container audit database"
            )
            #expect(FileManager.default.fileExists(
                atPath: document.quickPDFAutosaveDirectory.appendingPathComponent("history.sqlite").path
            ))

            _ = try await core.commands.calibrate(
                page: try #require(await core.session.firstPageID),
                first: PDFPoint(x: 72, y: 72),
                second: PDFPoint(x: 372, y: 72),
                knownLength: Decimal(30),
                knownLengthUnit: .metre
            )
            core.measurement.activate(kind: .length)
            core.measurement.placePoint(PDFPointValue(x: 72, y: 272))
            core.measurement.placePoint(PDFPointValue(x: 372, y: 272))
            await core.measurement.settlePlacements()
            core.measurement.commitActiveMeasurement()
            #expect(await AppTestSupport.wait { core.ledger.rowCount == 1 })
            await core.history.settle()
            #expect(core.history.events.map(\.action) == ["scale_changed", "markup_created"])

            await core.commands.undo()
            await core.history.settle()
            #expect(core.history.events.last?.action == "compensated", "an undo appends, never edits")

            // The shell reaches the same trail through the ledger presenter's cast —
            // exactly what the History tab does.
            let audit = try #require(core.ledger as (any LedgerAuditPresenting)?)
            #expect(audit.auditEvents(matching: LedgerAuditFilter()).count == 3)

            document.updateChangeCount(.changeCleared)
            _ = root
            document.close()
        }
    }
}
