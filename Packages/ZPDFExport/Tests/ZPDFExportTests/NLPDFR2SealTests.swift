import CoreGraphics
import Foundation
import PDFKit
import Security
import Testing
import ZPDFContracts
import ZPDFPDFKitBridge
@testable import ZPDFExport

/// NL-PDF-16 round 2: a visible seal drawn from stamp artwork, and the PAdES baseline profile —
/// a CAdES SignedData with signing-certificate-v2 and no signing-time — verified by the offline
/// inspector and independently by openssl. The key is made by openssl for the test and imported
/// with SecKeyCreateWithData: no keychain is touched.
@Suite("Seal and PAdES (NL-PDF-16)", .sharedHeap, .serialized)
struct NLPDFR2SealTests {

    static func output(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }

    /// A throwaway RSA certificate and its key as a SecKey, plus a CAdES signer over them.
    static func cadesSigner(in directory: URL) throws -> (signer: (Data) throws -> Data, certificate: URL) {
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        let keyDER = directory.appendingPathComponent("key.der")
        let certDER = directory.appendingPathComponent("cert.der")
        try SignedDrawingExportTests.run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                                          "-days", "30", "-subj", "/CN=Zenit PAdES Test"])
        try SignedDrawingExportTests.run(["rsa", "-in", key, "-outform", "DER", "-out", keyDER.path])
        try SignedDrawingExportTests.run(["x509", "-in", cert, "-outform", "DER", "-out", certDER.path])
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateWithData(try Data(contentsOf: keyDER) as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ] as CFDictionary, &error))
        let certificate = try Data(contentsOf: certDER)
        let signer: (Data) throws -> Data = { covered in
            try CAdESSignedData.build(content: covered, certificate: certificate, keyKind: .rsa) { attributes in
                var failure: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, attributes as CFData, &failure) else {
                    throw failure!.takeRetainedValue() as Error
                }
                return signature as Data
            }
        }
        return (signer, URL(fileURLWithPath: cert))
    }

    static func sealArtwork() -> ArtworkGeometry {
        // A ring and a bar: an engineer's seal, in unit space.
        let ring = (0..<24).map { i -> PDFPoint in
            let a = Double(i) / 24 * 2 * .pi
            return PDFPoint(x: 0.5 + 0.45 * cos(a), y: 0.5 + 0.45 * sin(a))
        }
        let inner = ring.map { PDFPoint(x: 0.5 + ($0.x - 0.5) * 0.8, y: 0.5 + ($0.y - 0.5) * 0.8) }
        return ArtworkGeometry(kind: .vector, regions: [ArtworkRegion(outer: ring, holes: [inner]),
                                                         ArtworkRegion(outer: [PDFPoint(x: 0.3, y: 0.45), PDFPoint(x: 0.7, y: 0.45), PDFPoint(x: 0.7, y: 0.55), PDFPoint(x: 0.3, y: 0.55)])])
    }

    @Test("PAdES B-B: ETSI.CAdES.detached, signing-certificate-v2 present, signing-time absent, intact, verified by openssl; the seal is drawn")
    func padesWithVisibleSeal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-pades-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (signer, certificate) = try Self.cadesSigner(in: directory)
        let source = LayeredSourceFixtures.plain()
        let seal = PDFSignatureWriter.Seal(
            pageIndex: 0, rect: PDFRect(x: 200, y: 40, width: 180, height: 60),
            lines: ["Digitally signed by Zenit PAdES Test", "2026-09-26 14:00", "Approved for construction"],
            artwork: Self.sealArtwork()
        )
        var captured = Data()
        let signed = try PDFSignatureWriter().data(
            source: source,
            options: .init(reason: "Approved for construction", signerName: "Zenit PAdES Test", profile: .cadesDetached, seal: seal),
            signer: { covered in captured = covered; return try signer(covered) }
        )
        // Old behaviour: adbe.pkcs7.detached only, always invisible.
        let signature = try #require(SignatureInspector.signatures(in: signed).first)
        #expect(signature.integrity == .intact)
        #expect(signature.subFilter == "ETSI.CAdES.detached")
        #expect(signature.signer == "Zenit PAdES Test")

        // Independent check: openssl verifies the CMS over the covered bytes, and its structure
        // carries signing-certificate-v2 and no signing-time.
        let scan = try PDFDocumentScan(data: signed)
        let sigDictionary = try #require(scan.objects.values.compactMap { $0.object.dictionaryValue }.first { $0["Type"]?.nameValue == "Sig" })
        guard case let .hexString(der)? = sigDictionary["Contents"] else { Issue.record("no /Contents"); return }
        let trimmed = Data(der.prefix { _ in true })
        let sigFile = directory.appendingPathComponent("sig.der"), contentFile = directory.appendingPathComponent("covered.bin")
        // The placeholder is zero-padded after the DER; asn1parse and smime read the first element.
        let element = try #require(DER.element([UInt8](trimmed), at: 0))
        try Data(trimmed[element.start..<element.end]).write(to: sigFile)
        try captured.write(to: contentFile)
        _ = try Self.output(["smime", "-verify", "-binary", "-inform", "DER", "-in", sigFile.path, "-content", contentFile.path,
                             "-noverify", "-out", "/dev/null"])
        let structure = try Self.output(["asn1parse", "-inform", "DER", "-in", sigFile.path])
        #expect(structure.contains("1.2.840.113549.1.9.16.2.47") || structure.contains("signingCertificateV2"))
        #expect(!structure.contains("signingTime"), "PAdES carries the time in /M, not as an attribute")
        _ = certificate

        // The seal: a printable widget at the rect, whose appearance draws the lines and the artwork.
        let document = try #require(PDFDocument(data: signed))
        let widget = try #require(document.page(at: 0)?.annotations.first { $0.type == "Widget" })
        #expect(abs(widget.bounds.minX - 200) < 0.5 && abs(widget.bounds.width - 180) < 0.5)
        let appearance = try #require(scan.objects.values.first {
            if case let .stream(d, data) = $0.object, d["Subtype"]?.nameValue == "Form" { return String(decoding: data, as: UTF8.self).contains("Digitally signed") }
            return false
        })
        if case let .stream(_, data) = appearance.object {
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("f*"), "the artwork's regions are filled")
            #expect(text.contains("Approved for construction"))
        }
        // Rendered, the seal's box is not blank.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        document.page(at: 0)?.draw(with: .mediaBox, to: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var inked = 0
        for y in 200..<260 { for x in 200..<380 where pixels[(y * 400 + x) * 4] < 200 { inked += 1 } }
        #expect(inked > 200, "\(inked) inked pixels in the seal box")
    }
}
