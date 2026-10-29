import CoreGraphics
import Foundation
import os
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Regression tests for the provider findings of bug hunt 2.
@Suite("Fix 2 — provider", .serialized)
struct Fix2ProviderTests {

    /// A private copy of a corpus fixture, so a per-URL observation cannot see another test.
    private func privateCopy(_ kind: FixtureKind, label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-fix2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(label).pdf")
        try FileManager.default.copyItem(at: Corpus.url(kind), to: url)
        return url
    }

    // MARK: - IM-005

    @Test("IM-005: a digest verified by the caller is not hashed again on open")
    func knownDigestSkipsTheHash() async throws {
        let url = try privateCopy(.titleBlockSheet, label: "working")
        let path = url.standardizedFileURL.path
        let hashes = OSAllocatedUnfairLock(initialState: 0)
        FileDigestReader.fileDigestObserver.withLock { observer in
            observer = { observed in
                if observed.standardizedFileURL.path == path { hashes.withLock { $0 += 1 } }
            }
        }
        defer { FileDigestReader.fileDigestObserver.withLock { $0 = nil } }

        let provider = PDFKitDocumentProvider()
        // Today's behaviour, and still the default: the open hashes the file itself.
        let first = try await provider.open(.url(url), password: nil, limits: .standard)
        #expect(hashes.withLock { $0 } == 1)

        // The caller verified the same file already: this open reads no byte of it to hash.
        let second = try await provider.open(
            .url(url), password: nil, limits: .standard, knownDigest: first.descriptor.digest
        )
        #expect(hashes.withLock { $0 } == 1)
        #expect(second.descriptor.digest == first.descriptor.digest)

        // A digest that cannot describe this file (wrong size) is ignored, and the file hashed.
        let wrong = FileDigest(sha256: first.descriptor.digest.sha256, byteCount: 1)
        let third = try await provider.open(.url(url), password: nil, limits: .standard, knownDigest: wrong)
        #expect(hashes.withLock { $0 } == 2)
        #expect(third.descriptor.digest == first.descriptor.digest)
        // So is a malformed one.
        let malformed = FileDigest(sha256: "not-a-digest", byteCount: first.descriptor.digest.byteCount)
        _ = try await provider.open(.url(url), password: nil, limits: .standard, knownDigest: malformed)
        #expect(hashes.withLock { $0 } == 3)
        await provider.closeAll()
    }

    // MARK: - BH-171

    @Test("BH-171: an unspecified bookmark coordinate or zoom is nil, not FLT_MAX")
    func unspecifiedOutlineDestination() async throws {
        let url = try HandBuiltPDF.pages(
            1,
            catalogExtra: "/Outlines 4 0 R",
            additional: [
                "<< /Type /Outlines /First 5 0 R /Last 7 0 R /Count 3 >>",
                "<< /Title (Fit) /Parent 4 0 R /Next 6 0 R /Dest [3 0 R /Fit] >>",
                "<< /Title (Null) /Parent 4 0 R /Prev 5 0 R /Next 7 0 R /Dest [3 0 R /XYZ null null null] >>",
                "<< /Title (Real) /Parent 4 0 R /Prev 6 0 R /Dest [3 0 R /XYZ 100 150 2] >>"
            ],
            label: "unspecified-outline"
        )
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let outline = try await provider.outline(of: opened.handle)
        let byLabel = Dictionary(uniqueKeysWithValues: outline.flattened.map { ($0.label, $0) })
        // Old code: point (3.40282e+38, 3.40282e+38) and zoom 3.40282e+38 for both.
        for title in ["Fit", "Null"] {
            let target = try #require(byLabel[title]?.destination)
            #expect(target.pageIndex == 0)
            #expect(target.point == nil, "\(title): \(String(describing: target.point))")
            #expect(target.zoom == nil, "\(title): \(String(describing: target.zoom))")
        }
        let real = try #require(byLabel["Real"]?.destination)
        #expect(real.point == CGPoint(x: 100, y: 150))
        #expect(real.zoom == 2)
        #expect(PDFKitDocumentProvider.specified(CGFloat(kPDFDestinationUnspecifiedValue)) == nil)
        #expect(PDFKitDocumentProvider.specified(.infinity) == nil)
        #expect(PDFKitDocumentProvider.specified(612) == 612)
        await provider.close(opened.handle)
    }

    // MARK: - BH-575 / BH-585

