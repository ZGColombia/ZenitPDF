import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
@testable import ZenitPDFAppKit

/// NL-PDF-22 in the app: a photographed signature becomes a stamp tool named for what it is,
/// stored in the project, refused in Quick PDF Mode with the reason.
@MainActor
@Suite("Signature image stamp (NL-PDF-22)", .appTierSerialised)
struct NLPDFR2SignatureStampTests {

    static func signaturePNG(at url: URL) throws {
        let context = CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 2400,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        context.setStrokeColor(CGColor(red: 0.05, green: 0.1, blue: 0.5, alpha: 1))
        context.setLineWidth(7)
        context.move(to: CGPoint(x: 40, y: 60))
        context.addCurve(to: CGPoint(x: 560, y: 120), control1: CGPoint(x: 200, y: 200), control2: CGPoint(x: 380, y: 0))
        context.strokePath()
        let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(writer))
    }

    @Test("A project gains a stamp tool 'Signature image (…)', with traced artwork; Quick PDF Mode is refused in words")
    func addsTheStamp() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Signature Stamp.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("my signature.png")
        try Self.signaturePNG(at: image)

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })

        // Quick PDF Mode: nowhere to store the picture, said plainly.
        guard case let .refused(reason) = await SignatureImageStamp.add(imageAt: image, to: document) else {
            Issue.record("a Quick PDF accepted artwork it cannot store"); return
        }
        #expect(reason.contains("Save this drawing as a project first"))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: directory.appendingPathComponent("Signature.zpdfproj"), ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // Old behaviour: a signature imported as a 96-cell mosaic, paper and all, named like any stamp.
        let outcome = await SignatureImageStamp.add(imageAt: image, to: document)
        guard case let .added(presetID) = outcome else { Issue.record("refused: \(outcome)"); return }
        let core = try #require(document.core)
        let preset = try #require(core.toolLibrary.presets.first { $0.id == presetID })
        // L-62: the long disclaimer name was cut short in the Tool Library; the disclaimer is the note.
        #expect(preset.name == "Signature image (my signature)")
        #expect(preset.markupKind == .stamp)
        let artwork = try #require(preset.stamp?.artwork)
        #expect(artwork.kind == .vector, "traced outlines stay sharp")
        let package = try #require(document.projectPackage)
        let stored = try await ProjectArtworkStore.geometry(forDigest: artwork.digest, in: package)
        let geometry = try #require(stored)
        #expect(!geometry.regions.isEmpty)
        #expect(core.document.warnings.contains { $0.message.contains("not a digital signature") })
    }
}
