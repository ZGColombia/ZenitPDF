import Foundation
import Testing
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRenderer
@testable import ZPDFExport

/// NL-PDF-15's other half: the annotated export of a signed drawing is an incremental update, so
/// the original signature's byte ranges still hash to what was signed.
@Suite("Signed drawings stay signed (NL-PDF-15)", .sharedHeap, .serialized)
struct SignedDrawingExportTests {

    static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")

    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = openssl
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "openssl \(arguments.first ?? "") failed"])
        }
    }

    /// A one-page PDF signed over everything but its `/Contents` placeholder.
    static func signedPDF(in directory: URL) throws -> Data {
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                 "-days", "30", "-subj", "/CN=Zenit Test Signer"])

        let placeholder = String(repeating: "0", count: 8192)
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [0 0 0 0] /P 3 0 R /V 5 0 R >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached"
                + " /ByteRange [0000000000 0000000000 0000000000 0000000000]"
                + " /Contents <\(placeholder)> /M (D:20260923120000Z) >>"
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

        var bytes = [UInt8](pdf)
        let marker = Array("/Contents <".utf8)
        guard let found = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<$0 + marker.count]) == marker })
        else { throw CocoaError(.fileReadCorruptFile) }
        let contentsStart = found + marker.count - 1          // the '<'
        let contentsEnd = contentsStart + placeholder.count + 2 // past the '>'
        let range = String(format: "%010d %010d %010d %010d", 0, contentsStart, contentsEnd, bytes.count - contentsEnd)
        let rangeMarker = Array("0000000000 0000000000 0000000000 0000000000".utf8)
        guard let rangeAt = (0...(bytes.count - rangeMarker.count)).first(where: { Array(bytes[$0..<$0 + rangeMarker.count]) == rangeMarker })
        else { throw CocoaError(.fileReadCorruptFile) }
        bytes.replaceSubrange(rangeAt..<rangeAt + rangeMarker.count, with: Array(range.utf8))

        let signed = Data(bytes[0..<contentsStart] + bytes[contentsEnd..<bytes.count])
        let input = directory.appendingPathComponent("signed-content.bin")
        let output = directory.appendingPathComponent("signature.der")
        try signed.write(to: input)
        try run(["smime", "-sign", "-binary", "-noattr", "-in", input.path, "-signer", cert, "-inkey", key,
                 "-outform", "DER", "-out", output.path])
        let signature = try Data(contentsOf: output)
        var hex = signature.map { String(format: "%02X", $0) }.joined()
        guard hex.count <= placeholder.count else { throw CocoaError(.fileWriteOutOfSpace) }
        hex += String(repeating: "0", count: placeholder.count - hex.count)
        bytes.replaceSubrange(contentsStart + 1..<contentsEnd - 1, with: Array(hex.utf8))
        return Data(bytes)
    }

    @Test("Annotating a signed drawing leaves its signature intact, with a later revision")
    func annotatedExportKeepsTheSignature() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-signed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try Self.signedPDF(in: directory)
        #expect(SignatureInspector.signatures(in: signed).first?.integrity == .intact)

        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 200, height: 200), crop: PDFRect(x: 0, y: 0, width: 200, height: 200)),
            rotation: .degrees0
        )
        let id = UUID()
        let points = [PDFPoint(x: 20, y: 20), PDFPoint(x: 180, y: 20), PDFPoint(x: 100, y: 160)]
        let annotation = StandardAnnotation(
            id: id,
            geometry: .polygon(points),
            stroke: RGBAColor(red: 0, green: 0, blue: 1),
            appearance: [RenderableMarkup(
                id: MarkupID(id),
                shape: .polyline(RenderPolyline(points: points, isClosed: true)),
                style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 1), lineWidth: 1)
            )]
        )
        let produced = try StandardAnnotationWriter().data(
            source: signed,
            pages: [StandardAnnotationPage(page: page, sourcePageIndex: 0, annotations: [annotation])]
        )
        #expect(produced.outcome.writtenAnnotationCount == 1)
        #expect(produced.data.prefix(signed.count) == signed)
        // The first annotated export rewrote the file through PDFKit: the byte ranges then pointed
        // at different bytes and the signature read as modified.
        #expect(SignatureInspector.signatures(in: produced.data).first?.integrity == .intactWithLaterRevisions)
    }
}
