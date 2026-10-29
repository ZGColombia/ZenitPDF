import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// LT-32, 2026-08-29, verified twice: in Project Mode ⌘S saves — the
/// bundle's mtimes move, `performPackageSave` runs `updateChangeCount(.changeCleared)` —
/// and the tab's "• Edited" dot NEVER clears. An indicator that lies about unsaved work
/// makes every close review and every quit review lie with it.
///
/// The save here is the real ⌘S: `NSDocument.save(_:)` through AppKit's own machinery —
/// not a direct `save(to:ofType:for:)` call, which skips the change-count token
/// bookkeeping AppKit wraps around the user-facing path and which is exactly where the
/// live divergence lived.
@MainActor
@Suite(.appTierSerialised)
struct ProjectSaveEditedDotTests {

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// Draws one length through the shipping measurement presenter, so the dirtying is
    /// the product's own — never a bare `updateChangeCount` a test invented.
    private func drawOneLength(_ core: AppCoreEnvironment, x: Double) async throws {
        core.measurement.activate(kind: .length)
        core.measurement.appendRawPoints([
            PDFPointValue(x: x, y: 80), PDFPointValue(x: x + 100, y: 80)
        ])
        core.measurement.commitActiveMeasurement()
        await core.measurement.settlePlacements()
        await core.commands.settle()
        await core.refresh()
    }

    @Test("⌘S in Project Mode clears the edited dot, and it stays cleared")
    func realSaveClearsTheEditedDot() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Dot.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        defer {
            controller.window?.close()
            document.close()
        }
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        await core.refresh()
        try await drawOneLength(core, x: 80)

        // Become a project the way the product does.
        let destination = directory.appendingPathComponent("Dot.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #expect(document.mode == .project)
        #expect(await wait { !document.isDocumentEdited },
                "a freshly saved project must start clean")

        // Dirty it with a real measurement…
        try await drawOneLength(core, x: 200)
        #expect(await wait { document.isDocumentEdited }, "drawing must mark the document edited")
        #expect(document.makeTabSummary().hasUnsavedChanges)

        // …and save through the exact ⌘S path.
        document.save(nil)
        #expect(await wait { !document.isDocumentEdited },
                "LT-32: ⌘S saved the package but the document still claims unsaved work")
        #expect(!document.makeTabSummary().hasUnsavedChanges,
                "LT-32: the tab chip still shows the edited dot after a completed save")

        // The cleared state must reach the tab strip model itself, not only the summary…
        let presenterTab = try #require(core.document.tabs.first)
        #expect(!presenterTab.hasUnsavedChanges,
                "the save never re-aggregated the tab strip — the chip's dot is stale")

        // …and it must STAY cleared once the canvas/ledger observation passes have run:
        // a refresh pass over an unchanged takeoff must not re-dirty a just-saved project.
        await core.refresh()
        await core.commands.settle()
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!document.isDocumentEdited,
                "something re-dirtied the document right after the save, with nothing user-visible changed")
        #expect(!document.makeTabSummary().hasUnsavedChanges)

        // A second edit + second ⌘S behaves identically — the change count cannot have
        // drifted negative or otherwise out of step after the first round trip.
        try await drawOneLength(core, x: 320)
        #expect(await wait { document.isDocumentEdited })
        document.save(nil)
        #expect(await wait { !document.isDocumentEdited },
                "the second ⌘S never cleared — the change count drifted during the first save")
        #expect(!document.makeTabSummary().hasUnsavedChanges)

        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }

    @Test("An autosave neither clears the edited dot nor skews the ledger under the next ⌘S")
    func autosaveKeepsTheChangeLedgerHonest() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "AutoDot.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        defer {
            controller.window?.close()
            document.close()
        }
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        await core.refresh()
        try await drawOneLength(core, x: 80)

        let destination = directory.appendingPathComponent("AutoDot.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #expect(await wait { !document.isDocumentEdited })

        // Dirty it, then run the real autosave cycle — live, AppKit fires these between
        // every pause; headless nothing does, which is why LT-32 resisted the plain repro.
        try await drawOneLength(core, x: 200)
        #expect(await wait { document.isDocumentEdited })
        var autosaved = false
        var autosaveFailure: (any Error)?
        document.autosave(withImplicitCancellability: false) { error in
            autosaveFailure = error
            autosaved = true
        }
        #expect(await wait { autosaved })
        #expect(autosaveFailure == nil)

        // The dot stays on — the work is safe on disk but not saved in the document
        // sense — and the ledger stays consistent: everything IS autosaved now. The old
        // code hand-cleared the count inside the autosave and left this true forever.
        #expect(document.isDocumentEdited,
                "an autosave must not clear the edited dot — nobody pressed Save")
        #expect(document.makeTabSummary().hasUnsavedChanges)
        #expect(await wait { !document.hasUnautosavedChanges },
                "LT-32's skew: the completed autosave never registered, the change ledger drifted")

        // ⌘S after the autosave — the live sequence — must clear the dot, everywhere.
        document.save(nil)
        #expect(await wait { !document.isDocumentEdited },
                "LT-32: ⌘S after an autosave never cleared the edited state")
        #expect(!document.makeTabSummary().hasUnsavedChanges)
        let presenterTab = try #require(core.document.tabs.first)
        #expect(!presenterTab.hasUnsavedChanges, "the chip's dot survived the save")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!document.isDocumentEdited, "something re-dirtied the document after the save")

        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }
}
