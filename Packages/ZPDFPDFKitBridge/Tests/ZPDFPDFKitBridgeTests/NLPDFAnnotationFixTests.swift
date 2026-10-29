import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Bridge-side PDF annotation bug fixes: opacity, ink, names that survive PDFKit, re-export
/// supersession, and signature detection. Each test states what the old code produced.
@Suite("PDF annotation fixes")
struct NLPDFAnnotationFixTests {

    struct Fixture {
        let provider: PDFKitDocumentProvider
        let handle: DocumentHandle
        let scratch: URL
    }

    func open(_ label: String) async throws -> Fixture {
        let scratch = try Corpus.scratchDirectory(label)
        let source = scratch.appendingPathComponent(FixtureKind.titleBlockSheet.fileName)
        try FileManager.default.copyItem(at: Corpus.url(.titleBlockSheet), to: source)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: source)
        return Fixture(provider: provider, handle: opened.handle, scratch: scratch)
    }

    func write(_ annotations: [NeutralAnnotation], mode: AnnotationWriteMode = .append,
               fixture: Fixture, named name: String) async throws -> URL {
        let url = fixture.scratch.appendingPathComponent(name)
        _ = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: annotations, mode: mode),
            of: fixture.handle,
            to: DocumentDestination(url: url, overwritePolicy: .replace)
        )
        return url
    }

    @Test("A 20 % interior colour keeps its alpha in the written appearance")
    func interiorAlphaSurvives() async throws {
        let fixture = try await open("nlpdf-alpha")
        let url = try await write([
            NeutralAnnotation(
                pageIndex: 0, kind: .square,
                bounds: CGRect(x: 100, y: 100, width: 200, height: 100),
                color: AnnotationColor(red: 0.1, green: 0.33, blue: 0.81, alpha: 1),
                interiorColor: AnnotationColor(red: 0.1, green: 0.33, blue: 0.81, alpha: 0.2),
                borderWidth: 1
            )
        ], fixture: fixture, named: "alpha.pdf")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        // Old output: `/IC [0.1 0.33 0.81]` and an appearance painted opaque — no `/ca` anywhere.
        #expect(text.contains("/ca 0.2"), "the fill's 20 % alpha must reach the appearance stream")
    }

    @Test("Ink strokes are written, and read back where they were drawn")
    func inkIsWritten() async throws {
        let fixture = try await open("nlpdf-ink")
        let strokes: [[CGPoint]] = [
            [CGPoint(x: 110, y: 120), CGPoint(x: 150, y: 180), CGPoint(x: 190, y: 130)],
            [CGPoint(x: 210, y: 140), CGPoint(x: 260, y: 150)]
        ]
        // Old behaviour: `PDFBridgeError.unsupported("writing ink annotation strokes")`.
        let url = try await write([
            NeutralAnnotation(
                pageIndex: 0, kind: .ink,
                bounds: CGRect(x: 100, y: 100, width: 180, height: 100),
                color: AnnotationColor(red: 0, green: 0, blue: 1, alpha: 1),
                borderWidth: 2,
                inkPaths: strokes
            )
        ], fixture: fixture, named: "ink.pdf")
        let reopened = try await fixture.provider.open(fileAt: url)
        let read = try await fixture.provider.annotations(of: reopened.handle, pageIndex: 0)
        let ink = try #require(read.first { $0.kind == .ink })
        #expect(ink.inkPaths.count == 2)
        for (written, back) in zip(strokes, ink.inkPaths) {
            #expect(written.count == back.count)
            for (a, b) in zip(written, back) {
                #expect(abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01, "\(a) read back as \(b)")
            }
        }
    }

    @Test("An annotation's name and Zenit ownership survive PDFKit's write")
    func nameAndOwnershipSurvive() async throws {
        let fixture = try await open("nlpdf-name")
        let url = try await write([
            NeutralAnnotation(
                pageIndex: 0, kind: .square, bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                name: "8C1F1C10-0000-4000-8000-000000000001", isZenitOwned: true
            )
        ], fixture: fixture, named: "named.pdf")
        let reopened = try await fixture.provider.open(fileAt: url)
        let read = try await fixture.provider.annotations(of: reopened.handle, pageIndex: 0)
        // Old output: `name == nil` — PDFKit strips `/NM` on write.
        #expect(read.first?.name == "8C1F1C10-0000-4000-8000-000000000001")
        #expect(read.first?.isZenitOwned == true)
    }

    @Test("A re-export supersedes Zenit's own annotations and keeps a reviewer's")
    func reExportSupersedes() async throws {
        let fixture = try await open("nlpdf-supersede")
        let reviewer = NeutralAnnotation(
            pageIndex: 0, kind: .text, bounds: CGRect(x: 400, y: 400, width: 20, height: 20),
            contents: "Reviewer's note", author: "Reviewer"
        )
        let legacy = NeutralAnnotation(
            pageIndex: 0, kind: .square, bounds: CGRect(x: 5, y: 5, width: 5, height: 5),
            subject: ZenitAnnotationOwnership.legacySubject
        )
        let ours = (0..<3).map { index in
            NeutralAnnotation(
                pageIndex: 0, kind: .square,
                bounds: CGRect(x: 50 + CGFloat(index) * 30, y: 50, width: 20, height: 20),
                name: "mark-\(index)", isZenitOwned: true
            )
        }
        let first = try await write([reviewer, legacy] + ours, fixture: fixture, named: "first.pdf")
        let firstOpened = try await fixture.provider.open(fileAt: first)
        let second = fixture.scratch.appendingPathComponent("second.pdf")
        _ = try await fixture.provider.writeAnnotations(
            AnnotationWriteRequest(annotations: ours, mode: .supersedeZenitOwned),
            of: firstOpened.handle,
            to: DocumentDestination(url: second, overwritePolicy: .replace)
        )
        let reopened = try await fixture.provider.open(fileAt: second)
        // PDFKit gives a note its own pop-up; that is the reviewer's too.
        let read = try await fixture.provider.annotations(of: reopened.handle, pageIndex: 0)
            .filter { $0.kind != .popup }
        // Old behaviour (`.append`): 5 + 3 = 8, two sets of Zenit marks stacked plus the legacy one.
        #expect(read.count == 4)
        #expect(read.contains { $0.author == "Reviewer" })
        #expect(read.filter(\.isZenitOwned).count == 3)
        #expect(!read.contains { $0.subject == ZenitAnnotationOwnership.legacySubject && $0.name == nil })
    }

    @Test("A signed drawing is reported as signed; an empty signature field is not")
    func signatureIsDetected() throws {
        let directory = try Corpus.scratchDirectory("nlpdf-signed")
        let signed = directory.appendingPathComponent("signed.pdf")
        let unsigned = directory.appendingPathComponent("unsigned.pdf")
        try Self.formDocument(signatureValue: true).write(to: signed)
        try Self.formDocument(signatureValue: false).write(to: unsigned)
        // Old code: `DocumentHazards` had no member for a signature, so neither was flagged.
        #expect(DocumentHazardProbe.hazards(ofFileAt: signed).contains(.signedDocument))
        #expect(DocumentHazardProbe.hazards(ofFileAt: signed).contains(.acroForm))
        #expect(!DocumentHazardProbe.hazards(ofFileAt: unsigned).contains(.signedDocument))
    }

    /// A one-page document with a signature field whose value is present or absent. The value is
    /// a dictionary with a placeholder `/Contents`; detection is structural and never verifies.
    static func formDocument(signatureValue: Bool) -> Data {
        let value = signatureValue
            ? " /V << /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached"
                + " /ByteRange [0 10 20 10] /Contents <00> >>"
            : ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [0 0 0 0] /P 3 0 R\(value) >>"
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
}

