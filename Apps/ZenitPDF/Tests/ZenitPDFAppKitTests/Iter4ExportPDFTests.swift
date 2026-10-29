import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 4, export-pdf, in the app: C-09 (redaction across the drawings of a project)
/// and the note half of U-053 (Clean Up Scanned Sheets says which sheets it could not clean at
/// the resolution asked for). No modal is drawn: the confirmation and the panels are answered
/// by injection.
///
/// C-09 re-fix: several marked drawings' copies go into a folder an open panel chooses, never
/// beside a save panel's file — the sandboxed app is granted only the file a save panel names.
/// `Iter4RedactionSandboxTests` (ZPDFExport) runs these writes under `sandbox-exec` with that
/// grant shape; these tests prove the app asks for the folder and hands it to the same writer.
@MainActor
@Suite("Iteration 4 — export-pdf (app)", .appTierSerialised)
struct Iter4ExportPDFAppTests {

    /// A one-sheet 420 × 300 pt drawing with `secret` at (70, 192) and `kept` at (70, 250), both
    /// real text in Helvetica 18.
    static func textDrawing(named name: String, secret: String, kept: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-it4-redact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for (text, y) in [(secret, 192.0), (kept, 250.0)] {
            context.textPosition = CGPoint(x: 70, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])), context)
        }
        context.stroke(CGRect(x: 20, y: 20, width: 380, height: 260))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// The box over the secret line of ``textDrawing(named:secret:kept:)``.
    static let secretBox = CGRect(x: 60, y: 180, width: 300, height: 40)

    static func text(of url: URL) -> String { PDFDocument(url: url)?.page(at: 0)?.string ?? "" }

    /// A project of drawing A (the harness's) and drawing B added after it; answers the harness,
    /// B's member, and each drawing's sheet.
    static func twoDrawings() async throws -> (Fix2Harness, DrawingSet.Member, ZPDFContracts.PageDescriptor, ZPDFContracts.PageDescriptor, URL) {
        let a = try Self.textDrawing(named: "Redact A.pdf", secret: "PRIMARYSECRET 111", kept: "Keep A")
        let b = try Self.textDrawing(named: "Redact B.pdf", secret: "ANNEXSECRET 222", kept: "Keep B")
        let harness = try await Fix2Harness.make("Redact A.pdf", calibrate: false, fixture: a)
        let added = try await Iter3ShellGlueTests.addDrawing(harness, b)
        let primarySheet = try #require(harness.document.drawing?.pages.first)
        let addedSheet = try #require(added.drawing.pages.first)
        return (harness, added, primarySheet, addedSheet, b)
    }

    @Test("C-09: marks on sheets of two drawings are applied per drawing, each into a copy of its own file")
    func redactionAcrossTwoDrawings() async throws {
        let (harness, added, primarySheet, addedSheet, b) = try await Self.twoDrawings()
        defer {
            RedactionWorkflow.clear(harness.document, canvas: harness.canvas)
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let primaryFile = try #require(harness.document.drawing).url
        let originals = (try Data(contentsOf: primaryFile), try Data(contentsOf: added.drawing.url))

        // Marked through the menu command, on each drawing's sheet in turn. Old: the drag on B's
        // sheet was refused with "This sheet comes from “Redact B”." (T-007), so B could not be
        // redacted in the project at all; before T-007 its box redacted page 1 of A.
        for (sheet, _) in [(primarySheet, "A"), (addedSheet, "B")] {
            harness.core.document.goToPage(id: sheet.id.rawValue)
            harness.canvas.onSnippetRegion = nil
            harness.controller.beginRedactionMark(for: harness.document)
            let armed = try #require(harness.canvas.onSnippetRegion)
            armed(PDFRectValue(x: Self.secretBox.minX, y: Self.secretBox.minY, width: Self.secretBox.width, height: Self.secretBox.height))
        }
        #expect(RedactionWorkflow.marks(for: harness.document).map(\.pageID) == [primarySheet.id.rawValue, addedSheet.id.rawValue])
        // The sheet on screen (B's) shows its own box.
        #expect(harness.canvas.automationOverlayForTesting?.hits.count == 1)

        let jobs = RedactionWorkflow.drawingMarks(for: harness.document)
        #expect(jobs.map(\.displayName) == ["Redact A", "Redact B"])
        #expect(jobs.map(\.source) == [primaryFile, added.drawing.url])

        // Apply through the command, the confirmation and the folder chooser answered by injection.
        let folder = harness.directory.appendingPathComponent("Redacted copies", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chosen = folder.appendingPathComponent("Redact A — Redacted.pdf")
        let beside = folder.appendingPathComponent("Redact B — Redacted.pdf")
        ZenitModalPresenter.reset()
        let previous = ZenitModalPresenter.handler
        defer { ZenitModalPresenter.handler = previous }
        ZenitModalPresenter.handler = { request in
            switch request.identifier {
            case RedactionWorkflow.confirmIdentifier: return .button(0)
            case RedactionWorkflow.folderPanelIdentifier: return .urls([folder])
            default: return .dismissed
            }
        }
        harness.controller.applyRedactions(for: harness.document)
        #expect(await AppTestSupport.wait(upTo: 30) {
            harness.core.document.warnings.contains { $0.id == RedactionWorkflow.resultNoteID }
        })
        let confirmation = try #require(ZenitModalPresenter.recorded.last { $0.identifier == RedactionWorkflow.confirmIdentifier })
        #expect(confirmation.title.contains("2 sheets of 2 drawings"), "\(confirmation.title)")
        #expect(confirmation.detail.contains("The marks are on “Redact A”, “Redact B”."), "\(confirmation.detail)")
        #expect(confirmation.detail.contains("in a folder you choose next"), "\(confirmation.detail)")
        // A folder chooser, and no save panel: a save panel's grant covers only the file it names,
        // and the copy the first fix wrote beside that file was refused in the sandboxed app.
        let chooser = try #require(ZenitModalPresenter.recorded.last { $0.identifier == RedactionWorkflow.folderPanelIdentifier })
        #expect(chooser.kind == .openPanel && chooser.buttons == ["Redact Here"], "\(chooser)")
        #expect(chooser.title.contains("2 redacted copies"), "\(chooser.title)")
        #expect(!ZenitModalPresenter.recorded.contains { $0.identifier == RedactionWorkflow.panelIdentifier })
        let panel = RedactionWorkflow.folderPanel(drawingCount: 2)
        #expect(panel.canChooseDirectories && !panel.canChooseFiles && panel.canCreateDirectories && !panel.allowsMultipleSelection)

        // Each copy holds its own drawing, with its own secret gone and the rest searchable.
        let a = Self.text(of: chosen), bCopy = Self.text(of: beside)
        #expect(!a.contains("PRIMARYSECRET") && a.contains("Keep A"), "\(a)")
        #expect(!bCopy.contains("ANNEXSECRET") && bCopy.contains("Keep B"), "\(bCopy)")
        #expect(PDFDocument(url: chosen)?.pageCount == 1 && PDFDocument(url: beside)?.pageCount == 1)
        let note = try #require(harness.core.document.warnings.first { $0.id == RedactionWorkflow.resultNoteID })
        #expect(note.title.contains("Redact A — Redacted.pdf") && note.title.contains("Redact B — Redacted.pdf"), "\(note.title)")
        // L-48: it read "1 areas removed on 1 sheets".
        #expect(note.message.contains("“Redact B”: 1 area removed on 1 sheet"), "\(note.message)")
        // Neither drawing is touched, and the folder holds the two copies and nothing else.
        #expect(try Data(contentsOf: primaryFile) == originals.0)
        #expect(try Data(contentsOf: added.drawing.url) == originals.1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Redact A — Redacted.pdf", "Redact B — Redacted.pdf"])
    }

    @Test("C-09: marks on two drawings with one file named are refused before anything is written")
    func severalDrawingsNeedAFolder() async throws {
        let (harness, _, primarySheet, addedSheet, b) = try await Self.twoDrawings()
        defer {
            RedactionWorkflow.clear(harness.document, canvas: harness.canvas)
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        RedactionWorkflow.add(Self.secretBox, onPage: primarySheet.id.rawValue, to: harness.document, canvas: harness.canvas)
        RedactionWorkflow.add(Self.secretBox, onPage: addedSheet.id.rawValue, to: harness.document, canvas: harness.canvas)
        let output = harness.directory.appendingPathComponent("One.pdf")
        // Old: A's copy at the file, B's beside it, which the sandbox refused after A was written.
        await #expect(throws: RedactionWorkflow.Refusal.severalDrawingsNeedAFolder(count: 2)) {
            _ = try await RedactionWorkflow.apply(document: harness.document, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!harness.core.document.warnings.contains { $0.id == RedactionWorkflow.resultNoteID })
    }

    @Test("C-09: a drawing that cannot be redacted leaves no copy of any drawing in the folder, and no result note")
    func failedDrawingLeavesTheFolderEmpty() async throws {
        let (harness, _, primarySheet, addedSheet, b) = try await Self.twoDrawings()
        defer {
            RedactionWorkflow.clear(harness.document, canvas: harness.canvas)
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        RedactionWorkflow.add(Self.secretBox, onPage: primarySheet.id.rawValue, to: harness.document, canvas: harness.canvas)
        // A box off B's sheet: B's copy cannot be made, after A's already was.
        RedactionWorkflow.add(CGRect(x: 5000, y: 5000, width: 10, height: 10), onPage: addedSheet.id.rawValue, to: harness.document, canvas: harness.canvas)
        let folder = harness.directory.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try await RedactionWorkflow.applyAll(document: harness.document, to: .folder(folder), keepSharp: false)
            Issue.record("a set with an unredactable drawing was written")
        } catch let refusal as RedactionRefusal {
            // Old: A's copy stayed on disk, silently, and the error spoke only of B's box.
            #expect(refusal == .copyFailed(drawing: "Redact B", reason: RedactionRefusal.markOutsidePage(addedSheet.index).description))
            #expect(refusal.localizedDescription.contains("“Redact B”") && refusal.localizedDescription.contains("no redacted copy of any marked drawing was kept"),
                    "\(refusal.localizedDescription)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!harness.core.document.warnings.contains { $0.id == RedactionWorkflow.resultNoteID })
    }

    @Test("C-09: a mark on the added drawing alone redacts a copy of that drawing, named after it, and never the primary")
    func redactionOfTheAddedDrawingOnly() async throws {
        let (harness, added, _, addedSheet, b) = try await Self.twoDrawings()
        defer {
            RedactionWorkflow.clear(harness.document, canvas: harness.canvas)
            harness.tearDown()
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        RedactionWorkflow.add(Self.secretBox, onPage: addedSheet.id.rawValue, to: harness.document, canvas: harness.canvas)
        let jobs = RedactionWorkflow.drawingMarks(for: harness.document)
        #expect(jobs.map(\.displayName) == ["Redact B"])
        #expect(jobs.first?.marks == [RedactionMark(pageIndex: addedSheet.index, rect: Self.secretBox)])

        let output = harness.directory.appendingPathComponent("Chosen.pdf")
        let copies = try await RedactionWorkflow.applyAll(document: harness.document, to: .file(output), keepSharp: false)
        #expect(copies.map(\.output) == [output])
        let text = Self.text(of: output)
        // Old (before T-007): the box was kept as page 0 of the primary and "PRIMARYSECRET" was
        // painted over in a copy of A. Now the copy is B's, as a picture (Keep Sharp off).
        #expect(!text.contains("ANNEXSECRET") && !text.contains("PRIMARYSECRET"))
        #expect(copies.first?.outcome.redactedPages == [addedSheet.index])
        // The added drawing's own file is protected like the primary's.
        await #expect(throws: DerivedCopyGuard.Refusal.self) {
            _ = try await RedactionWorkflow.applyAll(document: harness.document, to: .file(added.drawing.url))
        }
    }

    @Test("C-09: a copy in the chosen folder never takes a name already there")
    func folderNamesAreUnique() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-it4-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("Annex — Redacted.pdf"))
        func job(_ name: String) -> RedactionWorkflow.DrawingMarks {
            RedactionWorkflow.DrawingMarks(documentID: DocumentID(UUID()), source: folder.appendingPathComponent("\(name).pdf"),
                                           password: nil, displayName: name, marks: [RedactionMark(pageIndex: 0, rect: Self.secretBox)])
        }
        let outputs = RedactionWorkflow.outputs(for: [job("Plan"), job("Annex"), job("Annex")], in: folder)
        #expect(outputs.map(\.lastPathComponent) == ["Plan — Redacted.pdf", "Annex — Redacted 2.pdf", "Annex — Redacted 3.pdf"])
        #expect(outputs.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL })
    }

    // MARK: - U-053: the clean-up note names what it could not do as asked

    @Test("U-053: the clean-up note names a sheet cleaned below the resolution asked for and one copied uncleaned")
    func scanCleanupNoteNamesReducedAndUncleanedSheets() {
        let reports = [
            ScanCleanup.PageReport(pageIndex: 0, renderedDPI: 186),
            ScanCleanup.PageReport(pageIndex: 1, renderedDPI: nil),
            ScanCleanup.PageReport(pageIndex: 2, renderedDPI: 200),
        ]
        let note = ScanCleanupCommand.resultNote(
            reports: reports, output: URL(fileURLWithPath: "/tmp/Scan — Cleaned.pdf"),
            labels: [0: "A1", 1: "A2", 2: "A3"], requestedDPI: 200
        )
        // Old: the oversized sheet was dropped from the file and the note said only "The cleaned
        // sheets are a new PDF at the same paper size."
        #expect(note.message.contains("Too large for 200 dpi, cleaned at a lower resolution: A1 at 186 dpi."), "\(note.message)")
        #expect(note.message.contains("Not cleaned, copied as they were: A2."), "\(note.message)")
        #expect(!note.message.contains("A3 at"))
        #expect(note.severity == .warning)
        // Every sheet cleaned as asked: the note is as it was.
        let clean = ScanCleanupCommand.resultNote(reports: [ScanCleanup.PageReport(pageIndex: 0, renderedDPI: 200)],
                                                  output: URL(fileURLWithPath: "/tmp/Scan — Cleaned.pdf"), labels: [:])
        #expect(!clean.message.contains("Too large") && !clean.message.contains("Not cleaned"))
        #expect(clean.severity == .info)
    }
}
