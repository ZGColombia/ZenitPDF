import AppKit
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFServiceClient
import ZPDFServiceWire
@testable import ZenitPDFAppKit

/// Loop iteration 5, export-pdf, in the app. Each test says what the code before the fix did.
///
/// V-051: the writers that hand a save panel's file to the repair service — Optimize or Protect a
/// Copy, a burned-in Form Fill, the structure-preserving Marked export — wrote hidden siblings
/// of the chosen file (the Marked staging file, the parked destination, the client's staging
/// file). The shipped app is sandboxed with `files.user-selected.read-write` only, and a save
/// panel grants the chosen file and nothing beside it (C-09). Two kinds of proof: a recording
/// executor lists the destination's folder at the moment the service writes, and the real repair
/// worker runs under `sandbox-exec` with the save panel's grant shape.
///
/// V-053 / V-054: Clean Up Scanned Sheets reads the drawing of the sheet on screen, with its
/// password.
@MainActor
@Suite("Iteration 5 — export-pdf (app)", .appTierSerialised, .serialized)
struct Iter5ExportPDFAppTests {

    // MARK: - A repair service that records what it was given

    /// One call to the recording service: its input, where it was told to write, and what the
    /// destination's folder held at that moment.
    struct Call: Sendable {
        let input: URL
        let outputPath: String?
        let destinationFolderListing: [String]
    }

    actor Log {
        let watched: URL
        private(set) var calls: [Call] = []
        init(watching folder: URL) { watched = folder }
        func record(_ call: Call) { calls.append(call) }
    }

    /// Writes its input's bytes to the output it is handed — a service that changes nothing —
    /// or fails, as a service that refused the file would.
    struct RecordingRepair: RepairInProcessExecuting {
        let log: Log
        var fails = false