    @Test("BH-575/BH-585: a destination past the last page is reported unresolved")
    func outOfRangeDestinationIsUnresolved() async throws {
        let url = try HandBuiltPDF.pages(
            3,
            catalogExtra: "/Dests << /PAST [12 /XYZ 0 0 0] /REAL [4 0 R /XYZ 10 20 0] >>",
            label: "past-last-page"
        )
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let destinations = try await provider.namedDestinations(of: opened.handle)
        let past = try #require(destinations.first { $0.name == "PAST" })
        // Old code: pageIndex 12, isResolved true, pageLabel nil.
        #expect(past.target.pageIndex == nil)
        #expect(past.target.isResolved == false)
        #expect(past.target.pageLabel == nil)
        let real = try #require(destinations.first { $0.name == "REAL" })
        #expect(real.target.pageIndex == 1)
        #expect(real.target.pageLabel == "2")
        await provider.close(opened.handle)
    }

    // MARK: - BH-586

    @Test("BH-586: /XYZ null 612 keeps the horizontal axis absent instead of 0")
    func nullAxisIsAbsent() async throws {
        let url = try HandBuiltPDF.pages(
            1,
            catalogExtra: "/Dests << /TOP [3 0 R /XYZ null 612 0] /FITH [3 0 R /FitH 500] /BOTH [3 0 R /XYZ 5 6 0] >>",
            label: "null-axis"
        )
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let destinations = try await provider.namedDestinations(of: opened.handle)
        let top = try #require(destinations.first { $0.name == "TOP" }?.target)
        // Old code: only `point`, (0, 612) — a jump to the sheet's left edge.
        #expect(top.left == nil)
        #expect(top.top == 612)
        let fitH = try #require(destinations.first { $0.name == "FITH" }?.target)
        #expect(fitH.left == nil)
        #expect(fitH.top == 500)
        let both = try #require(destinations.first { $0.name == "BOTH" }?.target)
        #expect(both.left == 5 && both.top == 6)
        #expect(both.point == CGPoint(x: 5, y: 6))
        await provider.close(opened.handle)
    }

