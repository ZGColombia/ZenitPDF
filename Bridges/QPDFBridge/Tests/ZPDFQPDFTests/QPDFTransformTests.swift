import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// NL-PDF-08 / NL-PDF-09 through the C wrapper: flatten the drawing's own annotations, compress,
/// sanitise and encrypt a copy — the input untouched every time.
@Suite("Transform (flatten, compress, sanitise, encrypt)")
struct QPDFTransformTests {

    // MARK: - Fixtures

    /// A one-page drawing with an uncompressed, repetitive content stream (so compression has
    /// something to do), a square annotation carrying its own appearance, a document-level
    /// JavaScript tree, an embedded file, an open action, XMP metadata, an /Info dictionary
    /// and a page additional-action.
    static func hazardousDrawing() -> Data {
        var content = "0 0 0 RG 1 w\n"
        for index in 0..<400 {
            let y = 40 + index % 300
            content += "40 \(y) m 360 \(y) l S\n"
        }
        let appearance = "1 0 0 RG 4 w 2 2 96 46 re S"
        let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF/></x:xmpmeta>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /JavaScript /JS (app.alert\\(1\\)) >>"
                + " /Names << /JavaScript << /Names [(a) 8 0 R] >> /EmbeddedFiles << /Names [(f.txt) 9 0 R] >> >>"
                + " /Metadata 7 0 R /AA << /WC << /S /JavaScript /JS (1) >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Contents 4 0 R /Annots [5 0 R]"
                + " /AA << /O << /S /JavaScript /JS (2) >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /F 4 /C [1 0 0] /AP << /N 6 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 50] /Length \(appearance.utf8.count) >>\nstream\n\(appearance)\nendstream",
            "<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream",
            "<< /S /JavaScript /JS (3) >>",
            "<< /Type /Filespec /F (f.txt) /EF << /F 10 0 R >> >>",
            "<< /Type /EmbeddedFile /Length 5 >>\nstream\nhello\nendstream"
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
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info << /Author (Somebody) /Title (Plan) >> >>\n"
            + "startxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    static func write(_ data: Data, in box: Sandbox, named name: String = "input.pdf") throws -> URL {
        let url = box.file(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Encrypt

    @Test("An encrypted copy opens only with its password, as AES-256 revision 6, with the permissions asked for")
    func encrypts() throws {
        let box = try Sandbox("encrypts")
        let input = try Self.write(Self.hazardousDrawing(), in: box)
        let before = try Hashing.sha256(of: input)
        let output = box.file("protected.pdf")
        try QPDF.transform(
            input: input,
            output: output,
            transform: QPDFTransform(protection: .init(
                openPassword: "open-sesame",
                permissionsPassword: "owner-only",
                printing: .none,
                allowsChanges: false,
                allowsCopying: false,
                allowsAnnotating: false
            ))
        )
        #expect(try Hashing.sha256(of: input) == before, "the input must not change")
        expectQPDFError("passwordRequired") { _ = try QPDF.inspect(output) }
        let inventory = try QPDF.inspect(output, password: "open-sesame")
        let encryption = try #require(inventory.encryption)
        #expect(encryption.revision == 6)
        #expect(encryption.keyBits == 256)
        #expect(!encryption.allowsPrintHighResolution)
        #expect(!encryption.allowsPrintLowResolution)
        #expect(!encryption.allowsExtractAll)
        #expect(encryption.allowsAccessibility, "screen readers are never locked out")
        // An independent reader agrees: PDFKit sees a locked document that the password opens.
        let document = try #require(PDFDocument(url: output))
        #expect(document.isLocked)
        #expect(document.unlock(withPassword: "open-sesame"))
        #expect(document.pageCount == 1)
    }

    @Test("A permissions password equal to the open password is refused before anything is written")
    func refusesEqualPasswords() throws {
        let box = try Sandbox("equalPasswords")
        let input = try Self.write(Self.hazardousDrawing(), in: box)
        let output = box.file("never.pdf")
        expectQPDFError("invalidArgument") {
            try QPDF.transform(
                input: input, output: output,
                transform: QPDFTransform(protection: .init(openPassword: "same", permissionsPassword: "same"))
            )
        }
        expectQPDFError("invalidArgument") {
            try QPDF.transform(input: input, output: output, transform: QPDFTransform())
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Sanitise

    @Test("A sanitised copy carries no JavaScript, embedded files, open action, actions or metadata")
    func sanitizes() throws {
        let box = try Sandbox("sanitizes")
        let input = try Self.write(Self.hazardousDrawing(), in: box)
        let output = box.file("clean.pdf")
        // The fixture really carries every one of them. Read as bytes: Core Graphics does not
        // hand back a catalog's /OpenAction, so it cannot be the witness here.
        let keys = ["/OpenAction", "/JavaScript", "/EmbeddedFiles", "/Metadata", "/Author", "/AA"]
        let originalText = String(decoding: try Data(contentsOf: input), as: UTF8.self)
        for key in keys { #expect(originalText.contains(key), "the fixture lacks \(key)") }

        let report = try QPDF.transform(input: input, output: output, transform: QPDFTransform(sanitizes: true))
        #expect(report.removedJavaScript)
        #expect(report.removedEmbeddedFiles)
        #expect(report.removedMetadata)
        #expect(report.removedActionCount >= 3)

        // No object streams in the input, none added by a sanitise-only write: every remaining
        // dictionary is plain text in the output.
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        for key in keys { #expect(!text.contains(key), "\(key) survived sanitising") }
        #expect(IndependentReader.pageCount(of: output) == 1)
    }

    // MARK: - Flatten

    @Test("Flattening burns the drawing's own annotation into the page and removes it")
    func flattens() throws {
        let box = try Sandbox("flattens")
        let input = try Self.write(Self.hazardousDrawing(), in: box)
        let output = box.file("flat.pdf")
        let report = try QPDF.transform(input: input, output: output, transform: QPDFTransform(flattensAnnotations: true))
        #expect(report.flattenedAnnotationCount == 1)
        let page = try #require(CGPDFDocument(output as CFURL)?.page(at: 1))
        var annots: CGPDFArrayRef?
        let stillAnnotated = page.dictionary.map { CGPDFDictionaryGetArray($0, "Annots", &annots) } ?? false
        #expect(!stillAnnotated || annots.map(CGPDFArrayGetCount) == 0)

        // The square's red border is now page content: Core Graphics, which draws no annotations,
        // draws it. The original page drawn the same way does not.
        #expect(Self.redPixels(in: output) > 100)
        #expect(Self.redPixels(in: input) == 0)
    }

    static func redPixels(in url: URL) -> Int {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1),
              let context = CGContext(
                  data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return -1 }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.drawPDFPage(page)
        guard let data = context.data else { return -1 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 400 * 400 * 4)
        var count = 0
        for pixel in 0..<(400 * 400) where bytes[pixel * 4] > 200 && bytes[pixel * 4 + 1] < 80 {
            count += 1
        }
        return count
    }

    // MARK: - Compress

    @Test("Compressing a copy makes it smaller and changes no page")
    func compresses() throws {
        let box = try Sandbox("compresses")
        let input = try Self.write(Self.hazardousDrawing(), in: box)
        let output = box.file("small.pdf")
        let report = try QPDF.transform(input: input, output: output, transform: QPDFTransform(compresses: true))
        #expect(report.outputByteCount > 0)
        #expect(report.outputByteCount * 10 < report.inputByteCount * 6, "\(report.outputByteCount) of \(report.inputByteCount) bytes")
        #expect(IndependentReader.mediaBoxes(of: output) == IndependentReader.mediaBoxes(of: input))
    }

    @Test("Operations combine: flatten, sanitise, compress and encrypt in one copy")
    func combines() throws {
        let box = try Sandbox("combines")
        let input = try Self.write(Self.hazardousDrawing(), in: box)
        let output = box.file("all.pdf")
        let report = try QPDF.transform(
            input: input, output: output,
            transform: QPDFTransform(
                flattensAnnotations: true, compresses: true, sanitizes: true,
                protection: .init(permissionsPassword: "owner"), linearizes: true
            )
        )
        #expect(report.flattenedAnnotationCount == 1)
        // Empty open password: anyone opens it, the permissions still bind.
        let inventory = try QPDF.inspect(output)
        #expect(inventory.encryption?.revision == 6)
        #expect(inventory.isLinearized)
    }
}
