import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Iteration 1, in the PDFKit bridge: R-100 and R-110 (the signature
/// inspector), R-103 and R-114 (form fill's write path). Each test says what the old code did.
@Suite("Iteration 1 — PDF export fixes in the bridge", .serialized)
struct Iter1ExportPDFBridgeTests {

    /// A one-page PDF whose only field is a signature with the given dictionary body.
    static func signatureFieldPDF(signature: String) -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [0 0 0 0] /P 3 0 R /V 5 0 R >>",
            signature
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    // MARK: - R-100

    @Test("R-100: a /ByteRange whose start plus length overflows is unverifiable, not a crash")
    func hostileByteRangeDoesNotTrap() {
        // Old: `start + length <= data.count` overflowed and trapped — on every open of the file,
        // since the inspector runs when a drawing is opened.
        for range in ["[4611686018427387904 4611686018427387904 0 0]", "[0 9223372036854775807 9223372036854775807 1]",
                      "[9223372036854775807 1 0 0]"] {
            let pdf = Self.signatureFieldPDF(signature: "<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange \(range) /Contents <00> >>")
            let signatures = SignatureInspector.signatures(in: pdf)
            #expect(signatures.count == 1)
            #expect(signatures.first?.integrity == .unverifiable)
        }
    }

    // MARK: - R-110

    /// A signed PDF whose byte ranges leave, besides the `<hex>` /Contents, a `/Hidden (…)` entry
    /// unsigned in the gap; the signature over the covered bytes is genuine.
    static func signedWithWideGap(in directory: URL) throws -> Data {
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        try NLPDFSignatureTests.run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                                     "-days", "30", "-subj", "/CN=Zenit Gap Signer"])
        let placeholder = String(repeating: "0", count: 8192)
        let tail = " /Hidden (UNSIGNED CONTENT)"
        var bytes = [UInt8](Self.signatureFieldPDF(signature: "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached"
            + " /ByteRange [0000000000 0000000000 0000000000 0000000000] /Contents <\(placeholder)>\(tail) /M (D:20260923120000Z) >>"))
        func find(_ text: String) throws -> Int {
            let needle = Array(text.utf8)
            return try #require((0...(bytes.count - needle.count)).first { Array(bytes[$0..<$0 + needle.count]) == needle })
        }
        let contentsStart = try find("/Contents <") + "/Contents ".utf8.count
        let gapEnd = contentsStart + placeholder.count + 2 + tail.utf8.count
        let range = String(format: "%010d %010d %010d %010d", 0, contentsStart, gapEnd, bytes.count - gapEnd)
        let rangeAt = try find("0000000000 0000000000 0000000000 0000000000")
        bytes.replaceSubrange(rangeAt..<rangeAt + range.utf8.count, with: Array(range.utf8))
        let covered = Data(bytes[0..<contentsStart] + bytes[gapEnd..<bytes.count])
        let input = directory.appendingPathComponent("covered.bin"), output = directory.appendingPathComponent("sig.der")
        try covered.write(to: input)
        try NLPDFSignatureTests.run(["smime", "-sign", "-binary", "-noattr", "-in", input.path, "-signer", cert, "-inkey", key,
                                     "-outform", "DER", "-out", output.path])
        let hex = try Data(contentsOf: output).map { String(format: "%02X", $0) }.joined()
        #expect(hex.count <= placeholder.count)
        bytes.replaceSubrange(contentsStart + 1..<contentsStart + 1 + hex.count, with: Array(hex.utf8))
        return Data(bytes)
    }

    @Test("R-110: bytes other than this signature's <hex> in the unsigned gap make it unverifiable; a proper one stays intact")
    func gapMustHoldOnlyContents() throws {
        let directory = try Corpus.scratchDirectory("iter1-signature-gap")
        let wide = try Self.signedWithWideGap(in: directory)
        // Old: .intact — the digest matched, and nothing looked at what the gap held.
        #expect(SignatureInspector.signatures(in: wide).first?.integrity == .unverifiable)
        let proper = try NLPDFSignatureTests.signedPDF(in: directory)
        #expect(SignatureInspector.signatures(in: proper).first?.integrity == .intact)

        let data = Data("<0A1b>xyz".utf8)
        #expect(SignatureInspector.gapIsOnlyContents([(0, 0), (6, 3)], in: data))
        #expect(!SignatureInspector.gapIsOnlyContents([(0, 0), (7, 2)], in: data), "the gap must end at the '>'")
        #expect(!SignatureInspector.gapIsOnlyContents([(1, 0), (6, 3)], in: data), "the first range starts at byte 0")
        #expect(!SignatureInspector.gapIsOnlyContents([(0, 0), (6, 3), (9, 0)], in: data), "exactly two ranges")
        #expect(!SignatureInspector.gapIsOnlyContents([(0, 0), (6, 3)], in: Data("<0Z1b>xyz".utf8)), "hex digits only")
        #expect(!SignatureInspector.gapIsOnlyContents([(0, 7), (6, 3)], in: data), "the second range starts after the first")
    }

    // MARK: - R-103 / R-114: form fill's write path

    static func formPDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let field = PDFAnnotation(bounds: CGRect(x: 20, y: 150, width: 200, height: 22), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "Project"
        document.page(at: 0)?.addAnnotation(field)
        #expect(document.write(to: url))
    }

    @Test("R-103: filling into the drawing itself — by path or through a symlink — is refused; the drawing is untouched")
    func fillRefusesItsSource() throws {
        let directory = try Corpus.scratchDirectory("iter1-form-source")
        let source = directory.appendingPathComponent("RFI.pdf")
        try Self.formPDF(at: source)
        let before = try Data(contentsOf: source)
        let link = directory.appendingPathComponent("link.pdf")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for destination in [source, link] {
            // Old: the drawing was replaced by PDFKit's rewrite of it.
            #expect(throws: PDFFormFields.Refusal.destinationIsSource) {
                try PDFFormFields.fill(source: source, values: ["Project": .text("X")], to: destination)
            }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(StagedFileReplacement.sameItem(link, source))
        #expect(!StagedFileReplacement.sameItem(directory.appendingPathComponent("other.pdf"), source))
    }

    @Test("R-114: when the final move fails, form fill leaves no hidden staging file behind")
    func fillCleansUpStaging() throws {
        let directory = try Corpus.scratchDirectory("iter1-form-staging")
        let source = directory.appendingPathComponent("RFI.pdf")
        try Self.formPDF(at: source)
        let locked = directory.appendingPathComponent("locked.pdf")
        try Data("previous".utf8).write(to: locked)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) {
            try PDFFormFields.fill(source: source, values: ["Project": .text("X")], to: locked)
        }
        // Old: ".zpdf-form-<UUID>.pdf" stayed in the folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".zpdf-") }
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }
}