    @Test("BH-586: destinations encoded before left/top existed still decode")
    func oldDestinationBytesDecode() throws {
        // Bytes as the synthesised Codable wrote them: CGPoint encodes as [x, y].
        let json = #"{"pageIndex":3,"pageLabel":"A-102","point":[100,200],"zoom":2}"#
        let decoded = try JSONDecoder().decode(DestinationTarget.self, from: Data(json.utf8))
        #expect(decoded == DestinationTarget(
            pageIndex: 3, pageLabel: "A-102", point: CGPoint(x: 100, y: 200), zoom: 2
        ))
        #expect(decoded.left == 100 && decoded.top == 200)
        let unresolved = try JSONDecoder().decode(DestinationTarget.self, from: Data("{}".utf8))
        #expect(unresolved.pageIndex == nil && unresolved.point == nil && unresolved.left == nil)
        let oneAxis = DestinationTarget(pageIndex: 0, pageLabel: nil, left: nil, top: 612, zoom: nil)
        let roundTrip = try JSONDecoder().decode(
            DestinationTarget.self, from: try JSONEncoder().encode(oneAxis)
        )
        #expect(roundTrip == oneAxis)
        #expect(roundTrip.left == nil)
    }

    // MARK: - BH-576 / BH-577 / BH-578

    /// A two-page encrypted set: labelled `A-101`, `A-102`, one named destination on page 1, and
    /// page 1's media box has no area.
    private func encryptedLabelledSet() throws -> URL {
        try HandBuiltPDF.writeEncrypted(
            [
                "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /P «A-» /St 101 >>] >> /Names << /Dests << /Names [«SHEET» [4 0 R /XYZ 10 20 0]] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 0 0] >>"
            ],
            userPassword: "letmein",
            label: "encrypted-labelled"
        )
    }

    @Test("BH-577/BH-578: a late unlock labels named destinations exactly as an early one")
    func lateUnlockMatchesEarlyUnlock() async throws {
        let url = try encryptedLabelledSet()
        let provider = PDFKitDocumentProvider()

        let early = try await provider.open(fileAt: url, password: "letmein")
        let earlyDestinations = try await provider.namedDestinations(of: early.handle)
        let earlySheet = try #require(earlyDestinations.first { $0.name == "SHEET" })
        #expect(earlySheet.target.pageIndex == 1)
        #expect(earlySheet.target.pageLabel == "A-102")

        let late = try await provider.open(fileAt: url)
        #expect(late.descriptor.encryption == .locked)
        _ = try await provider.unlock(late.handle, password: "letmein")
        let lateDestinations = try await provider.namedDestinations(of: late.handle)
        // Old code: the raw CatalogInspector destination — pageLabel nil.
        #expect(lateDestinations == earlyDestinations)
        await provider.closeAll()
    }

    @Test("BH-576: unlock recomputes the integrity verdict the locked open could not take")
    func unlockRecomputesIntegrity() async throws {
        let url = try encryptedLabelledSet()
        let provider = PDFKitDocumentProvider()
        let early = try await provider.open(fileAt: url, password: "letmein")
        let late = try await provider.open(fileAt: url)
        #expect(late.descriptor.encryption == .locked)
        let unlocked = try await provider.unlock(late.handle, password: "letmein")
        // Old code: `.intact`, copied from the locked open that skipped the page-box sampling.
        #expect(unlocked.integrity == early.descriptor.integrity)
        #expect(unlocked.integrity != .intact)
        await provider.closeAll()
    }

    // MARK: - BH-172 / BH-572

    @Test("BH-172: an absurd /MediaBox throws a pixel-budget error instead of trapping")
    func absurdMediaBoxDoesNotTrap() async throws {
        let url = try HandBuiltPDF.pages(1, mediaBox: "[0 0 99999999999999999999999 792]", label: "absurd-box")
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        // Old code: `Int((1e23 * 1).rounded(.up))` — a Swift runtime trap, the process dies.
        await #expect(throws: PDFBridgeError.self) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, scale: 1)
            )
        }
        // The thumbnail path fits the box into its edge and still produces an image.
        let thumbnail = try await provider.thumbnail(
            ThumbnailRequest(document: opened.handle, pageIndex: 0, box: .media, maximumPixelSize: 64)
        )
        #expect(thumbnail.image.width <= 64 && thumbnail.image.height >= 1)
        await provider.close(opened.handle)
    }

    @Test("BH-172/BH-572: pixel conversion refuses NaN, infinity and out-of-range values")
    func pixelDimensionGuards() {
        // Old code converted these with Int(_:), which traps for every one of them.
        #expect(PDFKitDocumentProvider.pixelDimension(.nan) == nil)
        #expect(PDFKitDocumentProvider.pixelDimension(.infinity) == nil)
        #expect(PDFKitDocumentProvider.pixelDimension(CGFloat(1e23)) == nil)
        #expect(PDFKitDocumentProvider.pixelDimension(-1) == nil)
        #expect(PDFKitDocumentProvider.pixelDimension(2048) == 2048)
        // The exact expression the thumbnail path evaluated for an infinite box: inf * 0.
        let fit = min(CGFloat(2048) / .infinity, CGFloat(2048) / 792)
        #expect(PDFKitDocumentProvider.pixelDimension((CGFloat.infinity * fit).rounded()) == nil)
    }

    // MARK: - BH-173 / BH-180 / BH-181

    private func layeredAnnotationFixture() throws -> URL {
        let appearance = HandBuiltPDF.stream(
            "1 0 0 rg 0 0 180 180 re f",
            extra: "/Type /XObject /Subtype /Form /BBox [0 0 180 180]"
        )
        return try HandBuiltPDF.onePage(
            content: "0 0 0 RG 1 w 5 5 m 195 195 l S",
            mediaBox: "[0 0 200 200]",
            pageExtra: "/Annots [5 0 R]",
            catalogExtra: "/OCProperties << /OCGs [7 0 R] /D << /Order [7 0 R] >> >>",
            additional: [
                "<< /Type /Annot /Subtype /Square /Rect [10 10 190 190] /C [1 0 0] /IC [1 0 0] /F 4 /OC 7 0 R /AP << /N 6 0 R >> >>",
                appearance,
                "<< /Type /OCG /Name (Walls) >>"
            ],
            label: "layered-annotation"
        )
    }

    @Test("BH-173/BH-180/BH-181: a layer toggle is never answered from a stale thumbnail")
    func layerToggleInvalidatesThumbnails() async throws {
        let url = try layeredAnnotationFixture()
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let other = try await provider.open(fileAt: url)
        let request = ThumbnailRequest(document: opened.handle, pageIndex: 0, maximumPixelSize: 64)
        let shown = try await provider.thumbnail(request)
        #expect(shown.key.displayState.isEmpty)

        let bindings = try await provider.annotationLayerBindings(of: opened.handle)
        #expect(bindings.count == 1)
        let changed = try await provider.applyAnnotationLayerVisibility(
            of: opened.handle, bindings: bindings, hiddenLayerIDs: [PDFLayerID(rawValue: "ocg:0")]
        )
        #expect(changed == 1)

        let hidden = try await provider.thumbnail(request)
        // Old code: wasCacheHit == true — the image with the hidden square still drawn.
        #expect(hidden.wasCacheHit == false)
        #expect(!hidden.key.displayState.isEmpty)
        #expect(Self.pixels(of: hidden.image) != Self.pixels(of: shown.image))

        // The second handle on the same file still shows the layer, so it must not be served
        // the first handle's hidden-layer image (old code: shared key, shared image).
        let otherThumbnail = try await provider.thumbnail(
            ThumbnailRequest(document: other.handle, pageIndex: 0, maximumPixelSize: 64)
        )
        #expect(Self.pixels(of: otherThumbnail.image) == Self.pixels(of: shown.image))

        // Showing the layer again returns to the file's own state and its cached image.
        _ = try await provider.applyAnnotationLayerVisibility(
            of: opened.handle, bindings: bindings, hiddenLayerIDs: []
        )
        let restored = try await provider.thumbnail(request)
        #expect(restored.key.displayState.isEmpty)
        #expect(Self.pixels(of: restored.image) == Self.pixels(of: shown.image))
        await provider.closeAll()
    }

    @Test("BH-173: thumbnail keys encoded before displayState existed still decode")
    func oldThumbnailKeyBytesDecode() throws {
        let json = #"{"documentSHA256":"abc","pageIndex":2,"box":"crop","pixelWidth":64,"pixelHeight":48}"#
        let decoded = try JSONDecoder().decode(ThumbnailCache.Key.self, from: Data(json.utf8))
        #expect(decoded == ThumbnailCache.Key(
            documentSHA256: "abc", pageIndex: 2, box: .crop, pixelWidth: 64, pixelHeight: 48
        ))
        #expect(decoded.displayState.isEmpty)
    }

    static func pixels(of image: CGImage) -> Data {
        (image.dataProvider?.data as Data?) ?? Data()
    }

    // MARK: - BH-174

    @Test("BH-174: a source rewritten since the open is refused before anything is written")
    func sourceChangedSinceOpenIsRefused() async throws {
        let url = try privateCopy(.titleBlockSheet, label: "revision-a")
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        // A sync client replaces the drawing in place with another revision.
        try Data(contentsOf: Corpus.url(.rectangle)).write(to: url, options: .atomic)

        let destination = DocumentDestination(
            url: url.deletingLastPathComponent().appendingPathComponent("export.pdf")
        )
        let note = NeutralAnnotation(
            pageIndex: 0, kind: .text, bounds: CGRect(x: 10, y: 10, width: 20, height: 20), contents: "A-101"
        )
        // Old code: the markups were written onto revision B and the receipt reported the
        // source untouched (before == after, both hashed at write time).
        await #expect(throws: PDFBridgeError.sourceMutatedDuringWrite(path: url.path)) {
            _ = try await provider.writeAnnotations(
                AnnotationWriteRequest(annotations: [note]), of: opened.handle, to: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.url.path))
        await provider.closeAll()
    }

    // MARK: - BH-574

    @Test("BH-574: an export larger than the source limit gets its receipt")
    func oversizedExportGetsReceipt() async throws {
        let url = try privateCopy(.titleBlockSheet, label: "limit-sized")
        let size = try FileDigestReader.fileByteCount(at: url)
        let provider = PDFKitDocumentProvider()
        // The source is exactly at the limit; any annotation makes the export larger than it.
        let opened = try await provider.open(
            .url(url), password: nil, limits: DocumentLimits(maximumFileByteCount: size)
        )
        let notes = (0..<50).map { index in
            NeutralAnnotation(
                pageIndex: 0, kind: .text,
                bounds: CGRect(x: 10 + index, y: 10, width: 20, height: 20),
                contents: String(repeating: "Wall type A, check dimension. ", count: 20)
            )
        }
        let destination = DocumentDestination(
            url: url.deletingLastPathComponent().appendingPathComponent("bigger.pdf")
        )
        // Old code: fileTooLarge thrown from the destination digest, after the file was placed.
        let receipt = try await provider.writeAnnotations(
            AnnotationWriteRequest(annotations: notes), of: opened.handle, to: destination
        )
        #expect(receipt.digest.byteCount > size)
        #expect(receipt.digest.byteCount == (try FileDigestReader.fileByteCount(at: destination.url)))
        await provider.closeAll()
    }

    // MARK: - IM-073

    @Test("IM-073: a drawing opened again is answered from the disk tier, not re-rendered")
    func thumbnailDiskTierServesSecondOpen() async throws {
        // Forty sheets sharing one dense content stream (20 000 stroked segments), so a render
        // costs what a real drawing's does and the measurement below means something.
        var linework = "0 0 0 RG 0.2 w\n"
        for index in 0..<20_000 {
            let x = Double(index % 600) + 6, y = Double(index / 600) * 22 + 10
            linework += "\(x) \(y) m \(x + 5) \(y + 18) l S\n"
        }
        let kids = (0..<40).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        var bodies = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count 40 >>"
        ]
        for _ in 0..<40 {
            bodies.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 43 0 R >>")
        }
        bodies.append(HandBuiltPDF.stream(linework))
        let url = try HandBuiltPDF.write(bodies, label: "set-of-forty")
        let root = url.deletingLastPathComponent().appendingPathComponent("Thumbnails", isDirectory: true)
        let disk = ThumbnailDiskCache(directory: root)

        func thumbnails(_ provider: PDFKitDocumentProvider) async throws -> (Duration, [ThumbnailResult]) {
            let opened = try await provider.open(fileAt: url)
            let clock = ContinuousClock()
            var results: [ThumbnailResult] = []
            let elapsed = try await clock.measure {
                for page in 0..<40 {
                    results.append(try await provider.thumbnail(
                        ThumbnailRequest(document: opened.handle, pageIndex: page, maximumPixelSize: 256)
                    ))
                }
            }
            await provider.waitForThumbnailDiskWrites()
            await provider.close(opened.handle)
            return (elapsed, results)
        }

        // First session: every thumbnail is rendered through PDFKit and written behind.
        let first = PDFKitDocumentProvider(thumbnailDiskCache: disk)
        let (firstTime, firstResults) = try await thumbnails(first)
        #expect(await first.thumbnailRenderCount == 40)
        #expect(firstResults.allSatisfy { !$0.wasCacheHit })

        // Second session, fresh memory cache: nothing is rendered.
        let second = PDFKitDocumentProvider(thumbnailDiskCache: disk)
        let (secondTime, secondResults) = try await thumbnails(second)
        #expect(await second.thumbnailRenderCount == 0)
        #expect(await second.thumbnailDiskHitCount == 40)
        #expect(secondResults.allSatisfy { $0.wasCacheHit })
        #expect(zip(firstResults, secondResults).allSatisfy {
            $0.image.width == $1.image.width && $0.image.height == $1.image.height
        })
        print("[IM-073] 40 thumbnails: rendered \(firstTime), from disk \(secondTime)")

        // One byte changed: a different digest, so nothing stale is served.
        var bytes = try Data(contentsOf: url)
        bytes.append(contentsOf: Array("% changed\n".utf8))
        try bytes.write(to: url, options: .atomic)
        let third = PDFKitDocumentProvider(thumbnailDiskCache: disk)
        _ = try await thumbnails(third)
        #expect(await third.thumbnailRenderCount == 40)
    }

    @Test("IM-073: the disk tier is trimmed to its byte cap, and a corrupt entry is discarded")
    func thumbnailDiskTierIsBounded() async throws {
        let url = try HandBuiltPDF.pages(12, mediaBox: "[0 0 612 792]", label: "bounded")
        let root = url.deletingLastPathComponent().appendingPathComponent("Thumbnails", isDirectory: true)
        let provider = PDFKitDocumentProvider(thumbnailDiskCache: ThumbnailDiskCache(directory: root))
        let opened = try await provider.open(fileAt: url)
        var keys: [ThumbnailCache.Key] = []
        for page in 0..<12 {
            keys.append(try await provider.thumbnail(
                ThumbnailRequest(document: opened.handle, pageIndex: page, maximumPixelSize: 128)
            ).key)
        }
        await provider.waitForThumbnailDiskWrites()
        let full = ThumbnailDiskCache(directory: root)
        let sizes = keys.compactMap { full.fileURL(for: $0) }.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        #expect(sizes.count == 12)
        let total = sizes.reduce(0, +)

        let capped = ThumbnailDiskCache(directory: root, byteCapacity: total / 2)
        #expect(capped.trim() > 0)
        let remaining = keys.compactMap { capped.fileURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        #expect(remaining.reduce(0, +) <= total / 2)

        // A file that does not decode to its key's size is input, not a thumbnail.
        let survivor = try #require(keys.first { full.fileURL(for: $0).map { FileManager.default.fileExists(atPath: $0.path) } == true })
        let survivorURL = try #require(full.fileURL(for: survivor))
        try Data("not a png".utf8).write(to: survivorURL)
        #expect(full.load(survivor) == nil)
        #expect(!FileManager.default.fileExists(atPath: survivorURL.path))
        // View-state keys never reach the disk.
        let viewState = ThumbnailCache.Key(
            documentSHA256: survivor.documentSHA256, pageIndex: 0, box: .crop,
            pixelWidth: 10, pixelHeight: 10, displayState: "hidden"
        )
        #expect(full.fileURL(for: viewState) == nil)
        await provider.closeAll()
    }
}
