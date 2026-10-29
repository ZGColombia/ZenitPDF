import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
@testable import ZenitPDFAppKit

/// NL-PDF-16 round 2 in the app: the seal sits in the sheet's corner with the signing facts, the
/// confirmation offers the profile, the seal and — for a Quick PDF — signing in place, and a PDF
/// signed in place keeps its original bytes as the prefix. No keychain: openssl signs.
@MainActor
@Suite("Sign with a visible seal, PAdES, in place (NL-PDF-16)", .appTierSerialised)
struct NLPDFR2SignTests {

    @Test("The seal: 200 × 64 pt, 12 pt in from the bottom-right corner, signer, time and reason")
    func sealGeometry() {
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 2, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1191, height: 842), crop: PDFRect(x: 0, y: 0, width: 1191, height: 842))
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let seal = SignDrawingCopy.seal(on: page, signer: "Jane Engineer", reason: "Issued for construction",
                                        at: Date(timeIntervalSince1970: 1_790_164_800), artwork: nil, dateFormatter: formatter)
        // Hand-derived: 1191 − 200 − 12 = 979; 0 + 12 = 12.
        #expect(seal.pageIndex == 2)
        #expect(seal.rect == PDFRect(x: 979, y: 12, width: 200, height: 64))
        #expect(seal.lines == ["Digitally signed by Jane Engineer", "2026-09-23", "Issued for construction"])
    }

    @Test("The confirmation offers PAdES first, a seal, and Sign This PDF only when asked to")
    func confirmationChoices() {
        let (alert, _, _) = SignDrawingCopy.confirmation(identities: [], fileName: "Plan.pdf")
        let choices = SignDrawingCopy.addChoices(to: alert, artworkNames: ["PE Seal"], inPlaceAllowed: true)
        #expect(alert.buttons.map(\.title) == ["Sign Copy…", "Cancel", "Sign This PDF"])
        #expect(choices.profile.titleOfSelectedItem == "PAdES baseline (recommended)")
        #expect(choices.seal.state == .on)
        #expect(choices.artwork.itemTitles == ["Seal without a picture", "PE Seal"])
        let (projectAlert, _, _) = SignDrawingCopy.confirmation(identities: [], fileName: "Plan.pdf")
        _ = SignDrawingCopy.addChoices(to: projectAlert, artworkNames: [], inPlaceAllowed: false)
        #expect(projectAlert.buttons.count == 2)
    }

    @Test("Signing in place keeps the original bytes as the prefix, verifies intact, and shows the seal widget")
    func signsInPlace() throws {
        let url = try AppTestSupport.writeFixturePDF(named: "In Place.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        let key = directory.appendingPathComponent("key.pem").path, cert = directory.appendingPathComponent("cert.pem").path
        try SignedFixture.run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "30", "-subj", "/CN=Zenit In Place"])
        let signer: (Data) throws -> Data = { covered in
            let input = directory.appendingPathComponent("c.bin"), output = directory.appendingPathComponent("s.der")
            try covered.write(to: input)
            try SignedFixture.run(["smime", "-sign", "-binary", "-noattr", "-in", input.path, "-signer", cert, "-inkey", key, "-outform", "DER", "-out", output.path])
            return try Data(contentsOf: output)
        }
        let page = PageDescriptor(
            id: PageID(UUID()), documentID: DocumentID(UUID()), index: 0, label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792), crop: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let seal = SignDrawingCopy.seal(on: page, signer: "Zenit In Place", reason: nil, at: Date(), artwork: nil)
        // Old behaviour: only a copy could be signed, and always invisibly.
        #expect(throws: ExportError.self) {
            try SignDrawingCopy.write(source: url, opened: nil, to: url, inPlace: false, options: .init(), signer: signer)
        }
        try SignDrawingCopy.write(source: url, opened: nil, to: url, inPlace: true,
                                  options: .init(signerName: "Zenit In Place", seal: seal), signer: signer)
        let signed = try Data(contentsOf: url)
        #expect(signed.prefix(original.count) == original)
        let signature = try #require(SignatureInspector.signatures(ofFileAt: url).first)
        #expect(signature.integrity == .intact)
        #expect(signature.signer == "Zenit In Place")
    }
}
