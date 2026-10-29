import Foundation
import PDFKit
import Testing
import ZPDFContracts
import ZPDFPDFKitBridge
@testable import ZPDFExport

/// NL-PDF-16's foundation: a drawing signed as an incremental update, verified by the offline
/// inspector, and still signed after a later Zenit save.
@Suite("Signing a drawing (NL-PDF-16)", .sharedHeap, .serialized)
struct PDFSignatureWriterTests {

    static func signer(in directory: URL) throws -> (Data) throws -> Data {
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        try SignedDrawingExportTests.run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                                          "-days", "30", "-subj", "/CN=Zenit Seal Test"])
        return { covered in
            let input = directory.appendingPathComponent("covered-\(UUID().uuidString).bin")
            let output = directory.appendingPathComponent("sig-\(UUID().uuidString).der")
            try covered.write(to: input)
            try SignedDrawingExportTests.run(["smime", "-sign", "-binary", "-noattr", "-in", input.path,
                                              "-signer", cert, "-inkey", key, "-outform", "DER", "-out", output.path])
            return try Data(contentsOf: output)
        }
    }

    @Test("A signed drawing verifies intact, names its signer, and keeps its source as the prefix")
    func signedDrawingVerifies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LayeredSourceFixtures.plain()
        let signed = try PDFSignatureWriter().data(
            source: source,
            options: .init(reason: "Approved for construction", signerName: "Seal Test"),
            signer: try Self.signer(in: directory)
        )
        #expect(signed.prefix(source.count) == source)
        let signature = try #require(SignatureInspector.signatures(in: signed).first)
        #expect(signature.integrity == .intact)
        #expect(signature.coversWholeFile)
        #expect(signature.signer == "Zenit Seal Test")
        #expect(PDFDocument(data: signed)?.pageCount == 1)

        // A later Zenit save — markups as annotations — appends after the signed bytes.
        let fixture = StandardAnnotationWriterTests.fixture()
        let annotated = try StandardAnnotationWriter().data(
            source: signed,
            pages: [StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: [fixture.area])]
        ).data
        #expect(SignatureInspector.signatures(in: annotated).first?.integrity == .intactWithLaterRevisions)
        // The widget the signature needs is kept on the page alongside the new annotation.
        let annotations = try StandardAnnotationWriterTests.annotations(in: annotated)
        #expect(annotations.contains { $0.dictionary["FT"]?.nameValue == "Sig" })
    }
}