        func perform(request: RepairWireRequest, inputAt input: URL, outputPath: String?) async -> RepairReplyOutcome {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: log.watched.path))?.sorted() ?? []
            await log.record(Call(input: input, outputPath: outputPath, destinationFolderListing: listing))
            if fails { return .failure(WireFailure(domain: "Iter5", code: 1, message: "refused")) }
            guard let outputPath, let data = try? Data(contentsOf: input),
                  FileManager.default.createFile(atPath: outputPath, contents: data)
            else { return .failure(WireFailure(domain: "Iter5", code: 2, message: "no output")) }
            return .success(RepairWireReply(message: "copied", warnings: [], warningCount: 0, outputByteCount: Int64(data.count)))
        }
    }

    static func folder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-it5-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    // MARK: - V-051: Optimize or Protect a Copy

    @Test("V-051: Optimize Copy onto an existing chosen file writes nothing beside it, and the service stages in a private folder")
    func optimizeCopyWritesNothingBesideTheChosenFile() async throws {
        let source = try AppTestSupport.writeFixturePDF(named: "It5 Plan.pdf")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let chosenFolder = try Self.folder("chosen")
        defer { try? FileManager.default.removeItem(at: chosenFolder) }
        let chosen = chosenFolder.appendingPathComponent("Chosen.pdf")
        try Data("OLD".utf8).write(to: chosen)

        let log = Log(watching: chosenFolder)
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .inProcess(RecordingRepair(log: log)), maximumRestarts: 0)
        defer { DamagedDrawingRepair.clientOverride = nil }
        _ = try await DocumentCopyTransform.run(source: source, password: nil, output: chosen, choices: .init())

        let call = try #require(await log.calls.first)
        // Old: [".zpdf-replaced-….pdf", ".zpdf-staging-….pdf"] — the chosen file parked aside as a
        // hidden sibling and the service's output staged as another, both refused by the sandbox.
        #expect(call.destinationFolderListing == ["Chosen.pdf"], "\(call.destinationFolderListing)")
        let outputPath = try #require(call.outputPath)
        let staging = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        #expect(Self.resolved(staging) != Self.resolved(chosenFolder), "the service still stages beside the chosen file")
        #expect(!FileManager.default.fileExists(atPath: staging.path), "the staging folder outlived the write")
        #expect(try Data(contentsOf: chosen) == Data(contentsOf: source), "the copy is in place")
        #expect(try FileManager.default.contentsOfDirectory(atPath: chosenFolder.path) == ["Chosen.pdf"])
    }

    @Test("V-051: a transform that fails leaves the chosen file exactly as it was, and nothing beside it")
    func failedTransformLeavesTheChosenFile() async throws {
        let source = try AppTestSupport.writeFixturePDF(named: "It5 Plan.pdf")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let chosenFolder = try Self.folder("failed")
        defer { try? FileManager.default.removeItem(at: chosenFolder) }
        let chosen = chosenFolder.appendingPathComponent("Chosen.pdf")
        try Data("OLD".utf8).write(to: chosen)

        let log = Log(watching: chosenFolder)
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .inProcess(RecordingRepair(log: log, fails: true)), maximumRestarts: 0)
        defer { DamagedDrawingRepair.clientOverride = nil }
        await #expect(throws: ZPDFServiceError.self) {
            _ = try await DocumentCopyTransform.run(source: source, password: nil, output: chosen, choices: .init())
        }
        // Old: the same bytes came back, but only after being parked as `.zpdf-replaced-…` and
        // restored — a move the sandbox refuses before the service is even asked.
        #expect(try Data(contentsOf: chosen) == Data("OLD".utf8))
        let call = try #require(await log.calls.first)
        #expect(call.destinationFolderListing == ["Chosen.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: chosenFolder.path) == ["Chosen.pdf"])
        // The private staging folder the service was handed goes with the failure too.
        let staging = URL(fileURLWithPath: try #require(call.outputPath)).deletingLastPathComponent()
        #expect(Self.resolved(staging) != Self.resolved(chosenFolder))
        #expect(!FileManager.default.fileExists(atPath: staging.path), "the staging folder outlived the failed transform")
    }

    // MARK: - V-051: Export Marked PDF, structure-preserving

    @Test("V-051: Export Marked PDF stages the appended drawing in a private folder, and the rewrite runs")
    func markedExportStagesPrivately() async throws {
        let harness = try await Fix2Harness.make("It5 Marked Plan.pdf", calibrate: false)
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, subject: "Wall")
        let exports = try Self.folder("marked")
        defer { try? FileManager.default.removeItem(at: exports) }
        let url = exports.appendingPathComponent("Marked.pdf")
        try Data("OLD".utf8).write(to: url)

        let log = Log(watching: exports)
        DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .inProcess(RecordingRepair(log: log)), maximumRestarts: 0)
        defer { DamagedDrawingRepair.clientOverride = nil }
        let job = try await FlattenedDrawingExport.job(for: harness.document, set: nil)
        let content = await FlattenedDrawingExport.contentSource(for: harness.document)
        let marked = try await FlattenedDrawingExport.writeMarked(job: job, content: content, document: harness.document, to: url)

        #expect(marked.path == .appended(rewritten: true))
        let call = try #require(await log.calls.first)
        // Old: the service was handed `.zpdf-marked-….pdf` beside Marked.pdf, and the listing held
        // it and `.zpdf-staging-….pdf`; in the sandbox the first write was refused and the pages
        // were rebuilt, losing bookmarks and links.
        #expect(Self.resolved(call.input.deletingLastPathComponent()) != Self.resolved(exports), "\(call.input.path)")
        #expect(call.destinationFolderListing == ["Marked.pdf"], "\(call.destinationFolderListing)")
        #expect(!FileManager.default.fileExists(atPath: call.input.deletingLastPathComponent().path), "the marked staging folder outlived the export")
        #expect(PDFDocument(url: url)?.pageCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path) == ["Marked.pdf"])
    }

    @Test("V-051: the rebuilt path's reason is a sentence, never an error dump")
    func rebuiltReasonIsASentence() {
        let cocoa = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/tmp/x.pdf"])
        // Old: String(describing:) — `Error Domain=NSCocoaErrorDomain Code=513 "…" UserInfo={…}`.
        let reason = FlattenedDrawingExport.reason(cocoa)
        #expect(!reason.contains("Domain=") && !reason.contains("UserInfo"), "\(reason)")
        #expect(reason == cocoa.localizedDescription)
        let refusal = ExportError.annotationExportRefused("the drawing is encrypted")
        #expect(FlattenedDrawingExport.reason(refusal) == refusal.description)
        // Old: "The operation couldn’t be completed. (ZPDFExport.PDFFlattenError error 1.)" —
        // PDFFlattenError was not a LocalizedError, so its words never reached the report.
        let unusable = PDFFlattenError.unusablePage(index: 1, reason: "the crop box is empty")
        #expect(FlattenedDrawingExport.reason(unusable) == "page 1 cannot be laid out on paper: the crop box is empty")
        #expect(unusable.localizedDescription == unusable.description)
    }

    /// Every character sequence that marks a quoted error dump rather than a sentence.
    static func assertSentence(_ reason: String, _ label: String) {
        for dump in ["Domain=", "UserInfo", "couldn’t be completed", "couldn't be completed"] {
            #expect(!reason.contains(dump), "\(label): \(reason)")
        }
    }

    @Test("V-051: the errors a failed appended write really throws read as sentences in the report")
    func appendedWriteFailuresAreSentences() async throws {
        let harness = try await Fix2Harness.make("It5 Reason Plan.pdf", calibrate: false)
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, subject: "Wall")
        let job = try await FlattenedDrawingExport.job(for: harness.document, set: nil)
        let marked = job.pages.filter { !$0.markups.isEmpty }
        try #require(!marked.isEmpty)
        let source = try #require(harness.document.drawing?.url)
        let folder = try Self.folder("reason")
        defer { try? FileManager.default.removeItem(at: folder) }
        let options = LayeredMarkupExporter.Options(asSwitchableLayer: false)
        func thrown(_ body: () throws -> Void) -> (any Error)? {
            do { try body(); return nil } catch { return error }
        }

        // The destination's folder is gone (a volume unmounted, a folder deleted under the panel).
        // Old: fileWriteFailed(reason: String(describing:)) — `Error Domain=NSCocoaErrorDomain
        // Code=4 "…" UserInfo={NSFilePath=…, NSUnderlyingError=…}` inside the report's sentence.
        let missingFolder = folder.appendingPathComponent("gone", isDirectory: true).appendingPathComponent("Marked.pdf")
        let writeError = try #require(thrown {
            _ = try LayeredMarkupExporter().write(source: source, pages: marked, to: missingFolder, options: options)
        })
        guard case .fileWriteFailed(let path, _)? = writeError as? ExportError else {
            Issue.record("expected ExportError.fileWriteFailed, got \(writeError)"); return
        }
        #expect(path == missingFolder.path)
        let writeReason = FlattenedDrawingExport.reason(writeError)
        Self.assertSentence(writeReason, "write")
        #expect(writeReason.hasPrefix("could not write \(missingFolder.path): "), "\(writeReason)")

        // The drawing vanished between the job and the write.
        // Old: layeredSourceUnreadable("… could not be read: Error Domain=NSCocoaErrorDomain Code=260 …").
        let missingSource = folder.appendingPathComponent("Moved.pdf")
        let readError = try #require(thrown {
            _ = try LayeredMarkupExporter().write(
                source: missingSource, pages: marked, to: folder.appendingPathComponent("Out.pdf"), options: options)
        })
        guard case .layeredSourceUnreadable? = readError as? ExportError else {
            Issue.record("expected ExportError.layeredSourceUnreadable, got \(readError)"); return
        }
        let readReason = FlattenedDrawingExport.reason(readError)
        Self.assertSentence(readReason, "read")
        #expect(readReason.hasPrefix("the drawing at \(missingSource.path) could not be read: "), "\(readReason)")
        #expect(!readReason.hasSuffix(".."), "\(readReason)")

        // The export pointed at the drawing itself — a PDFFlattenError.
        // Old: "The operation couldn’t be completed. (ZPDFExport.PDFFlattenError error 3.)".
        let selfError = try #require(thrown {
            _ = try LayeredMarkupExporter().write(source: source, pages: marked, to: source, options: options)
        })
        #expect(selfError is PDFFlattenError, "\(selfError)")
        let selfReason = FlattenedDrawingExport.reason(selfError)
        Self.assertSentence(selfReason, "self")
        #expect(selfReason == "could not write \(source.path): the destination is the drawing being exported")
    }

    // MARK: - V-051: the real repair worker under the save panel's grant

    /// `realpath(3)`: seatbelt matches the canonical path (`/private/var/…`); both spellings go in.
    static func spellings(_ url: URL) -> [String] {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(url.path, &buffer) else { return [url.path] }
        return Array(Set([url.path, String(cString: resolved)]))
    }

    /// Every write under `root` denied except `granted` — the one file a save panel names.
    static func fileGrantProfile(root: URL, granted: URL) -> String {
        let relative = String(granted.path.dropFirst(root.path.count + 1))
        return (["(version 1)", "(allow default)"]
            + spellings(root).map { "(deny file-write* (subpath \"\($0)\"))" }
            + spellings(root).map { "(allow file-write* (subpath \"\($0)/\(relative)\"))" }).joined(separator: "\n")
    }

    static func sandboxed(_ executable: String, _ arguments: [String], profile: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profile.path, executable] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("V-051: Optimize Copy and a burned-in Form Fill succeed with the repair worker confined to the chosen file's grant")
    func repairWorkerUnderTheSavePanelGrant() async throws {
        let root = try Self.folder("sandbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try Self.folder("sandbox-tools")
        defer { try? FileManager.default.removeItem(at: tools) }
        let sourceFolder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let drawing = sourceFolder.appendingPathComponent("Plan.pdf")
        try Data(contentsOf: AppTestSupport.writeFixturePDF(named: "It5 Sandbox.pdf")).write(to: drawing)
        let form = sourceFolder.appendingPathComponent("RFI.pdf")
        try NLPDFR2FormFillTests.rfiForm(at: form)

        let worker = try NLPDFR2FormFillTests.productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.isExecutableFile(atPath: worker.path), "zpdf-repair-worker is built next to the tests")

        for chosenName in ["Optimized.pdf", "Burned.pdf"] {
            let chosen = root.appendingPathComponent(chosenName)
            let profile = tools.appendingPathComponent("\(chosenName).sb")
            try Self.fileGrantProfile(root: root, granted: chosen).write(to: profile, atomically: true, encoding: .utf8)
            // The profile bites before it is trusted: the old staging sibling is refused, the
            // chosen file is allowed (a gate that denies nothing proves nothing).
            let sibling = root.appendingPathComponent(".zpdf-staging-probe.pdf")
            #expect(try Self.sandboxed("/usr/bin/touch", [sibling.path], profile: profile) != 0, "the profile let a sibling be written")
            #expect(!FileManager.default.fileExists(atPath: sibling.path))
            #expect(try Self.sandboxed("/usr/bin/touch", [chosen.path], profile: profile) == 0, "the profile refused the chosen file")
            // Replace in the save panel: the chosen file is already there.
            try Data("OLD".utf8).write(to: chosen)

            let wrapper = tools.appendingPathComponent("worker-\(chosenName).sh")
            try "#!/bin/sh\nexec /usr/bin/sandbox-exec -f '\(profile.path)' '\(worker.path)' \"$@\"\n"
                .write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            DamagedDrawingRepair.clientOverride = ZPDFRepairServiceClient(backend: .subprocess(executableURL: wrapper), maximumRestarts: 0)
            defer { DamagedDrawingRepair.clientOverride = nil }

            // Old: the worker was told to write `.zpdf-staging-….pdf` beside the chosen file, the
            // grant refused it, and both commands failed on every chosen file.
            if chosenName == "Optimized.pdf" {
                _ = try await DocumentCopyTransform.run(source: drawing, password: nil, output: chosen, choices: .init(downsamplesPictures: false))
                #expect(PDFDocument(url: chosen)?.pageCount == 1)
            } else {
                _ = try await FormFill.write(source: form, password: nil, values: ["Project": .text("Level 3 slab")], flatten: true, to: chosen)
                let flat = try #require(PDFDocument(url: chosen))
                #expect(flat.page(at: 0)?.annotations.contains { $0.type == "Widget" } == false, "no widgets are left")
            }
            await DamagedDrawingRepair.client.shutdown()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Burned.pdf", "Optimized.pdf", "source"])
    }

    // MARK: - V-053: the drawing of the sheet on screen

    @Test("V-053: 'This sheet only' and 'All sheets' on an added drawing's sheet clean that drawing, never the primary")
    func scanCleanupReadsTheCurrentSheetsDrawing() async throws {
        let harness = try await Fix2Harness.make("It5 Scan A.pdf", calibrate: false)
        let b = try AppTestSupport.writeFixturePDF(named: "It5 Scan B.pdf", pageCount: 2)
        defer {
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let added = try await Iter3ShellGlueTests.addDrawing(harness, b)
        let sheet = try #require(added.drawing.pages.last)
        harness.core.document.goToPage(id: sheet.id.rawValue)
        #expect(await AppTestSupport.wait { harness.core.document.currentPageID == sheet.id.rawValue })
        let options = ScanCleanup.Options(straightens: false, enhancement: .none, dpi: 72)

        let one = harness.directory.appendingPathComponent("B sheet.pdf")
        let reports = try await ScanCleanupCommand.run(document: harness.document, options: options, currentSheetOnly: true, to: one)
        // Old: the sheet was looked up in the primary drawing, not found, so every page of
        // "It5 Scan A" (one page) was rasterised: reports [0], a one-page file.
        #expect(reports.map(\.pageIndex) == [sheet.index])
        #expect(PDFDocument(url: one)?.pageCount == 2, "B's two sheets, the second cleaned")

        let all = harness.directory.appendingPathComponent("B all.pdf")
        let every = try await ScanCleanupCommand.run(document: harness.document, options: options, currentSheetOnly: false, to: all)
        #expect(every.map(\.pageIndex) == [0, 1])
        #expect(PDFDocument(url: all)?.pageCount == 2)

        // The panel names the drawing it cleans; never over another drawing of the project.
        let name = try #require(ScanCleanupCommand.source(for: harness.document)?.name)
        #expect(name == added.displayName)
        #expect(ScanCleanupCommand.panelMessage(for: harness.document, drawingName: name).contains("“\(added.displayName)”"))
        let primary = try #require(harness.document.drawing).url
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            _ = try await ScanCleanupCommand.run(document: harness.document, options: options, currentSheetOnly: true, to: primary)
        }
    }

    // MARK: - V-054: the drawing's password

    @Test("V-054: a password-protected drawing is cleaned with the password it was opened with")
    func scanCleanupUnlocksTheDrawing() async throws {
        let password = "zenit-it5-scan"
        let url = try AppTestSupport.writeLockedFixturePDF(named: "It5 Locked Scan.pdf", password: password)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previousPrompt = ZenitPDFProjectDocument.passwordPrompt
        ZenitPDFProjectDocument.passwordPrompt = { _ in password }
        defer { ZenitPDFProjectDocument.passwordPrompt = previousPrompt }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && !document.isLoading })
        #expect(document.drawingPassword == password)

        let output = url.deletingLastPathComponent().appendingPathComponent("Cleaned.pdf")
        // Old: ScanCleanup.Refusal.unreadablePage(0) — "sheet 1 of the drawing could not be read".
        let reports = try await ScanCleanupCommand.run(
            document: document, options: .init(straightens: false, enhancement: .none, dpi: 72), currentSheetOnly: false, to: output
        )
        #expect(reports.map(\.pageIndex) == [0])
        #expect(reports.allSatisfy { $0.wasCleaned })
        #expect(PDFDocument(url: output)?.pageCount == 1)
    }

    // MARK: - V-052: the sheet's own viewport is marked as the sheet's

    @Test("V-052: the sheet's scale is written as the sheet-wide viewport, so the drawing's own viewports go after it")
    func sheetViewportIsMarkedSheetWide() async throws {
        let harness = try await Fix2Harness.make("It5 Viewports.pdf")
        defer { harness.tearDown() }
        let page = try #require(harness.document.drawing?.pages.first)
        let viewports = await StandardAnnotationExport.viewports(for: page, session: harness.core.session)
        // Old: no coverage — the writer could not tell the sheet's scale from a Scale Region and
        // replaced the page's whole /VP with its own.
        #expect(viewports.map(\.coverage) == [.sheet])
    }
}
