import AppKit
import Foundation
import Testing
import ZPDFAppCore
@testable import ZenitPDFAppKit

/// NL-PDF-15, the row a person reads: a signed drawing says on open who signed it, when, and
/// whether it is intact; a changed copy says "modified after signing". No window, no modal.
@MainActor
@Suite("Signature status on open (NL-PDF-15)", .appTierSerialised)
struct NLPDFR2SignatureStatusTests {

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    @Test("The lines name signer, date and state; a broken signature is a warning, an untrusted one says it was checked offline")
    func linesAndNote() throws {
        let date = Date(timeIntervalSince1970: 1_790_164_800) // 2026-09-23 12:00 UTC
        let intact = DrawingSignatureStatus.Line(signer: "Jane Engineer", signingTime: date, state: .intact, certificateTrusted: false)
        #expect(DrawingSignatureStatus.lines(for: [intact], dateFormatter: Self.formatter) == ["Signed by Jane Engineer on 23 Sep 2026 — intact"])
        let one = try #require(DrawingSignatureStatus.note(for: [intact], dateFormatter: Self.formatter))
        #expect(one.title == "Signed by Jane Engineer on 23 Sep 2026 — intact")
        #expect(one.severity == .info)
        #expect(one.message.contains("Nothing was looked up online"))
        #expect(one.message.contains("keep the signature valid"))

        let modified = DrawingSignatureStatus.Line(signer: nil, signingTime: nil, state: .modified, certificateTrusted: true)
        let two = try #require(DrawingSignatureStatus.note(for: [intact, modified], dateFormatter: Self.formatter))
        #expect(two.title == "2 signatures: 1 intact, 1 not.")
        #expect(two.severity == .warning)
        #expect(two.message.contains("Signed by an unreadable certificate — modified after signing"))
        #expect(DrawingSignatureStatus.note(for: [], dateFormatter: Self.formatter) == nil)
    }

    @Test("Opening a signed drawing posts 'Signed by … — intact'; a byte-flipped copy posts 'modified after signing'")
    func openingSaysIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-sigstatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signed = try SignedFixture.signedPDF(in: directory)
        let intactURL = directory.appendingPathComponent("Sealed.pdf")
        try signed.write(to: intactURL)
        let tampered = Data(String(decoding: signed, as: UTF8.self)
            .replacingOccurrences(of: "/MediaBox [0 0 200 200]", with: "/MediaBox [0 0 201 200]").utf8)
        let tamperedURL = directory.appendingPathComponent("Sealed changed.pdf")
        try tampered.write(to: tamperedURL)

        for (url, state) in [(intactURL, "— intact"), (tamperedURL, "— modified after signing")] {
            // Old behaviour: nothing was said on open; the signature showed only in export warnings.
            let document = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
            let core = try #require(document.core)
            #expect(await AppTestSupport.wait {
                core.document.warnings.contains { $0.title.hasPrefix("Signed by Zenit Test Signer") && $0.title.hasSuffix(state) }
            }, "\(url.lastPathComponent): \(core.document.warnings.map(\.title))")
            await document.drawing?.rasterSource.close()
            document.close()
        }
    }
}

/// A one-page PDF signed at test time by the system's `/usr/bin/openssl` with a throwaway
/// self-signed certificate over everything but its `/Contents` placeholder. No keychain.
enum SignedFixture {

    static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }

    static func signedPDF(in directory: URL) throws -> Data {
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                 "-days", "30", "-subj", "/CN=Zenit Test Signer"])
        let placeholder = String(repeating: "0", count: 8192)
        let content = "0 0 0 RG 10 10 m 190 190 l S"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [0 0 0 0] /P 3 0 R /V 5 0 R >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached"
                + " /ByteRange [0000000000 0000000000 0000000000 0000000000]"
                + " /Contents <\(placeholder)> /M (D:20260923120000Z) >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
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
        func find(_ text: String) throws -> Int {
            let marker = Array(text.utf8)
            guard let found = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<$0 + marker.count]) == marker })
            else { throw CocoaError(.fileReadCorruptFile) }
            return found
        }
        let contentsStart = try find("/Contents <") + "/Contents <".utf8.count - 1
        let contentsEnd = contentsStart + placeholder.count + 2
        let range = String(format: "%010d %010d %010d %010d", 0, contentsStart, contentsEnd, bytes.count - contentsEnd)
        let rangeAt = try find("0000000000 0000000000 0000000000 0000000000")
        bytes.replaceSubrange(rangeAt..<rangeAt + range.utf8.count, with: Array(range.utf8))
        let signedBytes = Data(bytes[0..<contentsStart] + bytes[contentsEnd..<bytes.count])
        let input = directory.appendingPathComponent("signed-content.bin")
        let output = directory.appendingPathComponent("signature.der")
        try signedBytes.write(to: input)
        try run(["smime", "-sign", "-binary", "-noattr", "-in", input.path, "-signer", cert, "-inkey", key,
                 "-outform", "DER", "-out", output.path])
        var hex = try Data(contentsOf: output).map { String(format: "%02X", $0) }.joined()
        guard hex.count <= placeholder.count else { throw CocoaError(.fileWriteOutOfSpace) }
        hex += String(repeating: "0", count: placeholder.count - hex.count)
        bytes.replaceSubrange(contentsStart + 1..<contentsEnd - 1, with: Array(hex.utf8))
        return Data(bytes)
    }
}
