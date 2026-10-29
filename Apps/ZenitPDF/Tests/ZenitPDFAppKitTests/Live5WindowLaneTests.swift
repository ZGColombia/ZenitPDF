import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFPersistence
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Window regressions (L-19, L-26, L-31): the window keeps its size when a second drawing
/// joins as a tab, the Combine Open Drawings note counts in the singular, and a clean quick takeoff
/// still open at quit leaves no autosave folder behind. Headless: no window is ordered on screen
/// and no modal is presented.
@MainActor
@Suite("Window size, tab notes and quit cleanup", .appTierSerialised)
struct Live5WindowLaneTests {

    // MARK: - L-19

    /// Live: Plan-B opened while Plan-A was open, and the 1443 × 840 window became 1040 × 640.
    ///
    /// Old output, measured: the frame after the attach was (120, 280, 1040, 640) — the window's
    /// minimum, from the loading placeholder's zero fitting size clamped — and it stayed there
    /// when the first tab came back.
    @Test("L-19: a second, still-opening drawing joining as a tab keeps the window's frame")
    func secondDrawingKeepsTheWindowFrame() async throws {
        let firstURL = try AppTestSupport.writeFixturePDF(named: "Plan-A.pdf")
        let secondURL = try AppTestSupport.writeFixturePDF(named: "Plan-B.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        Fix2Harness.forgetStoredWindowLayouts()
        let first = try AppTestSupport.makeDocument(opening: firstURL)
        let controller = ProjectWindowController(document: first)
        #expect(await AppTestSupport.wait { first.shell != nil })
        first.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.contentViewController is ProjectWindowLayoutController })
        let window = try #require(controller.window)
        #expect(!window.isVisible, "the test window is never ordered on screen")
        #expect(window.minSize == NSSize(width: 1_040, height: 640), "precondition: the project layout's minimum")

        let sized = NSRect(x: 120, y: 80, width: 1_443, height: 840)
        window.setFrame(sized, display: false)
        #expect(window.frame == sized)

        // Read, but its load not started: it joins exactly as a large drawing does while it opens.
        let second = ZenitPDFProjectDocument()
        try second.read(from: secondURL, ofType: UTType.pdf.identifier)
        controller.attach(document: second)

        #expect(controller.activeDocument === second)
        #expect(second.shell == nil, "precondition: the second drawing is still opening")
        #expect(controller.loadingPlaceholder != nil, "its opening state is on screen")
        #expect(!(controller.contentViewController is ProjectWindowLayoutController))
        #expect(window.frame == sized, "the window kept its size: \(window.frame)")

        // Back to the first tab: its layout comes back over the same frame.
        controller.activateTab(id: first.documentIdentity)
        #expect(controller.contentViewController is ProjectWindowLayoutController)
        #expect(window.frame == sized, "\(window.frame)")

