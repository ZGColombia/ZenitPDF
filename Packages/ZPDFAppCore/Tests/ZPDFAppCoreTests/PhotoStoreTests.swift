import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence

/// Site photographs attach to markups through a real directory on a real
/// filesystem, the stated budget is enforced by refusal rather than by hope, and the
/// pixels are stored once per digest however many markups share them. Nothing here
/// stubs the disk.
struct PhotoStoreTests {

    // MARK: - Fixtures

    private func makeWorkspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-photos-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A synthetic photograph: a deterministic gradient (compresses well) or seeded
    /// noise (compresses badly, for exercising the byte caps), optionally carrying an
    /// EXIF capture time. Deterministic by construction — no randomness, no clock.
    private func makeImageData(
        width: Int,
        height: Int,
        noiseSeed: UInt64? = nil,
        utType: UTType = .png,
        exifDateTimeOriginal: String? = nil
    ) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if let seed = noiseSeed {
            var state = seed
            for index in pixels.indices {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                pixels[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    pixels[offset] = UInt8((x * 255) / max(1, width - 1))
                    pixels[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                    pixels[offset + 2] = UInt8(((x + y) * 255) / max(1, width + height - 2))
                    pixels[offset + 3] = 255
                }
            }
        }

        let image: CGImage? = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
        let made = try #require(image)

        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            encoded, utType.identifier as CFString, 1, nil
        ))
        var options: [CFString: Any] = [:]
        if let exifDateTimeOriginal {
            options[kCGImagePropertyExifDictionary] =
                [kCGImagePropertyExifDateTimeOriginal: exifDateTimeOriginal]
        }
        CGImageDestinationAddImage(destination, made, options as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    /// Pixel size of encoded image bytes, read through ImageIO — the check that the
    /// recorded size is the actual size, not an echo of the writer's intention.
    private func decodedPixelSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return (width, height)
    }

    private func blobNames(in workspace: URL) -> [String] {
        FileDurability.directoryEntryNames(
            at: workspace.appendingPathComponent(PhotoStore.blobsDirectoryName, isDirectory: true)
        ).filter { $0.hasSuffix(".jpg") }
    }

    // MARK: - The stated budget

    @Test("The standard budget is the documented one: 2048 px, quality 0.8, 2 MiB per photo, 64 MiB per project")
    func standardBudgetStatesTheDocumentedNumbers() {
        #expect(PhotoBudget.standard.longestEdgePixels == 2048)
        #expect(PhotoBudget.standard.compressionQuality == 0.8)
        #expect(PhotoBudget.standard.bytesPerPhoto == 2 * 1024 * 1024)
        #expect(PhotoBudget.standard.bytesPerProject == 64 * 1024 * 1024)
        #expect(PhotoBudget.standard == PhotoBudget(
            longestEdgePixels: PhotoBudget.maximumLongestEdgePixels,
            compressionQuality: PhotoBudget.jpegCompressionQuality,
            bytesPerPhoto: PhotoBudget.maximumStoredBytesPerPhoto,
            bytesPerProject: PhotoBudget.maximumProjectPhotoBytes
        ))
    }

    @Test("A 4000-px photograph stores at the stated 2048-px longest edge, inside the per-photo cap")
    func downscaleHonoursTheStatedLimit() async throws {
        let workspace = try makeWorkspace("downscale")
        let store = try PhotoStore(directory: workspace)
        let markup = MarkupID(UUID())
        let source = try makeImageData(width: 4000, height: 3000)

        let attachment = try await store.addPhoto(imageData: source, to: markup)

        #expect(max(attachment.pixelWidth, attachment.pixelHeight) == 2048)
        #expect(min(attachment.pixelWidth, attachment.pixelHeight) <= 2048)
        #expect(attachment.byteCount <= PhotoBudget.maximumStoredBytesPerPhoto)

        // The recorded size must be the stored bytes' actual size, decoded back.
        let stored = try await store.photoData(for: attachment)
        #expect(stored.count == attachment.byteCount)
        let size = try decodedPixelSize(of: stored)
        #expect(size.width == attachment.pixelWidth)
        #expect(size.height == attachment.pixelHeight)
    }

    @Test("A photograph already inside the limit keeps its own size — the pipeline never upscales")
    func smallPhotographIsNotUpscaled() async throws {
        let workspace = try makeWorkspace("noupscale")
        let store = try PhotoStore(directory: workspace)
        let source = try makeImageData(width: 800, height: 600)

        let attachment = try await store.addPhoto(imageData: source, to: MarkupID(UUID()))

        #expect(attachment.pixelWidth == 800)
        #expect(attachment.pixelHeight == 600)
    }

    @Test("An add past the project budget is refused with the numbers in it, and stores nothing")
    func overBudgetAddRefusesRatherThanStores() async throws {
        let workspace = try makeWorkspace("projectcap")
        // The standard budget's numbers except the project cap, so the refusal machinery
        // is provable without 64 MiB of fixtures. The standard numbers themselves are
        // pinned by `standardBudgetStatesTheDocumentedNumbers`.
        let budget = PhotoBudget(
            longestEdgePixels: PhotoBudget.maximumLongestEdgePixels,
            compressionQuality: PhotoBudget.jpegCompressionQuality,
            bytesPerPhoto: PhotoBudget.maximumStoredBytesPerPhoto,
            bytesPerProject: 10_000
        )
        let store = try PhotoStore(directory: workspace, budget: budget)
        // Seeded noise defeats JPEG compression, so the processed photograph lands far
        // above 10 000 bytes.
        let source = try makeImageData(width: 256, height: 256, noiseSeed: 0x5EED)

        do {
            _ = try await store.addPhoto(imageData: source, to: MarkupID(UUID()))
            Issue.record("an add past the project budget was stored instead of refused")
        } catch let refusal as PhotoImportRefusal {
            guard case let .projectPhotoBudgetExceeded(storedBytes, incomingBytes, limit) = refusal else {
                Issue.record("wrong refusal: \(refusal)")
                return
            }
            #expect(storedBytes == 0)
            #expect(incomingBytes > 10_000)
            #expect(limit == 10_000)
            // The number reaches the person, not just the log.
            #expect(refusal.reason.contains("10000"))
        }

        // Refused means *nothing* was stored: no attachment, no blob, and a reopen
        // agrees.
        #expect(await store.allAttachments().isEmpty)
        #expect(blobNames(in: workspace).isEmpty)
        let reopened = try PhotoStore(directory: workspace, budget: budget)
        #expect(await reopened.allAttachments().isEmpty)
    }

    @Test("A photograph over the per-photo cap is refused, not stored")
    func oversizedPhotographIsRefused() async throws {
        let workspace = try makeWorkspace("photocap")
        let budget = PhotoBudget(
            longestEdgePixels: PhotoBudget.maximumLongestEdgePixels,
            compressionQuality: PhotoBudget.jpegCompressionQuality,
            bytesPerPhoto: 10_000,
            bytesPerProject: PhotoBudget.maximumProjectPhotoBytes
        )
        let store = try PhotoStore(directory: workspace, budget: budget)
        let source = try makeImageData(width: 256, height: 256, noiseSeed: 0xBEEF)

        do {
            _ = try await store.addPhoto(imageData: source, to: MarkupID(UUID()))
            Issue.record("an over-cap photograph was stored instead of refused")
        } catch let refusal as PhotoImportRefusal {
            guard case let .photoTooLarge(bytes, limit) = refusal else {
                Issue.record("wrong refusal: \(refusal)")
                return
            }
            #expect(bytes > 10_000)
            #expect(limit == 10_000)
        }
        #expect(await store.allAttachments().isEmpty)
        #expect(blobNames(in: workspace).isEmpty)
    }

    // MARK: - Persistence round trip

    @Test("Two photos on two markups survive write and reload: bytes identical, attribution intact")
    func roundTripThroughARealDirectory() async throws {
        let workspace = try makeWorkspace("roundtrip")
        let markupA = MarkupID(UUID())
        let markupB = MarkupID(UUID())
        let capturedA = Date(timeIntervalSince1970: 1_770_000_000)
        let capturedB = Date(timeIntervalSince1970: 1_770_100_000)

        let store = try PhotoStore(directory: workspace)
        let first = try await store.addPhoto(
            imageData: try makeImageData(width: 1200, height: 900),
            to: markupA,
            capturedAt: capturedA,
            caption: "junction box, east riser"
        )
        let second = try await store.addPhoto(
            imageData: try makeImageData(width: 900, height: 1200, noiseSeed: 42),
            to: markupB,
            capturedAt: capturedB,
            caption: "slab penetration"
        )
        #expect(first.digest != second.digest)
        let firstBytes = try await store.photoData(for: first)
        let secondBytes = try await store.photoData(for: second)

        // Reload from disk alone: a brand-new store over the same directory.
        let reopened = try PhotoStore(directory: workspace)
        let all = await reopened.allAttachments()
        #expect(all.count == 2)

        let reloadedFirst = try #require(await reopened.attachments(forMarkup: markupA).first)
        #expect(reloadedFirst.id == first.id)
        #expect(reloadedFirst.markupID == markupA)
        #expect(reloadedFirst.digest == first.digest)
        #expect(reloadedFirst.caption == "junction box, east riser")
        #expect(reloadedFirst.capturedAt == capturedA)
        #expect(reloadedFirst.pixelWidth == first.pixelWidth)
        #expect(reloadedFirst.pixelHeight == first.pixelHeight)
        #expect(reloadedFirst.byteCount == first.byteCount)

        let reloadedSecond = try #require(await reopened.attachments(forMarkup: markupB).first)
        #expect(reloadedSecond.id == second.id)
        #expect(reloadedSecond.caption == "slab penetration")
        #expect(reloadedSecond.capturedAt == capturedB)

        // Byte-identical, and each byte still hashes to its own name (photoData verifies).
        #expect(try await reopened.photoData(for: reloadedFirst) == firstBytes)
        #expect(try await reopened.photoData(for: reloadedSecond) == secondBytes)
    }

    // MARK: - Content addressing

    @Test("A digest shared by two markups stores one blob, which survives until the last reference goes")
    func sharedDigestBlobSurvivesUntilLastReference() async throws {
        let workspace = try makeWorkspace("shared")
        let store = try PhotoStore(directory: workspace)
        let markupA = MarkupID(UUID())
        let markupB = MarkupID(UUID())
        let source = try makeImageData(width: 1000, height: 750)

        let onA = try await store.addPhoto(imageData: source, to: markupA)
        let onB = try await store.addPhoto(imageData: source, to: markupB)

        // Same pixels, same stored bytes, one blob on disk — attached twice, stored once.
        #expect(onA.digest == onB.digest)
        #expect(onA.id != onB.id)
        #expect(blobNames(in: workspace) == ["\(onA.digest).jpg"])
        #expect(await store.storedPhotoByteCount() == onA.byteCount)

        // Removing one markup's photo must not take the other markup's pixels with it.
        try await store.removeAttachment(onA.id)
        #expect(blobNames(in: workspace) == ["\(onB.digest).jpg"])
        #expect(try await store.photoData(for: onB).count == onB.byteCount)

        // The last reference goes; only now does the blob.
        try await store.removeAttachment(onB.id)
        #expect(blobNames(in: workspace).isEmpty)
        #expect(await store.allAttachments().isEmpty)
        #expect(await store.storedPhotoByteCount() == 0)
    }

    @Test("Removing a markup's photographs spares every digest another markup still references")
    func removingAMarkupsPhotosRespectsSharedDigests() async throws {
        let workspace = try makeWorkspace("markupremove")
        let store = try PhotoStore(directory: workspace)
        let markupA = MarkupID(UUID())
        let markupB = MarkupID(UUID())
        let shared = try makeImageData(width: 640, height: 480)
        let ownOnly = try makeImageData(width: 480, height: 640)

        _ = try await store.addPhoto(imageData: shared, to: markupA)
        _ = try await store.addPhoto(imageData: ownOnly, to: markupA)
        let onB = try await store.addPhoto(imageData: shared, to: markupB)
        #expect(blobNames(in: workspace).count == 2)

        let attachments = await store.allAttachments().filter { $0.markupID == markupA }
        #expect(attachments.count == 2)
        for attachment in attachments {
            try await store.removeAttachment(attachment.id)
        }
        #expect(await store.allAttachments().allSatisfy { $0.markupID != markupA })
        // The shared blob survives for markup B; markup A's own blob is gone.
        #expect(blobNames(in: workspace) == ["\(onB.digest).jpg"])
        #expect(try await store.photoData(for: onB).count == onB.byteCount)
    }

    // MARK: - Capture time

    @Test("The source's EXIF capture time is adopted when the caller supplies none")
    func exifCaptureTimeIsAdopted() async throws {
        let workspace = try makeWorkspace("exif")
        let store = try PhotoStore(directory: workspace)
        let source = try makeImageData(
            width: 320, height: 240, utType: .jpeg,
            exifDateTimeOriginal: "2026:05:14 09:30:00"
        )

        let attachment = try await store.addPhoto(imageData: source, to: MarkupID(UUID()))

        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 14
        components.hour = 9
        components.minute = 30
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(attachment.capturedAt == calendar.date(from: components))
    }

    // MARK: - Crash safety and hostile input

    @Test("An unreadable manifest is refused loudly, never opened as an empty store")
    func unreadableManifestRefusesToOpen() throws {
        let workspace = try makeWorkspace("badmanifest")
        _ = try PhotoStore(directory: workspace)  // lays out the directory
        let manifestURL = workspace.appendingPathComponent(PhotoStore.manifestFileName)
        try Data("not a manifest {".utf8).write(to: manifestURL)

        #expect {
            _ = try PhotoStore(directory: workspace)
        } throws: { error in
            guard case .manifestUnreadable = error as? PhotoStoreFailure else { return false }
            return true
        }
    }

    @Test("A crash leftover blob is unreferenced, never billed to the budget, and swept")
    func leftoverBlobIsSweptNotBilled() async throws {
        let workspace = try makeWorkspace("sweep")
        let store = try PhotoStore(directory: workspace)
        let kept = try await store.addPhoto(
            imageData: try makeImageData(width: 500, height: 400), to: MarkupID(UUID())
        )

        // What a kill between "blob written" and "manifest written" leaves behind:
        // a well-formed content-addressed file no attachment names.
        let strayBytes = Data("stranded by a simulated crash".utf8)
        let strayDigest = FileDurability.sha256(of: strayBytes)
        let blobsDirectory = workspace.appendingPathComponent(
            PhotoStore.blobsDirectoryName, isDirectory: true
        )
        try strayBytes.write(to: blobsDirectory.appendingPathComponent("\(strayDigest).jpg"))

        #expect(await store.unreferencedBlobDigests() == [strayDigest])
        #expect(await store.storedPhotoByteCount() == kept.byteCount)

        let swept = try await store.sweepUnreferencedBlobs()
        #expect(swept == 1)
        #expect(blobNames(in: workspace) == ["\(kept.digest).jpg"])
        #expect(try await store.photoData(for: kept).count == kept.byteCount)
    }

    @Test("A malformed digest is refused before it can become a file path")
    func malformedDigestIsRefused() async throws {
        let workspace = try makeWorkspace("digest")
        let store = try PhotoStore(directory: workspace)
        await #expect(throws: PhotoStoreFailure.malformedDigest("../../escape")) {
            _ = try await store.photoData(forDigest: "../../escape")
        }
    }
}
