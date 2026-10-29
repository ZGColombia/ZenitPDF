import AppKit
import CryptoKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFServiceWire
import ZPDFSpreadsheet
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Loop iteration 1, area app-shell-glue: R-016 … R-031. Every test states the old output it
/// fails with. Headless throughout: windows are never ordered front, every modal is recorded
/// or answered by injection.
@MainActor
@Suite("Iteration 1 — app shell glue (1)", .appTierSerialised)
struct Iter1ShellGlueTests {

    /// A defaults store that counts its writes per key.
    final class CountingStore: ZPDFDefaultsStoring {
        var values: [String: Data] = [:]
        var writes: [String: Int] = [:]
        func persistedData(forKey key: String) -> Data? { values[key] }
        func setPersistedData(_ data: Data?, forKey key: String) {
            values[key] = data
            writes[key, default: 0] += 1
        }
    }

    /// Saves the harness's Quick PDF as a project beside the fixture and returns its package.
    static func saveAsProject(_ harness: Fix2Harness, name: String = "Project.zpdfproj") async throws -> URL {
        let destination = harness.directory.appendingPathComponent(name)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            harness.document.save(to: destination, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return destination
    }

    static func save(_ document: ZenitPDFProjectDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: operation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - R-016

    @Test("R-016: a drawing opened through the window has VoiceOver markup labels and press-to-select installed")
    func markupAccessibilityInstalledByTheWindow() async throws {
        let harness = try await Fix2Harness.make("R016.pdf")
        defer { harness.tearDown() }
        // No direct installMarkupAccessibility() call: the window's own install path must do it.
        // Old: nil and nil — wireR2Platform ran before the canvas was registered.
        let pageView = harness.canvas.pageViewForTesting
        #expect(pageView.markupAccessibilityTexts != nil)
        #expect(pageView.onMarkupAccessibilityPress != nil)
        let markup = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        }, subject: "Wall")
        harness.canvas.refresh()
        let element = try #require(pageView.markupAccessibilityElements().first as? CanvasMarkupAccessibilityElement)
        #expect(element.accessibilityLabel()?.hasPrefix("Wall, ") == true)
        #expect(element.accessibilityPerformPress())
        #expect(harness.core.canvas.selectedMarkups.map(\.id) == [markup.id.rawValue])
    }

    // MARK: - R-017

    @Test("R-017: building a menu bar, or the shortcut reference, never takes over NSApp's Services, Window or Help menus")
    func shortcutReferenceLeavesMenuRolesAlone() throws {
        let app = NSApplication.shared
        let services = app.servicesMenu, windows = app.windowsMenu, help = app.helpMenu
        _ = KeyboardShortcutsReference.sections()
        let bar = ZenitMenuBar.make()
        // Old: every ZenitMenuBar.make() assigned all three to the new, never-installed bar's menus.
        #expect(app.servicesMenu === services)
        #expect(app.windowsMenu === windows)
        #expect(app.helpMenu === help)
        // The roles are found in the built bar, for ZenitMenuBar.install(_:) to give.
        #expect(ZenitMenuBar.specialMenu(.services, in: bar)?.title == "Services")
        #expect(ZenitMenuBar.specialMenu(.windows, in: bar)?.title == "Window")
        #expect(ZenitMenuBar.specialMenu(.help, in: bar)?.title == "Help")
        // The reference still lists the application chords.
        #expect(KeyboardShortcutsReference.sections().flatMap(\.entries).contains { $0.title == "Show Next Tab" })
    }

    // MARK: - R-018