// MARK: - R-117: the pending thumbnail-write list

/// Holds the first `held` disk writes until released; lets every later one through.
actor DiskWriteGate {
    private var calls = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let held: Int

    init(held: Int) { self.held = held }

    func pass() async {
        calls += 1
        guard calls <= held, !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

extension Iter1ExportPDFBridgeTests {

    @Test("R-117: waiting for thumbnail disk writes waits for all of them — past 256 in flight too")
    func thumbnailWaitSeesEveryWrite() async throws {
        let url = try HandBuiltPDF.pages(260, mediaBox: "[0 0 100 100]", label: "iter1-thumbnail-wait")
        let root = url.deletingLastPathComponent().appendingPathComponent("Thumbnails-iter1", isDirectory: true)
        let provider = PDFKitDocumentProvider(thumbnailDiskCache: ThumbnailDiskCache(directory: root))
        let gate = DiskWriteGate(held: 128)
        await provider.setThumbnailDiskWriteGate { await gate.pass() }
        let opened = try await provider.open(fileAt: url)
        var keys: [ThumbnailCache.Key] = []
        for page in 0..<260 {
            keys.append(try await provider.thumbnail(ThumbnailRequest(document: opened.handle, pageIndex: page, maximumPixelSize: 16)).key)
        }
        let waiter = Task { await provider.waitForThumbnailDiskWrites() }
        try await Task.sleep(for: .seconds(2))
        // Old: the 256th write dropped the oldest 128 handles, running or not, so the wait
        // returned while those writes — held here — had not stored anything.
        let pendingWhileHeld = await provider.pendingThumbnailDiskWrites.count
        #expect(pendingWhileHeld == 128, "the held writes are still listed")
        await gate.release()
        await waiter.value
        #expect(await provider.pendingThumbnailDiskWrites.isEmpty, "each write removed itself")
        let disk = ThumbnailDiskCache(directory: root)
        let stored = keys.filter { key in disk.fileURL(for: key).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        #expect(stored.count == 260, "every thumbnail is on disk once the wait returns")
        await provider.close(opened.handle)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - R-112: one page-to-sheet mapping

extension Iter1ExportPDFBridgeTests {

    @Test("R-112: pageToRect is the four hand-derived quarter-turn maps, stretched onto the rectangle")
    func pageToRectMatchesTheQuarterTurns() throws {
        // A crop box off the origin, 200 × 100 at (10, 20), onto a rectangle at (5, 7).
        let box = CGRect(x: 10, y: 20, width: 200, height: 100)
        func mapped(_ rotation: Int, _ point: CGPoint, rect: CGRect) throws -> CGPoint {
            point.applying(try #require(PageDisplayGeometry.pageToRect(box: box, rotation: rotation, rect: rect)))
        }
        // 0°: the sheet is 200 × 100; rect 400 × 50 scales x by 2 and y by 0.5.
        let flat = CGRect(x: 5, y: 7, width: 400, height: 50)
        #expect(try mapped(0, CGPoint(x: 10, y: 20), rect: flat) == CGPoint(x: 5, y: 7))
        #expect(try mapped(0, CGPoint(x: 210, y: 120), rect: flat) == CGPoint(x: 405, y: 57))
        // 90°: the displayed sheet is 100 × 200; the box's top-left (10, 120) is the sheet's
        // bottom-left, its bottom-left (10, 20) the sheet's bottom-right... by (u, v) → (v, w − u).
        let tall = CGRect(x: 5, y: 7, width: 100, height: 200)
        #expect(try mapped(90, CGPoint(x: 210, y: 20), rect: tall) == CGPoint(x: 5, y: 7))
        #expect(try mapped(90, CGPoint(x: 10, y: 120), rect: tall) == CGPoint(x: 105, y: 207))
        // 180°: (u, v) → (w − u, h − v).
        #expect(try mapped(180, CGPoint(x: 210, y: 120), rect: CGRect(x: 5, y: 7, width: 200, height: 100)) == CGPoint(x: 5, y: 7))
        // 270°: (u, v) → (h − v, u).
        #expect(try mapped(270, CGPoint(x: 10, y: 120), rect: tall) == CGPoint(x: 5, y: 7))
        #expect(try mapped(270, CGPoint(x: 210, y: 20), rect: tall) == CGPoint(x: 105, y: 207))
        #expect(PageDisplayGeometry.pageToRect(box: .zero, rotation: 0, rect: tall) == nil)
        #expect(PageDisplayGeometry.pageToRect(box: box, rotation: 0, rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)) == nil)
    }
}