        controller.window?.close()
        first.close()
        second.close()
    }

    // MARK: - L-26

    /// Old output: "1 drawings added to this project with their takeoffs. Their own tabs are
    /// unchanged." — one bare `%d` format for every count.
    @Test("L-26: the Combine Open Drawings note says 1 drawing, 2 drawings")
    func combinedNoteCountsInTheSingular() {
        #expect(ZenitPDFProjectDocument.drawingsCombinedNote(1)
                == "1 drawing added to this project with its takeoff. Its own tab is unchanged.")
        #expect(ZenitPDFProjectDocument.drawingsCombinedNote(2)
                == "2 drawings added to this project with their takeoffs. Their own tabs are unchanged.")
    }

    // MARK: - L-31

    private func withContainerRoot<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-container-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        defer {
            ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(root)
    }

    /// Live: after Don't Save and a clean quit, `Autosave/<UUID>/history.sqlite` stayed. The
    /// History feed opens that database in the container when a quick PDF loads, and quit closes
    /// every document its review left open with `shutDownStorage()` — never `close()`, whose
    /// clean-takeoff removal was the only one there was.
    ///
    /// Old output: after `shutDownStorage()` the clean takeoff's directory still held
    /// `history.sqlite`.
    @Test("L-31: quit's storage shutdown removes a clean quick takeoff's container; an edited one keeps its crash copy")
    func quitShutdownDiscardsACleanTakeoffsContainer() async throws {
        try await withContainerRoot { root in
            let manager = FileManager.default

            let cleanURL = try AppTestSupport.writeFixturePDF(named: "Plan-B.pdf")
            defer { try? manager.removeItem(at: cleanURL.deletingLastPathComponent()) }
            let clean = try AppTestSupport.makeDocument(opening: cleanURL)
            #expect(await AppTestSupport.wait { clean.core?.history.isAttached == true })
            let cleanDirectory = clean.quickPDFAutosaveDirectory
            #expect(cleanDirectory.path.hasPrefix(root.path))
            #expect(manager.fileExists(atPath: cleanDirectory.appendingPathComponent("history.sqlite").path),
                    "precondition: the History feed opened its database in the container at load")
            #expect(!clean.isDocumentEdited)

            // What `ZenitApplicationDelegate.shutDownAllDocumentStorage()` runs at quit.
            await clean.shutDownStorage()
            #expect(!manager.fileExists(atPath: cleanDirectory.path), "a clean takeoff leaves nothing behind")
            clean.close()
            #expect(await AppTestSupport.wait { !clean.hasOpenStorage })

            // The control: an edited takeoff that reaches quit unreviewed keeps its autosave.
            let editedURL = try AppTestSupport.writeFixturePDF(named: "Plan-C.pdf")
            defer { try? manager.removeItem(at: editedURL.deletingLastPathComponent()) }
            let edited = try AppTestSupport.makeDocument(opening: editedURL)
            #expect(await AppTestSupport.wait { edited.core?.history.isAttached == true })
            edited.updateChangeCount(.changeDone)
            let package = try await edited.autosaveQuickPDFTakeoff()
            await edited.shutDownStorage()
            #expect(manager.fileExists(atPath: package.appendingPathComponent(ProjectPackageLayout.manifest).path),
                    "an edited takeoff's autosave is its crash-survival copy")
            #expect(manager.fileExists(atPath: edited.quickPDFAutosaveDirectory.appendingPathComponent("history.sqlite").path))
            edited.close()
            #expect(await AppTestSupport.wait { !edited.hasOpenStorage })
            #expect(manager.fileExists(atPath: edited.quickPDFAutosaveDirectory.path), "close keeps it too")
        }
    }

    /// The storage half, without a document: a discarding shutdown removes the directory and the
    /// history database in it — also when the history open is still in flight and would otherwise
    /// recreate the file after the removal.
    @Test("L-31: QuickTakeoffStorage.shutDown(discardingDirectory:) removes the container, a racing history open included")
    func discardingShutdownRemovesTheContainer() async throws {
        let pdf = try AppTestSupport.writeFixturePDF(named: "L31.pdf")
        let root = pdf.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        func storage(_ directory: URL, writeDelay: Duration = .zero) -> QuickTakeoffStorage {
            QuickTakeoffStorage(
                defaultDirectory: { directory },
                origin: { QuickTakeoffStorage.Origin(originalPDF: pdf, pageCount: 1, displayName: "L31") },
                writeArchive: { _ in try await Task.sleep(for: writeDelay) }
            )
        }
        let manager = FileManager.default

        let settledDirectory = root.appendingPathComponent("container-settled", isDirectory: true)
        let settled = storage(settledDirectory)
        _ = try await settled.openHistoryDatabase()
        #expect(manager.fileExists(atPath: settledDirectory.appendingPathComponent("history.sqlite").path))
        await settled.shutDown(discardingDirectory: true)
        #expect(!settled.holdsStorage)
        #expect(!manager.fileExists(atPath: settledDirectory.path))

        // A history open queued behind an autosave still writing — its epoch taken before the
        // shutdown, which waits for the write and not for the open. Whichever of the two runs
        // first once the write lands, nothing may be left behind: not the package, not the
        // history database the late open creates.
        let racingDirectory = root.appendingPathComponent("container-racing", isDirectory: true)
        let racing = storage(racingDirectory, writeDelay: .milliseconds(400))
        let flush = Task { @MainActor in try await racing.flush() }
        let open = Task { @MainActor in try await racing.openHistoryDatabase() }
        #expect(await AppTestSupport.wait { racing.pendingOperations == 2 }, "the write runs, the open is queued")
        await racing.shutDown(discardingDirectory: true)
        _ = try? await flush.value
        _ = try? await open.value
        #expect(await AppTestSupport.wait { racing.pendingOperations == 0 })
        #expect(!racing.holdsStorage, "no history handle outlives the shutdown")
        #expect(!manager.fileExists(atPath: racingDirectory.path))

        // The default keeps the container, as before (IM-181).
        let keptDirectory = root.appendingPathComponent("container-kept", isDirectory: true)
        let kept = storage(keptDirectory)
        _ = try await kept.openHistoryDatabase()
        await kept.shutDown()
        #expect(manager.fileExists(atPath: keptDirectory.appendingPathComponent("history.sqlite").path))
    }
}
