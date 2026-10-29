import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 1, re-fix of area app-shell-glue: what the checker found unresolved in R-028,
/// R-024 and R-039. Every test states the old output it fails with. Headless throughout: windows
/// are never ordered front, every panel is answered by injection.
@MainActor
@Suite("Iteration 1 re-fix — app shell glue", .appTierSerialised)
struct Iter1RShellGlueTests {

    // MARK: - R-028

    @Test("R-028: Export Arranged Set, Extract Pages, the Review Report, XFDF and the review file are each Share Last Export's file")
    func everyExportIsTheLastExport() async throws {
        let harness = try await Fix2Harness.make("R028r.pdf", pageCount: 2, calibrate: false)
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
        }
        let document = harness.document
        #expect(ShareExport.target(for: document) == .nothingExported)

        // Export Arranged Set…, through its own save panel.
        let arranged = harness.directory.appendingPathComponent("Arranged.pdf")
        ZenitModalPresenter.handler = { request in
            request.identifier == ZenitPDFProjectDocument.exportArrangedSetPanelIdentifier ? .urls([arranged]) : .dismissed
        }
        document.exportArrangedSet(window: nil)
        // Old: the file was written and Share Last Export still said nothing had been exported.
        #expect(await AppTestSupport.wait(upTo: 20) { ShareExport.target(for: document) == .file(arranged) })

        // Extract Pages… on one drawing (the write half the panel's answer runs).
        let extract = harness.directory.appendingPathComponent("Extract.pdf")
        let drawing = try #require(document.drawing)
        #expect(await document.writeExtract(indices: [1], from: drawing.url, password: nil, to: extract) != nil)
        #expect(ShareExport.target(for: document) == .file(extract), "old: still Arranged.pdf")

        // The Review Report, as CSV, through its save panel.
        let report = harness.directory.appendingPathComponent("Review.csv")
        ZenitModalPresenter.handler = { request in
            request.identifier == ReviewReportExport.panelIdentifier ? .urls([report]) : .dismissed
        }
        ReviewReportExport.present(document: document, markupIDs: [], window: nil)
        #expect(await AppTestSupport.wait { ShareExport.target(for: document) == .file(report) }, "old: still Extract.pdf")
        #expect(FileManager.default.fileExists(atPath: report.path))

        // Export Review as XFDF….
        let xfdf = harness.directory.appendingPathComponent("Review.xfdf")
        #expect(await ReviewXFDFFlow.write(document: document, to: xfdf))
        #expect(ShareExport.target(for: document) == .file(xfdf), "old: still Review.csv")

