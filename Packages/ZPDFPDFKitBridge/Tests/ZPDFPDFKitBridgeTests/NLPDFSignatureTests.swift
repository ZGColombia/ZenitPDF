import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// NL-PDF-15: signatures detected, verified offline, and reported as intact, intact with later
/// revisions, or modified.
///
/// The signed fixture is made here, at test time, by the system's own `/usr/bin/openssl`: a
/// throwaway self-signed certificate and a detached PKCS#7 over the fixture's byte ranges. No
/// keychain is touched and nothing is checked in.
@Suite("nl-pdf signatures", .serialized)
struct NLPDFSignatureTests {

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

    @Test("A signed file is intact and names its signer; a flipped byte is modified; an appended revision keeps the signature")
    func signaturesAreVerified() throws {
        let directory = try Corpus.scratchDirectory("nlpdf-signature")
        let signed = try Self.signedPDF(in: directory)

        let intact = try #require(SignatureInspector.signatures(in: signed).first)
        #expect(intact.integrity == .intact)
        #expect(intact.signer == "Zenit Test Signer")
        #expect(intact.coversWholeFile)
        #expect(!intact.certificateTrusted, "a throwaway self-signed certificate is not trusted, and was never looked up")
        #expect(intact.subFilter == "adbe.pkcs7.detached")

        // A byte inside the signed range, changed in place: the file was modified after signing.
        // The page's media box, 200 wide, rewritten as 201 — the file still parses.
        let text = String(decoding: signed, as: UTF8.self)
        let tampered = Data(text.replacingOccurrences(of: "/MediaBox [0 0 200 200]", with: "/MediaBox [0 0 201 200]").utf8)
        #expect(tampered.count == signed.count && tampered != signed)
        #expect(SignatureInspector.signatures(in: tampered).first?.integrity == .modified)

        // An incremental revision appended after the signed bytes: still intact, and said so.
        var appended = signed
        appended.append(Data("\n% a later revision\n".utf8))
        #expect(SignatureInspector.signatures(in: appended).first?.integrity == .intactWithLaterRevisions)
        #expect(DocumentHazardProbe.hazards(ofFileAt: {
            let url = directory.appendingPathComponent("signed.pdf")
            try? signed.write(to: url)
            return url
        }()).contains(.signedDocument))
    }

    @Test("An unsigned file has no signatures")
    func unsignedHasNone() throws {
        #expect(SignatureInspector.signatures(in: NLPDFAnnotationFixTests.formDocument(signatureValue: false)).isEmpty)
    }
}
