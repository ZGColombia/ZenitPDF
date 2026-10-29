import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFSearch
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 5, render-extract-search (V-078): Process PDF Files ▸ Make searchable no
/// longer reports a file done in full when some of its pages could not be read for text.
@MainActor
@Suite("Process PDF Files: pages Make Searchable could not read (V-078)", .appTierSerialised)
struct Iter5BatchUnreadablePageTests {

    /// A two-page PDF; what is on the pages does not matter, the recogniser is injected.
    private static func twoPagePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 396)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(gray: 0.5, alpha: 1))
            pdf.fill(CGRect(x: 100, y: 100, width: 200, height: 40))
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    /// Page 1 read, page 2 failed: what `OCRService.recogniseFile` returns when page 2 cannot
    /// be rendered (asserted against the real recogniser in ZPDFSearch's R-150/V-078 test).
    private static let recogniser: BatchFileProcessor.FileRecogniser = { _ in
        OCRFileRecognition(
            tokens: [0: [OCRRecognisedToken(text: "FOUNDATION", confidence: 0.9, bounds: CGRect(x: 100, y: 100, width: 200, height: 40))], 1: []],
            unreadablePages: [1]
        )
    }

    /// Old output: `status == .done` with no reason, the CSV row `Plan.pdf,done,,…`, a result
    /// note of severity `.info`, and a rerun that skipped the file as "already processed".
    @Test("V-078: a file with an unreadable page is done with a reason naming the page, in the item, the CSV and the note")
    func unreadablePageIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-batch-v078-\(UUID().uuidString)", isDirectory: true)
        let inputs = root.appendingPathComponent("in", isDirectory: true), outputs = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.twoPagePDF(at: inputs.appendingPathComponent("Plan.pdf"))
        var steps = BatchFileProcessor.Steps()
        steps.makeSearchable = true
        steps.reduceSize = false
        steps.pictureDPI = nil

        let report = try await BatchFileProcessor.run(
            inputs: [inputs], steps: steps, outputFolder: outputs,
            transform: { _, _, _ in Issue.record("no qpdf step was chosen") },
            recognise: Self.recogniser
        )

        let item = try #require(report.items.first)
        #expect(item.status == .done, "the searchable copy of the readable page is still written")
        let note = try #require(item.note)
        #expect(note.hasPrefix("page 2 could not be read for text"), "\(note)")
        #expect(report.done == 1 && report.incomplete == 1)
        let csv = try String(contentsOf: outputs.appendingPathComponent(BatchFileProcessor.reportFileName), encoding: .utf8)
        // The one file's row, under the header; quoted as the app's CSV field rule decides.
        let row = try #require(csv.split(separator: "\n").dropFirst().first)
        #expect(row.hasPrefix("Plan.pdf,") || row.hasPrefix("\"Plan.pdf\","))
        #expect(row.contains(",done,") && row.contains("page 2 could not be read for text"), "\(csv)")
        let warning = BatchFileCommand.resultNote(report, folder: outputs)
        #expect(warning.severity == .warning)
        #expect(warning.message.contains("Some pages of these files could not be read for text: Plan.pdf."), "\(warning.message)")

        // Page 1 did get its text layer.
        let output = try #require(item.output)
        let document = try #require(PDFDocument(url: output))
        let found = document.findString("FOUNDATION", withOptions: .caseInsensitive)
        #expect(found.first?.pages.first.map { document.index(for: $0) } == 0)

        // A rerun retries the file instead of skipping it as already processed.
        let rerun = try await BatchFileProcessor.run(
            inputs: [inputs], steps: steps, outputFolder: outputs,
            transform: { _, _, _ in Issue.record("no qpdf step was chosen") },
            recognise: Self.recogniser
        )
        #expect(rerun.items.first?.status == .done)
        #expect(rerun.items.first?.note?.hasPrefix("page 2 could not be read") == true)
    }

    @Test("V-078: the page list counts from one and names every unreadable page")
    func noteWording() {
        #expect(BatchFileProcessor.unreadablePagesNote([]) == nil)
        #expect(BatchFileProcessor.unreadablePagesNote([6, 2])
            == "pages 3, 7 could not be read for text, so they have no text layer; run again to retry them")
        #expect(BatchFileProcessor.unreadablePagesNote([0])
            == "page 1 could not be read for text, so it has no text layer; run again to retry it")
    }
}