    @Test("R-018: an Inspector repeat-count edit is one change: ⌘Z returns the document to clean")
    func repeatCountUndoReturnsToClean() async throws {
        let harness = try await Fix2Harness.make("R018.pdf")
        defer { harness.tearDown() }
        let markup = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 200, y: 10)])
        })
        harness.document.updateChangeCount(.changeCleared)
        #expect(!harness.document.isDocumentEdited)
        let onSetRepeatCount = try #require(harness.shell.onSetRepeatCount)
        // W-039: the hook answers whether the edit landed.
        #expect(await onSetRepeatCount(markup.id.rawValue, 3))
        #expect(await AppTestSupport.wait { harness.document.isDocumentEdited })
        await harness.core.commands.settle()
        await harness.core.refresh()
        // Room for the old explicit changeDone, which ran after the refresh, to land.
        try await Task.sleep(for: .milliseconds(300))
        harness.document.undoManager?.undo()
        // Old: the bus's undo group plus an explicit changeDone — one ⌘Z left the count at 1.
        #expect(await AppTestSupport.wait(upTo: 5) { !harness.document.isDocumentEdited },
                "⌘Z must bring the document back to clean")

        // The other seven sites: none of them marks the document on top of the bus any more.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wiring = try String(contentsOf: root.appendingPathComponent("Sources/ZenitPDFAppKit/Workflows/ProjectStructureWiring.swift"), encoding: .utf8)
        #expect(!wiring.contains("updateChangeCount(.changeDone)"))
        let roundTrip = try String(contentsOf: root.appendingPathComponent("Sources/ZenitPDFAppKit/Platform/SpreadsheetRoundTrip.swift"), encoding: .utf8)
        #expect(!roundTrip.contains("document.updateChangeCount(.changeDone)"))
    }

    // MARK: - R-020

    @Test("R-020: the stale-autosave sweep judges age by the newest of manifest, database and WAL")
    func staleSweepUsesTheNewestStamp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r020-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        let yesterday = now.addingTimeInterval(-86_400)
        func container(_ name: String, manifest: Date, database: Date?) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let package = QuickTakeoffStorage.packageURL(in: directory)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let manifestURL = package.appendingPathComponent(ProjectPackageLayout.manifest)
            try Data("{}".utf8).write(to: manifestURL)
            try FileManager.default.setAttributes([.modificationDate: manifest], ofItemAtPath: manifestURL.path)
            if let database {
                let databaseURL = package.appendingPathComponent(ProjectPackageLayout.database)
                try Data("db".utf8).write(to: databaseURL)
                try FileManager.default.setAttributes([.modificationDate: database], ofItemAtPath: databaseURL.path)
            }
            return directory
        }
        // A restored container: created 40 days ago, light-autosaved into its database yesterday.
        let recent = try container("recent", manifest: old, database: yesterday)
        let stale = try container("stale", manifest: old, database: old)
        let removed = ZenitPDFProjectDocument.removeStaleQuickAutosaves(in: root, sparing: [], olderThan: 30 * 86_400, now: now)
        // Old: both removed — the manifest alone decided, and it is 40 days old in both.
        #expect(removed.map(\.lastPathComponent) == ["stale"])
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(QuickTakeoffStorage.lastWritten(packageURL: QuickTakeoffStorage.packageURL(in: recent))
            .map { abs($0.timeIntervalSince(yesterday)) < 2 } == true)
    }

    // MARK: - R-021

    @Test("R-021: edits, undos and autosaves no longer re-record the window session or re-bookmark its drawings")
    func dirtyStateChangesDoNotRewriteTheSession() async throws {
        let harness = try await Fix2Harness.make("R021.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.document.fileURL = harness.directory.appendingPathComponent("R021.pdf")
        let store = CountingStore()
        let previous = ZenitProcessDefaults.override
        ZenitProcessDefaults.override = store
        defer { ZenitProcessDefaults.override = previous }
        // Synchronous from here: nothing else can write through the override meanwhile.
        harness.document.updateChangeCount(.changeDone)
        harness.document.updateChangeCount(.changeDone)
        harness.document.updateChangeCount(.changeUndone)
        harness.document.updateChangeCount(.changeCleared)
        let sessionWrites = store.writes[WindowSessionStore.key, default: 0]
        let bookmarkWrites = store.writes[DroppedFileBookmarks.defaultsKey, default: 0]
        // Old: four session writes and four bookmark-store rewrites, one per change-count move.
        #expect(sessionWrites == 1, "the session is recorded once, when it first differs from the stored one")
        #expect(bookmarkWrites <= 1, "the drawing is bookmarked at most once")
        #expect(WindowSessionStore.load(defaults: store)?.paths == [harness.directory.appendingPathComponent("R021.pdf").path])
        // A real change to the session — the sheet in front — is still recorded.
        harness.core.canvas.setZoom(2)
        harness.controller.syncTabs()
        #expect(store.writes[WindowSessionStore.key, default: 0] == 2)
    }

    // MARK: - R-022

    @Test("R-022: Cancel in the window-close review thaws the session, so later tab changes are recorded")
    func cancelledCloseThawsTheSession() async throws {
        let harness = try await Fix2Harness.make("R022.pdf", calibrate: false)
        defer { harness.tearDown() }
        let first = harness.directory.appendingPathComponent("R022.pdf")
        harness.document.fileURL = first
        let store = CountingStore()
        let previous = ZenitProcessDefaults.override
        ZenitProcessDefaults.override = store
        defer { ZenitProcessDefaults.override = previous }
        harness.document.updateChangeCount(.changeDone)
        var asked = false
        harness.document.unsavedTakeoffReview = { _, answer in asked = true; answer(.cancel) }
        defer { harness.document.unsavedTakeoffReview = nil }
        let window = try #require(harness.controller.window)
        #expect(!harness.controller.windowShouldClose(window))
        #expect(await AppTestSupport.wait { asked })
        #expect(await AppTestSupport.wait { !harness.controller.isSessionFrozen },
                "old: the session stayed frozen until another drawing arrived")
        // A change after the cancelled close is recorded.
        let renamed = harness.directory.appendingPathComponent("R022 renamed.pdf")
        harness.document.fileURL = renamed
        harness.controller.syncTabs()
        #expect(WindowSessionStore.load(defaults: store)?.paths == [renamed.path])
        harness.document.updateChangeCount(.changeCleared)
    }

    @Test("R-022: a quit freezes every window's session before its review closes tabs; a cancelled quit thaws it")
    func quitFreezesAndCancelThaws() async throws {
        let harness = try await Fix2Harness.make("R022q.pdf", calibrate: false)
        defer { harness.tearDown() }
        let first = harness.directory.appendingPathComponent("R022q.pdf")
        harness.document.fileURL = first
        let store = CountingStore()
        let previous = ZenitProcessDefaults.override
        ZenitProcessDefaults.override = store
        defer { ZenitProcessDefaults.override = previous }
        // A clean document, so the termination sweep brings no window forward.
        harness.document.updateChangeCount(.changeCleared)
        harness.controller.prepareForTermination()
        #expect(harness.controller.isSessionFrozen, "old: quit never froze the session")
        #expect(WindowSessionStore.load(defaults: store)?.paths == [first.path])
        // What the quit review does to a reviewed tab — the stored session must not follow it.
        harness.document.fileURL = harness.directory.appendingPathComponent("During review.pdf")
        harness.controller.syncTabs()
        #expect(WindowSessionStore.load(defaults: store)?.paths == [first.path])
        // The review was cancelled: the window lives on and records again.
        ZenitApplicationDelegate().windowsAfterCancelledTermination(NSApplication.shared)
        harness.controller.terminationCancelled()
        #expect(!harness.controller.isSessionFrozen)
        #expect(WindowSessionStore.load(defaults: store)?.paths == [harness.directory.appendingPathComponent("During review.pdf").path])
    }

    // MARK: - R-023 / R-024 / R-025

    static func copyTransform(delay: Duration = .zero) -> @Sendable (URL, URL, RepairWireTransform) async throws -> Void {
        { input, output, _ in
            if delay > .zero { try await Task.sleep(for: delay) }
            try FileManager.default.copyItem(at: input, to: output)
        }
    }

    @Test("R-023: a second Process PDF Files run is refused while one runs, Stop reaches the live run, and Stop is enabled only then")
    func batchRunKeepsItsStopHandle() async throws {
        let harness = try await Fix2Harness.make("R023.pdf", calibrate: false)
        defer { harness.tearDown() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r023-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("in/Plan.pdf")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: harness.directory.appendingPathComponent("R023.pdf"), to: input)
        var steps = BatchFileProcessor.Steps()
        steps.reduceSize = true
        let state = ZenitAppCommandWindowState(controller: harness.controller)
        #expect(!ZenitAppCommandTable.validate(.stopProcessingPDFFiles, item: nil, state: state),
                "old: Stop Processing was always enabled")
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .button(0) }
        defer { ZenitModalPresenter.reset() }
        let started = BatchFileCommand.start(
            inputs: [input], steps: steps, folder: root.appendingPathComponent("out"), beside: false,
            document: nil, window: nil, transform: Self.copyTransform(delay: .milliseconds(400))
        )
        #expect(started)
        let firstRun = try #require(BatchFileCommand.running)
        #expect(ZenitAppCommandTable.validate(.stopProcessingPDFFiles, item: nil, state: state))
        // Old: the second start cancelled the first and took its handle; the first then cleared it.
        let second = BatchFileCommand.start(
            inputs: [input], steps: steps, folder: root.appendingPathComponent("out2"), beside: false,
            document: nil, window: nil, transform: Self.copyTransform()
        )
        #expect(!second)
        #expect(ZenitModalPresenter.didRequest(BatchFileCommand.refusalIdentifier))
        #expect(BatchFileCommand.running == firstRun, "Stop still reaches the run on screen")
        await firstRun.value
        #expect(!BatchFileCommand.isRunning)
        #expect(!ZenitAppCommandTable.validate(.stopProcessingPDFFiles, item: nil, state: state))
    }

    @Test("R-024: same-named PDFs from two folders get two outputs, and a re-run resumes each by its own output")
    func sameNamedInputsGetTheirOwnOutputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r024-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Level 1/Plan.pdf"), b = root.appendingPathComponent("Level 2/Plan.pdf")
        for (url, pages) in [(a, 1), (b, 2)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try AppTestSupport.writeFixturePDF(named: "Plan.pdf", pageCount: pages), to: url)
        }
        let out = root.appendingPathComponent("out", isDirectory: true)
        var steps = BatchFileProcessor.Steps()
        steps.reduceSize = true
        let report = try await BatchFileProcessor.run(
            inputs: [a.deletingLastPathComponent(), b.deletingLastPathComponent()],
            steps: steps, outputFolder: out, transform: Self.copyTransform()
        )
        #expect(report.done == 2)
        let outputs = report.items.compactMap(\.output?.lastPathComponent)
        // Old: ["Plan — Processed.pdf", "Plan — Processed.pdf"] — one file, the second input's.
        #expect(outputs == ["Plan (Level 1) — Processed.pdf", "Plan (Level 2) — Processed.pdf"])
        for (input, name) in zip([a, b], outputs) {
            #expect(try Data(contentsOf: out.appendingPathComponent(name)) == Data(contentsOf: input))
        }
        let resumed = try await BatchFileProcessor.run(
            inputs: [a.deletingLastPathComponent(), b.deletingLastPathComponent()],
            steps: steps, outputFolder: out, transform: Self.copyTransform()
        )
        #expect(resumed.items.allSatisfy { $0.status == .skipped("already processed in an earlier run") })

        // A state written before outputs were recorded resumes nothing: its outputs may be shared.
        var legacy = BatchFileProcessor.readState(in: out)
        legacy.outputs = nil
        BatchFileProcessor.writeState(legacy, in: out)
        let rerun = try await BatchFileProcessor.run(
            inputs: [a.deletingLastPathComponent(), b.deletingLastPathComponent()],
            steps: steps, outputFolder: out, transform: Self.copyTransform()
        )
        #expect(rerun.done == 2)
    }

    @Test("R-025: Protect ticked with no password is refused before the output folder is asked for")
    func protectWithoutPasswordIsRefused() throws {
        let accessory = BatchFileCommand.StepsAccessory()
        accessory.protect.state = .on
        accessory.password.stringValue = ""
        #expect(accessory.steps.protection == nil)
        #expect(accessory.refusal?.contains("permissions password") == true)
        let recorded = ZenitModalPresenter.answering({ _ in .button(0) }) {
            BatchFileCommand.chooseOutputFolder(inputs: [URL(fileURLWithPath: "/tmp/x.pdf")], accessory: accessory, document: nil, window: nil)
        }
        // Old: the output-folder panel came next and the run wrote unprotected copies.
        #expect(recorded.map(\.identifier) == [BatchFileCommand.refusalIdentifier])
        // Nothing ticked at all is refused at the same point, not after the folder panel.
        accessory.protect.state = .off
        accessory.reduce.state = .off
        #expect(accessory.refusal == BatchFileProcessor.Refusal.noSteps.description)
        accessory.password.stringValue = "owner"
        accessory.protect.state = .on
        #expect(accessory.refusal == nil)
        #expect(accessory.steps.protection?.permissionsPassword == "owner")
    }

    // MARK: - R-026

    @Test("R-026: Redaction, Scan Clean-up, Fill Form Fields and Optimize Copy refuse to write over the drawing")
    func derivedCopiesNeverReplaceTheDrawing() async throws {
        let harness = try await Fix2Harness.make("R026.pdf", calibrate: false)
        defer { harness.tearDown() }
        let drawing = try #require(harness.document.drawing).url
        let before = SHA256.hash(data: try Data(contentsOf: drawing))
        // The same file spelled through a symbolic link to its folder.
        let link = harness.directory.deletingLastPathComponent().appendingPathComponent("r026-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: harness.directory)
        defer { try? FileManager.default.removeItem(at: link) }
        let spelled = link.appendingPathComponent(drawing.lastPathComponent)
        for target in [drawing, spelled] {
            // Old: each replaced the drawing with its derived copy.
            await #expect(throws: DerivedCopyGuard.Refusal.self) {
                _ = try await RedactionWorkflow.apply(document: harness.document, to: target)
            }
            await #expect(throws: DerivedCopyGuard.Refusal.self) {
                _ = try await ScanCleanupCommand.run(document: harness.document, options: .init(), currentSheetOnly: false, to: target)
            }
            await #expect(throws: (any Error).self) {
                _ = try await FormFill.write(source: drawing, password: nil, values: [:], flatten: false, to: target)
            }
            await #expect(throws: DerivedCopyGuard.Refusal.self) {
                _ = try await DocumentCopyTransform.run(source: drawing, password: nil, output: target, choices: .init())
            }
        }
        #expect(SHA256.hash(data: try Data(contentsOf: drawing)) == before, "the drawing is byte for byte what it was")
    }

    // MARK: - R-027

    @Test("R-027: AppleScript writes the menu's workbook, with row identity, and answers the Shortcuts totals")
    func appleScriptSharesTheExportPath() async throws {
        let harness = try await Fix2Harness.make("R027.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 250, y: 10)])
        }, subject: "Wall")
        let workbook = harness.directory.appendingPathComponent("Script.xlsx")
        _ = try await ZenitScripting.export(document: harness.document, to: workbook, format: .xlsx)
        // Old: a bare XLSXExporter workbook with no identity sheet, which the reader refuses.
        let reading = try LedgerRoundTripWorkbook(data: Data(contentsOf: workbook))
        #expect(reading.rows.count == 1)
        // Old: only Sum rows, written "title: number unit", unlike Get Totals.
        let scripted = try await ZenitScripting.totals(document: harness.document)
        let shortcut = try await ZenitShortcutsBridge.totals(of: harness.document)
        #expect(scripted == shortcut)
        #expect(scripted.replacingOccurrences(of: ",", with: ".").contains("2.5"), "250 pt at 100 pt/m is 2.5 m — \(scripted)")
        // The CSV is the on-screen table's, byte for byte.
        let scriptedCSV = harness.directory.appendingPathComponent("Script.csv")
        let menuCSV = harness.directory.appendingPathComponent("Menu.csv")
        _ = try await ZenitScripting.export(document: harness.document, to: scriptedCSV, format: .csv)
        try ProjectWindowController.writeLedgerCSV(core: harness.core, includeTrail: false, to: menuCSV)
        #expect(try Data(contentsOf: scriptedCSV) == Data(contentsOf: menuCSV))
    }

    // MARK: - R-028

    @Test("R-028: Share Last Export shares the drawing export just written")
    func drawingExportIsTheLastExport() async throws {
        let harness = try await Fix2Harness.make("R028.pdf")
        defer { harness.tearDown() }
        #expect(ShareExport.target(for: harness.document) == .nothingExported)
        let url = harness.directory.appendingPathComponent("Clean.pdf")
        try await harness.controller.writeDrawing(.clean, for: harness.document, to: url)
        // Old: .nothingExported — only the two ledger paths recorded the file.
        #expect(ShareExport.target(for: harness.document) == .file(url))
    }

    // MARK: - R-029

    @Test("R-029: on a Quick PDF, Sync, Disconnect and Share Review File are disabled, and a scripted call says why")
    func sharedReviewRowsNeedAProject() async throws {
        let harness = try await Fix2Harness.make("R029.pdf", calibrate: false)
        defer { harness.tearDown() }
        let state = ZenitAppCommandWindowState(controller: harness.controller)
        for command in [ZenitAppCommand.syncSharedReview, .disconnectSharedReview, .shareReviewFile] {
            // Old: enabled (rule .drawing) and silently did nothing.
            #expect(!ZenitAppCommandTable.validate(command, item: nil, state: state), "\(command)")
        }
        #expect(ZenitAppCommandTable.validate(.connectSharedReview, item: nil, state: state), "Connect explains its refusal")
        let recorded = await ZenitModalPresenter.answeringAsync { _ in .button(0) } perform: {
            _ = await SharedReviewCommands.syncNow(document: harness.document)
        }
        #expect(recorded.contains { $0.identifier == SharedReviewCommands.refusalIdentifier && $0.detail.contains("Create Zenit PDF Project") })
    }

    @Test("R-029: Disconnect says it happened")
    func disconnectPostsANote() async throws {
        let harness = try await Fix2Harness.make("R029d.pdf", calibrate: false)
        defer { harness.tearDown() }
        _ = try await Self.saveAsProject(harness)
        let previous = SharedReviewCommands.defaults
        SharedReviewCommands.defaults = ReviewPreferences(defaults: nil)
        defer { SharedReviewCommands.defaults = previous }
        await SharedReviewCommands.disconnect(document: harness.document)
        // Old: nothing posted.
        #expect(harness.core.document.warnings.contains { $0.id == SharedReviewCommands.noteID })
    }

    // MARK: - R-030 / R-036

    @Test("R-030: closing a project stops its shared-review watcher")
    func closingStopsTheWatcher() async throws {
        let harness = try await Fix2Harness.make("R030.pdf", calibrate: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await Self.saveAsProject(harness)
        let folder = harness.directory.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SharedReviewAutoSync.start(document: harness.document, folder: folder, participant: "r030", registersPresenter: false)
        #expect(SharedReviewAutoSync.watcher(for: harness.document) != nil)
        harness.document.close()
        // Old: still registered, its timer running, until Disconnect.
        #expect(SharedReviewAutoSync.watcher(for: harness.document) == nil)
    }

    @Test("R-036: the watcher's 'changed here' signal is the document's change counter, not a hash of every markup")
    func watcherSyncsOnTheChangeCounter() async throws {
        let harness = try await Fix2Harness.make("R036.pdf", calibrate: false)
        defer { harness.tearDown() }
        _ = try await Self.saveAsProject(harness)
        let folder = harness.directory.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = SharedReviewCommands.defaults
        SharedReviewCommands.defaults = ReviewPreferences(defaults: nil)
        defer {
            SharedReviewCommands.defaults = previous
            SharedReviewAutoSync.stop(document: harness.document)
        }
        let watcher = SharedReviewAutoSync.start(document: harness.document, folder: folder, participant: "r036", registersPresenter: false)
        _ = await watcher.tick()
        #expect(watcher.syncCount == 1, "the first look always syncs")
        // No folder is connected, so each sync has nothing to sync with. That is not a failed
        // sync (U-009): no backoff, so every tick below is decided by the change counter alone.
        #expect(watcher.consecutiveFailures == 0)
        #expect(watcher.retryNotBefore == .distantPast)
        _ = await watcher.tick()
        #expect(watcher.syncCount == 1, "nothing changed")
        let revision = harness.document.localChangeRevision
        harness.document.updateChangeCount(.changeDone)
        #expect(harness.document.localChangeRevision == revision + 1)
        _ = await watcher.tick()
        // Old: 1 — the markup hash had not moved, so an edit that did not touch a markup
        // (and every hash of every markup, every four seconds) decided.
        #expect(watcher.syncCount == 2)
        harness.document.updateChangeCount(.changeAutosaved)
        _ = await watcher.tick()
        #expect(watcher.syncCount == 2, "an autosave is not a change made here")
        harness.document.updateChangeCount(.changeCleared)
    }

    // MARK: - R-031

    @Test("R-031: an edit that lands while a save is running keeps the document edited")
    func editDuringSaveStaysUnsaved() async throws {
        let harness = try await Fix2Harness.make("R031.pdf")
        defer { harness.tearDown() }
        let package = try await Self.saveAsProject(harness)
        #expect(!harness.document.isDocumentEdited)
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 250, y: 10)])
        })
        #expect(await AppTestSupport.wait { harness.document.isDocumentEdited })
        var hookRan = false
        harness.document.packageSaveWillWriteHook = { [weak document = harness.document] in
            hookRan = true
            // The person's next edit, after the snapshot was taken and before the save ends.
            document?.updateChangeCount(.changeDone)
        }
        defer { harness.document.packageSaveWillWriteHook = nil }
        try await Self.save(harness.document, to: package, .saveOperation)
        #expect(hookRan)
        // Old: false — the save cleared the count outright and the edit read as saved.
        #expect(harness.document.isDocumentEdited)
        harness.document.packageSaveWillWriteHook = nil
        try await Self.save(harness.document, to: package, .saveOperation)
        #expect(!harness.document.isDocumentEdited, "a save with nothing arriving meanwhile still clears")
    }
}

extension ZenitModalPresenter {
    /// ``answering(_:perform:)`` for an asynchronous body, restoring the handler afterwards.
    static func answeringAsync(
        _ answer: @escaping @MainActor (ZenitModalRequest) -> ZenitModalAnswer,
        perform body: () async throws -> Void
    ) async rethrows -> [ZenitModalRequest] {
        let previous = handler
        let before = recorded.count
        handler = answer
        defer { handler = previous }
        try await body()
        return Array(recorded.dropFirst(before))
    }
}
