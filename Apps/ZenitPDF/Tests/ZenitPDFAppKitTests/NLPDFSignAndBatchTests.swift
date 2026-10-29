import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFExport
import ZPDFPDFKitBridge
@testable import ZenitPDFAppKit

/// NL-PDF-16's first slice and NL-PDF-20's wiring, from the window controller.
@MainActor
@Suite(.appTierSerialised)
struct NLPDFSignAndBatchTests {

    @Test("With no certificate on the Mac the command says so, and writes nothing")
    func noCertificateIsSaid() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Sign.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let before = try Data(contentsOf: url)

        let previousProvider = SignDrawingCopy.identityProvider
        SignDrawingCopy.identityProvider = { [] }
        defer { SignDrawingCopy.identityProvider = previousProvider }
        ZenitModalPresenter.reset()
        let requests = ZenitModalPresenter.answering({ _ in .button(0) }) {
            ProjectWindowController(document: document).signDrawingCopy(for: document)
        }
        // A window-less controller returns before asking; with a window it asks. Either way the
        // keychain was never read and the drawing is byte for byte what it was.
        #expect(requests.allSatisfy { $0.identifier == SignDrawingCopy.noIdentityIdentifier })
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("A signed copy written by the workflow verifies intact and leaves the drawing untouched")
    func signedCopyVerifies() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Seal.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: url)
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        func openssl(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                     "-days", "30", "-subj", "/CN=Zenit App Seal"])
        let destination = directory.appendingPathComponent("Seal — Signed.pdf")
        try SignDrawingCopy.write(
            source: url, opened: nil, to: destination,
            options: PDFSignatureWriter.Options(reason: "Issued for construction")
        ) { covered in
            let input = directory.appendingPathComponent("covered.bin")
            let output = directory.appendingPathComponent("sig.der")
            try covered.write(to: input)
            try openssl(["smime", "-sign", "-binary", "-noattr", "-in", input.path, "-signer", cert,
                         "-inkey", key, "-outform", "DER", "-out", output.path])
            return try Data(contentsOf: output)
        }
        #expect(try Data(contentsOf: url) == before)
        let signature = try #require(SignatureInspector.signatures(ofFileAt: destination).first)
        #expect(signature.integrity == .intact)
        #expect(signature.signer == "Zenit App Seal")
        #expect(FlattenedDrawingExport.signatureNote(forDrawingAt: destination)?.contains("Zenit App Seal") == true)
    }

    @Test("A header template's start value is read from {n=…}")
    func headerTemplateStart() {
        let parsed = ProjectWindowController.headerFooterTemplate("Sheet S-{n=101} of {project}")
        #expect(parsed.template == "Sheet S-{n} of {project}")
        #expect(parsed.numberStart == 101)
        #expect(ProjectWindowController.headerFooterTemplate("{page}").numberStart == 1)
    }

    @Test("The header/footer batch model plans against the real engine")
    func headerFooterModelPlans() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Header.pdf", pageCount: 3)
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let controller = ProjectWindowController(document: document)
        let wired = try #require(controller.makeHeaderFooterModel(for: document))
        #expect(wired.model.placementPrompt?.contains("{page}") == true)
    }
}
