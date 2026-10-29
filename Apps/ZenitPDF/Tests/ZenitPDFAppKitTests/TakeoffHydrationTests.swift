import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The hydration gap, closed end to end through the shipping document class (ADR-0009):
/// draw, save as a project, reopen — and the ledger, the scale, the labels and the
/// canvas markups are all back, digit for digit, with a fresh undo stack. Plus the
/// clean-quit half: a closed session takes its crash marker down, an abandoned one
/// still raises the recovery prompt.
@MainActor
@Suite(.appTierSerialised)
struct TakeoffHydrationTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// Every visible ledger cell of a presenter, row-major.
    private func ledgerStrings(_ core: AppCoreEnvironment) -> [[String]] {
        let columns = core.ledger.visibleColumns
        var rows: [[String]] = []
        for index in 0..<core.ledger.rowCount {
            guard let row = core.ledger.row(at: index) else { continue }
            rows.append(columns.map { row.displayValue($0.id) })
        }
        return rows
    }

    /// Calibrates 100 pt = 1 m and draws one length and one area through the shipping
    /// measurement presenter, so the auto labels ("Length A") ride along.
    private func populate(_ core: AppCoreEnvironment) async throws {
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        core.measurement.activate(kind: .length)
        core.measurement.appendRawPoints([
            PDFPointValue(x: 80, y: 80), PDFPointValue(x: 279, y: 80)
        ])
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.ledger.rowCount == 1 }, "the length row never landed")
        core.measurement.activate(kind: .area)
        core.measurement.appendRawPoints([
            PDFPointValue(x: 100, y: 100), PDFPointValue(x: 200, y: 100),
            PDFPointValue(x: 200, y: 174), PDFPointValue(x: 100, y: 174)
        ])
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.ledger.rowCount == 2 }, "the area row never landed")
        await core.refresh()
    }

    private func saveAsProject(_ document: ZenitPDFProjectDocument, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test("Save, close, reopen: scale, ledger, labels and markups hydrate identically")
    func reopenedProjectHydratesTheWholeTakeoff() async throws {
        let url = try AppTestSupport.writeFixturePDF()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        try await populate(core)

        let scaleBefore = try #require(core.snapshot.firstPageScale)
        let ledgerBefore = ledgerStrings(core)
        let markupsBefore = core.snapshot.markups.map { ($0.label, $0.subject) }
        #expect(markupsBefore.map(\.0) == ["Length A", "Area A"])

        let destination = directory.appendingPathComponent("Hydrate.zpdfproj")
        try await saveAsProject(document, to: destination)
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        // ── Reopen through the shipping load path ───────────────────────────────────
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        #expect(await wait { reopened.core != nil && !reopened.isLoading })
        let restored = try #require(reopened.core)
        #expect(reopened.loadFailure == nil)

        // Scale: the status bar reads the snapshot's default scale synchronously.
        let scaleAfter = try #require(restored.snapshot.firstPageScale)
        #expect(scaleAfter.displayString == scaleBefore.displayString)

        // Ledger: rows, order, every visible cell digit for digit.
        #expect(await wait { restored.ledger.rowCount == ledgerBefore.count })
        #expect(ledgerStrings(restored) == ledgerBefore)

        // Canvas: the markups are back with their stored labels and styles.
        let markupsAfter = restored.snapshot.markups
        #expect(markupsAfter.map(\.label) == ["Length A", "Area A"])
        #expect(markupsAfter.map(\.colorRGBA) == core.snapshot.markups.map(\.colorRGBA))

        // Undo starts fresh; a new measurement continues the letter sequence and is
        // undoable on its own.
        #expect(restored.commands.undoManager.canUndo == false)
        restored.measurement.activate(kind: .length)
        restored.measurement.appendRawPoints([
            PDFPointValue(x: 80, y: 120), PDFPointValue(x: 180, y: 120)
        ])
        restored.measurement.commitActiveMeasurement()
        #expect(await wait { restored.ledger.rowCount == ledgerBefore.count + 1 })
        await restored.refresh()
        #expect(restored.snapshot.markups.map(\.label).contains("Length B"),
                "a reopened project must continue at the next letter, not restart at A")
        await restored.commands.undo()
        await restored.refresh()
        #expect(restored.ledger.rowCount == ledgerBefore.count)

        reopened.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }

    @Test("A clean quit takes the crash marker down; an abandoned session still prompts")
    func cleanQuitClearsTheRecoveryMarker() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Marker.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        try await populate(core)
        let destination = directory.appendingPathComponent("Marker.zpdfproj")
        try await saveAsProject(document, to: destination)

        // The session is live, so the crash marker is armed — that is correct.
        let marker = destination.member(ProjectPackageLayout.crashMarker)
        #expect(FileManager.default.fileExists(atPath: marker.path),
                "an open session must keep its crash marker armed")

        // The quit path: shut the storage down and *wait* for it, exactly as
        // applicationShouldTerminate now does.
        await document.shutDownStorage()
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "a clean quit left the crash marker armed — the false recovery prompt")
        let assessment = try await ProjectPackage.assessRecovery(at: destination)
        #expect(assessment.isClean, "a cleanly quit project must reopen without a prompt")

        // And the honest half: a session that dies without closing must still prompt.
        let abandoned = try await ProjectPackage.open(at: destination)
        guard case .opened = abandoned else {
            Issue.record("the clean package should have opened without recovery")
            return
        }
        // No close() — the handle is abandoned, as a crash would leave it.
        let crashed = try await ProjectPackage.assessRecovery(at: destination)
        #expect(crashed.crashMarkerPresent, "a crashed session must keep its marker")
        #expect(!crashed.isClean, "a crashed session must still raise the recovery prompt")
        if case .opened(let handle) = abandoned {
            try await handle.close()  // leave the filesystem clean for the next test
        }
    }

    @Test("⌘S answered by an immediate ⌘Q still lands session-closed — no false prompt")
    func saveThenImmediateQuitLeavesNoPrompt() async throws {
        // The save pipeline reopens a storage session after its
        // atomic replace, and a quit racing it used to leave the journal's last word
        // `session-opened` — the false "was not closed properly" prompt. The package
        // now queues close() behind any in-flight save; this drives the racy sequence
        // through the shipping document and asserts the relaunch contract.
        let url = try AppTestSupport.writeFixturePDF(named: "Race.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        try await populate(core)
        let destination = directory.appendingPathComponent("Race.zpdfproj")
        try await saveAsProject(document, to: destination)

        // Dirty the takeoff again, then ⌘S on the existing package…
        core.measurement.activate(kind: .length)
        core.measurement.appendRawPoints([
            PDFPointValue(x: 10, y: 10), PDFPointValue(x: 60, y: 10)
        ])
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.ledger.rowCount == 3 })

        var saveFinished = false
        document.save(
            to: destination,
            ofType: ZenitAppInfo.projectTypeIdentifier,
            for: .saveOperation
        ) { _ in saveFinished = true }
        // …and ⌘Q before the pipeline can possibly finish. Whichever way the two
        // interleave, the disk must end cleanly closed.
        await Task.yield()
        await document.shutDownStorage()
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
        #expect(await wait { saveFinished }, "the in-flight save must resolve, not leak")

        let marker = destination.member(ProjectPackageLayout.crashMarker)
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "save-then-quit left the crash marker armed — the 12.9.5 false prompt")
        let assessment = try await ProjectPackage.assessRecovery(at: destination)
        #expect(assessment.isClean,
                "the relaunch must open silently after a save answered by an immediate quit")
    }

    @Test("The quit review of an edited project completes within its watchdog — never parks")
    func quitReviewOfAnEditedProjectNeverParks() async throws {
        // `NSDocumentController.shared` is one object for the whole
        // process and the review path walks every document registered in it. Hold it
        // for the duration of this test so no other suite's review closes this
        // document out from under the assertion below.
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        // The once-observed disease: a quit
        // parked forever in reviewNextEditedDocument → canClose on
        // _NSDocumentSerializationSemaphore. This drives the exact path with a bounded
        // watchdog, so a recurrence fails here in seconds instead of hanging a user.
        let url = try AppTestSupport.writeFixturePDF(named: "Park.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        try await populate(core)
        let destination = directory.appendingPathComponent("Park.zpdfproj")
        try await saveAsProject(document, to: destination)

        // An edited project at quit: the review path autosaves it in place and closes.
        core.measurement.activate(kind: .length)
        core.measurement.appendRawPoints([
            PDFPointValue(x: 20, y: 20), PDFPointValue(x: 90, y: 20)
        ])
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.ledger.rowCount == 3 })
        document.updateChangeCount(.changeDone)

        NSDocumentController.shared.addDocument(document)
        defer { NSDocumentController.shared.removeDocument(document) }
        let delegate = ZenitApplicationDelegate()
        var verdict: Bool?
        delegate.reviewEditedDocuments { verdict = $0 }
        #expect(await wait(upTo: 20) { verdict != nil },
                "the quit review parked in canClose — the 12.9 hang recurred")
        #expect(verdict == true, "an edited project autosaves in place and grants the quit")
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        let assessment = try await ProjectPackage.assessRecovery(at: destination)
        #expect(assessment.isClean, "the reviewed close must disarm the crash marker")
    }

    @Test("The bounded quit wait finishes, and takes the progress affordance down with it")
    func boundedQuitWaitCompletes() async throws {
        // `NSDocumentController.shared` is one object for the whole
        // process and the review path walks every document registered in it. Hold it
        // for the duration of this test so no other suite's review closes this
        // document out from under the assertion below.
        await SharedDocumentControllerGate.acquire()
        defer { SharedDocumentControllerGate.release() }
        let url = try AppTestSupport.writeFixturePDF(named: "Wait.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        try await populate(core)
        let destination = directory.appendingPathComponent("Wait.zpdfproj")
        try await saveAsProject(document, to: destination)

        NSDocumentController.shared.addDocument(document)
        defer { NSDocumentController.shared.removeDocument(document) }
        let delegate = ZenitApplicationDelegate()
        // Zero delay: even if the affordance flashes on, the wait must clean it up.
        delegate.terminationAffordanceDelay = .zero
        let finished = await delegate.awaitTerminationStorageShutdown()
        #expect(finished, "storage shutdown must complete well inside the bound")
        #expect(!delegate.terminationProgressVisible,
                "the quit progress affordance must come down when the wait ends")
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }

    @Test("The export dialog's CSV writes the ledger, and the trail rides along when asked")
    func exportCSVIncludesTheTrailWhenAsked() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Export.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        try await populate(core)
        await core.history.settle()

        let plain = directory.appendingPathComponent("ledger.csv")
        try ProjectWindowController.writeLedgerCSV(core: core, includeTrail: false, to: plain)
        let plainText = try String(contentsOf: plain, encoding: .utf8)
        #expect(plainText.contains("Length A"))
        #expect(!plainText.contains("Audit Trail"))

        let withTrail = directory.appendingPathComponent("ledger-trail.csv")
        try ProjectWindowController.writeLedgerCSV(core: core, includeTrail: true, to: withTrail)
        let trailText = try String(contentsOf: withTrail, encoding: .utf8)
        #expect(trailText.contains("Audit Trail"))
        if core.history.events.isEmpty {
            // Quick PDF Mode records history through the container database; without one
            // attached the trail section is present and honestly empty.
            #expect(trailText.contains("Audit Trail"))
        } else {
            #expect(trailText.contains("Measured") || trailText.contains("Scale changed"),
                    "the trail section must carry the recorded actions")
        }
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }
}
