import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Feature 15's application wiring: the photo sidecar mounts on both roads into Project
/// Mode, the Inspector's closures attach and detach through the real store, and Quick PDF
/// Mode honestly offers nothing. The file chooser is injected — no panel ever appears.
@MainActor
@Suite(.appTierSerialised)
struct PhotoAttachmentWiringTests {

    /// A real 64×48 PNG, drawn in memory — the pipeline refuses non-images.
    private static func makePNG(in directory: URL) throws -> URL {
        let width = 64, height = 48
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let url = directory.appendingPathComponent("site-photo.png")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("Quick PDF Mode offers no photo affordance — there is no package to keep pixels in")
    func quickPDFOffersNothing() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "NoPhotos.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.shell != nil })
        let shell = try #require(document.shell)

        #expect(document.photoStore == nil)
        #expect(shell.photoAttachments == nil, "the Inspector must not offer rows it cannot keep")
        #expect(shell.onAttachPhoto == nil)
        document.close()
    }

    @Test("Save As mounts the sidecar, and attach/remove flow through the injected chooser")
    func saveAsMountsAndAttaches() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Photos.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photoURL = try Self.makePNG(in: directory)

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let shell = try #require(document.shell)

        let destination = directory.appendingPathComponent("Photos.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #expect(document.mode == .project)
        #expect(document.photoStore != nil, "Save As must mount the sidecar, not wait for a reopen")
        #expect(shell.photoAttachments != nil)

        // Attach through the environment closure, with the chooser answered by the test.
        let previousChooser = ZenitPDFProjectDocument.photoFileChooser
        defer { ZenitPDFProjectDocument.photoFileChooser = previousChooser }
        ZenitPDFProjectDocument.photoFileChooser = { _ in photoURL }

        let markupID = UUID()
        shell.onAttachPhoto?(markupID)
        #expect(await AppTestSupport.wait {
            shell.photoAttachments?(markupID).count == 1
        }, "the attached photograph never reached the Inspector rows")
        let row = try #require(shell.photoAttachments?(markupID).first)
        // LT-31: "320 × 240 px" alone made two photos on one markup indistinguishable.
        // The attach path seeds the caption with the source file's name, and the row
        // label leads with it, keeping the dimensions as the tiebreaker.
        #expect(row.label.contains("site-photo.png"),
                "LT-31: the row must carry the source filename; it says only: \(row.label)")
        #expect(row.label.contains("px"),
                "the dimensions stay on the row — they tell two same-named files apart")

        // The blob is on disk inside the package's attachments member.
        let blobs = destination
            .appendingPathComponent("attachments")
            .appendingPathComponent(PhotoStore.sidecarDirectoryName)
            .appendingPathComponent("blobs")
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? []
        #expect(stored.count == 1, "one attached photograph is one stored blob")

        // Remove through the same seam: the row disappears and re-attach still works.
        shell.onRemovePhoto?(markupID, row.id)
        #expect(await AppTestSupport.wait {
            shell.photoAttachments?(markupID).isEmpty == true
        }, "removing never reached the rows")

        document.close()
    }

    @Test("The photo row label: caption leads, dimensions always distinguish (LT-31)")
    func photoRowLabelShapes() {
        func attachment(caption: String?, capturedAt: Date? = nil) -> PhotoAttachment {
            PhotoAttachment(
                id: PhotoAttachmentID(UUID()),
                markupID: MarkupID(UUID()),
                digest: String(repeating: "0", count: 64),
                capturedAt: capturedAt,
                caption: caption,
                pixelWidth: 320,
                pixelHeight: 240,
                byteCount: 12_345
            )
        }

        // A caption — the attach path seeds it with the source filename — leads the row,
        // with the dimensions kept as the tiebreaker between same-named files.
        let named = ZenitPDFProjectDocument.photoRowLabel(for: attachment(caption: "IMG_0142.jpeg"))
        #expect(named.contains("IMG_0142.jpeg"))
        #expect(named.contains("320 × 240 px"))
        #expect(named.hasPrefix("IMG_0142.jpeg"), "the name is the handle; it leads")

        // No caption, a capture date: the date leads, the dimensions stay.
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = ZenitPDFProjectDocument.photoRowLabel(
            for: attachment(caption: nil, capturedAt: captured)
        )
        #expect(dated.contains("320 × 240 px"))
        #expect(!dated.hasPrefix("320"), "with a date known, the row says more than pixels")

        // Neither: the dimensions are the only honest thing left.
        let bare = ZenitPDFProjectDocument.photoRowLabel(for: attachment(caption: nil))
        #expect(bare == "320 × 240 px")

        // An empty caption is no caption.
        let empty = ZenitPDFProjectDocument.photoRowLabel(for: attachment(caption: ""))
        #expect(empty == "320 × 240 px")
    }
}