        // Export Review File… needs a project; Share Review File…'s temporary copy is not an export.
        _ = try await Iter1ShellGlueTests.saveAsProject(harness)
        let reviewFile = harness.directory.appendingPathComponent("Review.zpdfreview")
        #expect(await ReviewFileFlow.write(document: document, to: reviewFile))
        #expect(ShareExport.target(for: document) == .file(reviewFile), "old: still Review.xfdf")
        var shared: URL?
        ReviewFileFlow.sharingPresenter = { url, _ in shared = url }
        defer { ReviewFileFlow.sharingPresenter = nil }
        ReviewFileFlow.share(document: document, window: nil)
        #expect(await AppTestSupport.wait { shared != nil })
        #expect(ShareExport.target(for: document) == .file(reviewFile), "the share picker's temporary copy is not the last export")
    }

    @Test("R-028: a ledger confirmation's Show in Finder reveals the ledger file after a later drawing export")
    func confirmationRevealsItsOwnFile() async throws {
        let harness = try await Fix2Harness.make("R028n.pdf")
        defer { harness.tearDown() }
        try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, subject: "Wall")
        let ledger = harness.directory.appendingPathComponent("Ledger.xlsx")
        await harness.controller.writeProjectedExport(
            format: .xlsx, for: harness.document, core: harness.core, includeTrail: false, to: ledger
        ).value
        let note = try #require(harness.core.status.warnings.first { $0.id == ExportCompletion.warningID })
        #expect(note.title.contains("Ledger.xlsx"))

        // A drawing export while the ledger's note is still showing.
        let drawing = harness.directory.appendingPathComponent("Clean.pdf")
        try await harness.controller.writeDrawing(.clean, for: harness.document, to: drawing)
        #expect(ShareExport.target(for: harness.document) == .file(drawing), "Share Last Export shares the newest file")
        #expect(harness.core.status.warnings.first { $0.id == ExportCompletion.warningID }?.title.contains("Ledger.xlsx") == true)

        var revealed: [URL] = []
        let previous = ExportCompletion.revealer
        ExportCompletion.revealer = { revealed.append($0) }
        defer { ExportCompletion.revealer = previous }
        #expect(ExportCompletion.handleAction(for: ExportCompletion.warningID, document: harness.document))
        // Old: [Clean.pdf] — the note said “Ledger.xlsx” and Finder showed the drawing.
        #expect(revealed == [ledger])
    }

    // MARK: - R-024

    @Test("R-024: Level 1, then Level 2 alone, then Level 1 again into one folder keep two files, and a resume is only ever against its own")
    func twoRunsNeverShareAnOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r024r-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Level 1/Plan.pdf"), b = root.appendingPathComponent("Level 2/Plan.pdf")
        for (url, pages) in [(a, 1), (b, 2)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try AppTestSupport.writeFixturePDF(named: "Plan.pdf", pageCount: pages), to: url)
        }
        let aBytes = try Data(contentsOf: a), bBytes = try Data(contentsOf: b)
        #expect(aBytes != bBytes)
        let out = root.appendingPathComponent("out", isDirectory: true)
        var steps = BatchFileProcessor.Steps()
        steps.reduceSize = true
        func run(_ input: URL) async throws -> BatchFileProcessor.Item {
            let report = try await BatchFileProcessor.run(
                inputs: [input.deletingLastPathComponent()], steps: steps, outputFolder: out,
                transform: Iter1ShellGlueTests.copyTransform()
            )
            return try #require(report.items.first)
        }

        let first = try await run(a)
        #expect(first.status == .done)
        #expect(first.output?.lastPathComponent == "Plan — Processed.pdf")

        let second = try await run(b)
        #expect(second.status == .done)
        // Old: "Plan — Processed.pdf" again — Level 1's file replaced by Level 2's result.
        #expect(second.output?.lastPathComponent == "Plan (Level 2) — Processed.pdf")
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".pdf") }.sorted()
        #expect(pdfs == ["Plan (Level 2) — Processed.pdf", "Plan — Processed.pdf"], "two distinct files")
        #expect(try Data(contentsOf: out.appendingPathComponent("Plan — Processed.pdf")) == aBytes, "Level 1's result is still there")
        #expect(try Data(contentsOf: out.appendingPathComponent("Plan (Level 2) — Processed.pdf")) == bBytes)

        // Old: skipped "already processed" against a file that held Level 2's result.
        let third = try await run(a)
        #expect(third.status == .skipped("already processed in an earlier run"))
        let thirdOutput = try #require(third.output)
        #expect(try Data(contentsOf: thirdOutput) == aBytes, "a resume is reported only against Level 1's own result")
        let fourth = try await run(b)
        #expect(fourth.status == .skipped("already processed in an earlier run"))
        #expect(try Data(contentsOf: try #require(fourth.output)) == bBytes)
    }

    @Test("R-024: a state that records one output for two inputs resumes neither, and a name in the state is never handed to another input")
    func sharedLegacyClaimsResumeNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r024s-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Level 1/Plan.pdf"), b = root.appendingPathComponent("Level 2/Plan.pdf")
        for (url, pages) in [(a, 1), (b, 2)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try AppTestSupport.writeFixturePDF(named: "Plan.pdf", pageCount: pages), to: url)
        }
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let plain = "Plan — Processed.pdf"
        // What the first R-024 fix left after two runs: both inputs claim one file (it holds B's).
        try Data(contentsOf: b).write(to: out.appendingPathComponent(plain))
        let keyA = a.standardizedFileURL.path, keyB = b.standardizedFileURL.path
        BatchFileProcessor.writeState(BatchFileProcessor.State(
            finished: [keyA: try #require(BatchFileProcessor.sha256(of: a)), keyB: try #require(BatchFileProcessor.sha256(of: b))],
            outputs: [keyA: plain, keyB: plain]
        ), in: out)
        var steps = BatchFileProcessor.Steps()
        steps.reduceSize = true
        let report = try await BatchFileProcessor.run(
            inputs: [a.deletingLastPathComponent()], steps: steps, outputFolder: out,
            transform: Iter1ShellGlueTests.copyTransform()
        )
        // Old: skipped "already processed" against B's result.
        #expect(report.items.first?.status == .done)
        #expect(try Data(contentsOf: try #require(report.items.first?.output)) == Data(contentsOf: a))
        let state = BatchFileProcessor.readState(in: out)
        #expect(state.outputs?[keyB] == nil && state.finished[keyB] == nil, "B no longer claims a file it may not hold")

        // The pure rule: an input keeps its own recorded name; another input never gets it.
        let names = BatchFileProcessor.outputNames(for: [b], claimed: [keyA: plain])
        #expect(names[b] == "Plan (Level 2) — Processed.pdf", "old: the plain name, over A's file")
        #expect(BatchFileProcessor.outputNames(for: [a], claimed: [keyA: "Plan (Level 1) — Processed.pdf"])[a]
                == "Plan (Level 1) — Processed.pdf", "an input keeps the name the state records for it")
    }

    // MARK: - R-039

    @Test("R-039: the shell modal gate forbids a direct beginSheet, as the suite does, and names the door as its exemption")
    func shellGateForbidsDirectSheets() throws {
        let script = try String(
            contentsOf: ModalInjectionTests.repositoryRoot.appendingPathComponent("Scripts/verify-no-uninjected-modals.sh"),
            encoding: .utf8
        )
        // Old: exemption 3 allowed `NSWindow.beginSheet` of a workflow sheet and no pattern named it.
        #expect(script.contains("readonly SHEET_PATTERN='\\.beginSheet\\('"))
        #expect(script.contains("\"${SHEET_PATTERN}\""), "the pattern is scanned, not only declared")
        #expect(script.contains("gsub(/ZenitModalPresenter\\.beginSheet\\(/"), "the door is struck out, not the whole line")
        #expect(script.contains("must go through that door"))
        #expect(!script.contains("**`NSWindow.beginSheet` of a workflow sheet.**"))
    }
}
