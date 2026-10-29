import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFServiceClient
import ZPDFServiceWire
@testable import ZenitPDFAppKit

/// NL-PDF-19: a folder through "Make searchable → Reduce size → Protect" into another folder,
/// with a per-file report, originals hashed unchanged, a stopped run resumed. qpdf runs in the
/// repair worker as a child process.
@MainActor
@Suite("Process PDF Files (NL-PDF-19)", .appTierSerialised)
struct NLPDFR2BatchTests {

    static func productsDirectory() throws -> URL {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else { throw CocoaError(.fileNoSuchFile) }
        var url = URL(fileURLWithPath: String(cString: path))
        while url.pathComponents.count > 1, url.pathExtension != "xctest" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
    }

    /// A "scan": text drawn as a picture, so only OCR can find it.
    static func scannedPDF(at url: URL, word: String) throws {
        let width = 1275, height = 825  // 8.5 × 5.5 in at 150 dpi
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        bitmap.textPosition = CGPoint(x: 120, y: 400)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.init(kCTFontAttributeName as String): font])), bitmap)
        var box = CGRect(x: 0, y: 0, width: 612, height: 396)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.draw(try #require(bitmap.makeImage()), in: box); pdf.endPDFPage(); pdf.closePDF()
    }

    static func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    @Test("Three scans, a text file and a locked PDF: 3 done (searchable, protected), 2 skipped with reasons; originals unchanged; a rerun resumes")
    func folderRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-batch-\(UUID().uuidString)", isDirectory: true)
        let inputs = root.appendingPathComponent("in", isDirectory: true), outputs = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, word) in [("A.pdf", "FOUNDATION"), ("B.pdf", "ELEVATION"), ("C.pdf", "SECTION")] {
            try Self.scannedPDF(at: inputs.appendingPathComponent(name), word: word)
        }
        try Data("notes".utf8).write(to: inputs.appendingPathComponent("notes.txt"))
        // A locked PDF.
        let open = try #require(PDFDocument(url: inputs.appendingPathComponent("A.pdf")))
        #expect(open.write(to: inputs.appendingPathComponent("D locked.pdf"), withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "y"]))
        let hashes = try FileManager.default.contentsOfDirectory(at: inputs, includingPropertiesForKeys: nil).reduce(into: [String: String]()) { $0[$1.lastPathComponent] = try Self.sha($1) }

        let worker = try Self.productsDirectory().appendingPathComponent("zpdf-repair-worker")
        try #require(FileManager.default.fileExists(atPath: worker.path))
        let client = ZPDFRepairServiceClient(backend: .subprocess(executableURL: worker), maximumRestarts: 0)
        let transform: @Sendable (URL, URL, RepairWireTransform) async throws -> Void = { input, output, request in
            _ = try await client.transform(input: input, output: output, password: nil, transform: request)
        }
        var steps = BatchFileProcessor.Steps()
        steps.makeSearchable = true
        steps.protection = .init(openPassword: "", permissionsPassword: "owner", printing: 2, allowsChanges: false, allowsCopying: true, allowsAnnotating: true)

        // Old behaviour: nothing processed more than one open drawing.
        await #expect(throws: BatchFileProcessor.Refusal.outputBesideInputs) {
            _ = try await BatchFileProcessor.run(inputs: [inputs], steps: steps, outputFolder: inputs, transform: transform)
        }
        let report = try await BatchFileProcessor.run(inputs: [inputs], steps: steps, outputFolder: outputs, transform: transform)
        #expect(report.done == 3, "\(report.items.map { ($0.input.lastPathComponent, $0.status) })")
        #expect(report.skipped == 2)
        #expect(report.items.first { $0.input.lastPathComponent == "notes.txt" }?.status == .skipped("not a PDF"))
        if case let .skipped(reason)? = report.items.first(where: { $0.input.lastPathComponent == "D locked.pdf" })?.status {
            #expect(reason.contains("password"))
        } else { Issue.record("the locked file was not skipped") }
        for name in ["A", "B", "C"] {
            let output = outputs.appendingPathComponent("\(name) — Processed.pdf")
            let document = try #require(PDFDocument(url: output))
            #expect(!document.findString(["A": "FOUNDATION", "B": "ELEVATION", "C": "SECTION"][name]!, withOptions: .caseInsensitive).isEmpty, "\(name) is searchable")
            #expect(CGPDFDocument(output as CFURL)?.isEncrypted == true, "\(name) is protected (AES-256, permissions password)")
        }
        let after = try FileManager.default.contentsOfDirectory(at: inputs, includingPropertiesForKeys: nil).reduce(into: [String: String]()) { $0[$1.lastPathComponent] = try Self.sha($1) }
        #expect(after == hashes, "every original is byte for byte what it was")
        let csv = try String(contentsOf: outputs.appendingPathComponent(BatchFileProcessor.reportFileName), encoding: .utf8)
        // Fields are quoted only when they must be, through the one CSV rule (V-022, sweep 11 I-27).
        let rows = csv.split(whereSeparator: \.isNewline).map(String.init)
        #expect(rows.contains { $0.hasPrefix("A.pdf,done") } && rows.contains { $0.hasPrefix("notes.txt,skipped") }, "\(rows)")

        // A second run with the same files and folder resumes: nothing is done twice.
        let resumed = try await BatchFileProcessor.run(inputs: [inputs], steps: steps, outputFolder: outputs, transform: transform)
        #expect(resumed.done == 0)
        #expect(resumed.items.filter { $0.status == .skipped("already processed in an earlier run") }.count == 3)
    }
}
