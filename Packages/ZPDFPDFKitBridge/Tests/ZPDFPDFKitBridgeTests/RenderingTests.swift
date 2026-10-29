import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Rasterisation, the pixel budget, cancellation and the thumbnail cache.
@Suite("Rendering")
struct RenderingTests {

    @Test("A whole page renders at the requested scale")
    func rendersWholePage() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, scale: 0.5)
        )
        #expect(rendered.pixelWidth == 306)
        #expect(rendered.pixelHeight == 396)
        #expect(rendered.renderedRegion == CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(rendered.rotation == 0)
        #expect(rendered.scale == 0.5)
    }

    @Test("An exact pixel size is honoured, and it does not stretch the page")
    func exactPixelSize() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        // A region whose ceil would round up: 200.5 points at scale 1 is 201 pixels.
        let region = CGRect(x: 0, y: 0, width: 200.5, height: 200.5)
        let rounded = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, region: region, scale: 1)
        )
        #expect(rounded.pixelWidth == 201)

        // Pinned to 200, which is what a canvas blitting onto whole device pixels needs.
        let pinned = try await provider.renderPageRegion(
            PageRenderRequest(
                document: opened.handle,
                pageIndex: 0,
                box: .media,
                region: region,
                scale: 1,
                exactPixelSize: RenderPixelSize(width: 200, height: 200)
            )
        )
        #expect(pinned.pixelWidth == 200)
        #expect(pinned.pixelHeight == 200)
        #expect(pinned.scale == 1)

        // And the content is the same content, not the same content squeezed: every pixel of
        // the pinned image matches the corresponding pixel of the rounded one. A bitmap size is
        // a canvas size here, never a scale factor.
        #expect(Self.identicalTopLeft(pinned.image, rounded.image, width: 200, height: 200))
    }

    @Test("A pinned pixel size is still subject to the pixel budget")
    func exactPixelSizeIsNotAWaiver() async throws {
        let provider = PDFKitDocumentProvider()
        var limits = DocumentLimits.standard
        limits.maximumRenderPixels = 10_000
        let opened = try await provider.open(.url(Corpus.url(.rectangle)), password: nil, limits: limits)
        await #expect(throws: PDFBridgeError.pixelBudgetExceeded(requestedPixels: 1_000_000, limit: 10_000)) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(
                    document: opened.handle,
                    pageIndex: 0,
                    box: .media,
                    region: CGRect(x: 0, y: 0, width: 100, height: 100),
                    scale: 1,
                    exactPixelSize: RenderPixelSize(width: 1000, height: 1000)
                )
            )
        }
    }

    /// Whether the top-left `width x height` pixels of two images are byte-identical in grey.
    private static func identicalTopLeft(_ a: CGImage, _ b: CGImage, width: Int, height: Int) -> Bool {
        func grey(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return }
                // Both images share their bottom-left origin, which is where CGImage row order
                // starts, so drawing each at its own natural size compares the same corner.
                context.draw(
                    image,
                    in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
                )
            }
            return pixels
        }
        return grey(a) == grey(b)
    }

    @Test("A region is clamped to the box and reported as clamped")
    func clampsRegion() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(
                document: opened.handle,
                pageIndex: 0,
                box: .media,
                region: CGRect(x: -100, y: -100, width: 300, height: 300),
                scale: 1
            )
        )
        #expect(rendered.renderedRegion == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(rendered.pixelWidth == 200)
        #expect(rendered.pixelHeight == 200)
    }

    @Test("A region entirely outside the page is an error, not an empty image")
    func regionOutsidePage() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        await #expect(throws: PDFBridgeError.emptyRenderRegion) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(
                    document: opened.handle,
                    pageIndex: 0,
                    region: CGRect(x: 10_000, y: 10_000, width: 10, height: 10),
                    scale: 1
                )
            )
        }
    }

    @Test("A crop box with a negative origin renders the crop, not the media box")
    func negativeOriginCropBox() async throws {
        let manifest = try Corpus.manifest(.cropBoxNegativeOrigin)
        let crop = manifest.pages[0].cropBox
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.cropBoxNegativeOrigin))
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, box: .crop, scale: 1)
        )
        #expect(rendered.pixelWidth == Int(crop.width))
        #expect(rendered.pixelHeight == Int(crop.height))
        // Compared as `Double` on both sides: mixing `CGFloat` and `Double` inside an
        // `#expect` macro does not go through the implicit numeric conversion.
        #expect(Double(rendered.renderedRegion.minX) == crop.llx)
        #expect(Double(rendered.renderedRegion.minY) == crop.lly)
    }

    @Test("A rotated page renders transposed, and the rotation is reported")
    func rotatedPage() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rotation90))
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, scale: 0.25)
        )
        #expect(rendered.rotation == 90)
        #expect(rendered.pixelWidth == 198)
        #expect(rendered.pixelHeight == 153)
    }

    @Test("The page-space to display-space mapping is exact for all four rotations")
    func displayGeometry() {
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let rect = CGRect(x: 68, y: 76, width: 100, height: 600)
        #expect(PageDisplayGeometry.displayRect(forPageRect: rect, box: box, rotation: 0) == rect)
        #expect(
            PageDisplayGeometry.displayRect(forPageRect: rect, box: box, rotation: 90)
                == CGRect(x: 76, y: 612 - 168, width: 600, height: 100)
        )
        #expect(
            PageDisplayGeometry.displayRect(forPageRect: rect, box: box, rotation: 180)
                == CGRect(x: 612 - 168, y: 792 - 676, width: 100, height: 600)
        )
        #expect(
            PageDisplayGeometry.displayRect(forPageRect: rect, box: box, rotation: 270)
                == CGRect(x: 792 - 676, y: 68, width: 600, height: 100)
        )
        #expect(PageDisplayGeometry.displaySize(of: box.size, rotation: 270) == CGSize(width: 792, height: 612))
        #expect(PageDisplayGeometry.displaySize(of: box.size, rotation: 180) == box.size)
    }

    @Test("A render bigger than the pixel budget is refused before anything is allocated")
    func pixelBudget() async throws {
        var limits = DocumentLimits.standard
        limits.maximumRenderPixels = 10_000
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.sizeArchD)), password: nil, limits: limits
        )
        await #expect(throws: PDFBridgeError.self) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(document: opened.handle, pageIndex: 0, scale: 4)
            )
        }
        // An ARCH-D sheet at 96 megapixels would be a 384 MB bitmap under the default
        // budget too, so the default rejects it as well.
        let standard = PDFKitDocumentProvider()
        let big = try await standard.open(fileAt: Corpus.url(.sizeArchD))
        await #expect(throws: PDFBridgeError.self) {
            _ = try await standard.renderPageRegion(
                PageRenderRequest(document: big.handle, pageIndex: 0, scale: 8)
            )
        }
    }

    @Test("A scale that is zero, negative or not finite is refused")
    func invalidScale() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        for scale in [0.0, -1.0, Double.infinity, Double.nan] {
            await #expect(throws: PDFBridgeError.self) {
                _ = try await provider.renderPageRegion(
                    PageRenderRequest(document: opened.handle, pageIndex: 0, scale: CGFloat(scale))
                )
            }
        }
    }

    @Test("A cancelled render throws cancelled rather than finishing")
    func cancellation() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.sizeArchD))
        let handle = opened.handle
        let task = Task {
            try await provider.renderPageRegion(
                PageRenderRequest(document: handle, pageIndex: 0, scale: 2)
            )
        }
        task.cancel()
        await #expect(throws: PDFBridgeError.cancelled) { try await task.value }
    }

    // MARK: - Thumbnails

    @Test("A thumbnail fits inside the requested box and preserves aspect ratio")
    func thumbnailFits() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.sizeArchD))
        let result = try await provider.thumbnail(
            ThumbnailRequest(document: opened.handle, pageIndex: 0, maximumPixelSize: 256)
        )
        #expect(max(result.image.width, result.image.height) == 256)
        // 1728 x 2592 is 2:3.
        #expect(result.image.width == 171)
        #expect(result.image.height == 256)
        #expect(result.wasCacheHit == false)
    }

    @Test("The second request for the same thumbnail is a cache hit")
    func thumbnailCacheHitAndMiss() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.mixedPageSizes))
        let request = ThumbnailRequest(document: opened.handle, pageIndex: 0, maximumPixelSize: 64)

        let first = try await provider.thumbnail(request)
        #expect(first.wasCacheHit == false)
        let second = try await provider.thumbnail(request)
        #expect(second.wasCacheHit)
        #expect(second.image === first.image)

        var statistics = await provider.thumbnailCacheStatistics()
        #expect(statistics.hits == 1)
        #expect(statistics.misses == 1)
        #expect(statistics.count == 1)

        // A different page, and a different size of the same page, both miss.
        _ = try await provider.thumbnail(
            ThumbnailRequest(document: opened.handle, pageIndex: 1, maximumPixelSize: 64)
        )
        _ = try await provider.thumbnail(
            ThumbnailRequest(document: opened.handle, pageIndex: 0, maximumPixelSize: 128)
        )
        statistics = await provider.thumbnailCacheStatistics()
        #expect(statistics.misses == 3)
        #expect(statistics.count == 3)
    }

    @Test("The cache is keyed by content, so two copies of a file share one entry")
    func cacheKeyedByContent() async throws {
        let scratch = try Corpus.scratchDirectory("cache-key")
        let copy = scratch.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: Corpus.url(.rectangle), to: copy)

        let provider = PDFKitDocumentProvider()
        let original = try await provider.open(fileAt: Corpus.url(.rectangle))
        let duplicate = try await provider.open(fileAt: copy)
        #expect(original.descriptor.digest == duplicate.descriptor.digest)

        _ = try await provider.thumbnail(
            ThumbnailRequest(document: original.handle, pageIndex: 0, maximumPixelSize: 48)
        )
        let second = try await provider.thumbnail(
            ThumbnailRequest(document: duplicate.handle, pageIndex: 0, maximumPixelSize: 48)
        )
        #expect(second.wasCacheHit)
    }

    @Test("Closing a document drops its thumbnails, and clearing drops everything")
    func cacheEviction() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(.rectangle))
        let request = ThumbnailRequest(document: opened.handle, pageIndex: 0, maximumPixelSize: 32)
        _ = try await provider.thumbnail(request)
        #expect(await provider.thumbnailCacheStatistics().count == 1)
        await provider.close(opened.handle)
        #expect(await provider.thumbnailCacheStatistics().count == 0)

        let reopened = try await provider.open(fileAt: Corpus.url(.rectangle))
        _ = try await provider.thumbnail(
            ThumbnailRequest(document: reopened.handle, pageIndex: 0, maximumPixelSize: 32)
        )
        await provider.clearThumbnailCache()
        #expect(await provider.thumbnailCacheStatistics().count == 0)
    }

    @Test("The thumbnail edge is clamped by the limits")
    func thumbnailEdgeClamped() async throws {
        var limits = DocumentLimits.standard
        limits.maximumThumbnailEdge = 40
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(
            .url(Corpus.url(.rectangle)), password: nil, limits: limits
        )
        let result = try await provider.thumbnail(
            ThumbnailRequest(document: opened.handle, pageIndex: 0, maximumPixelSize: 4096)
        )
        #expect(max(result.image.width, result.image.height) == 40)
    }
}

/// The LRU cache on its own, without PDFKit.
@Suite("Thumbnail cache")
struct ThumbnailCacheTests {

    func image(_ side: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        )
        return try #require(context.makeImage())
    }

    func key(_ page: Int, sha: String = "a", size: Int = 16) -> ThumbnailCache.Key {
        ThumbnailCache.Key(
            documentSHA256: sha, pageIndex: page, box: .crop, pixelWidth: size, pixelHeight: size
        )
    }

    @Test("A miss then a hit, counted")
    func hitAndMiss() throws {
        var cache = ThumbnailCache(capacity: 4)
        #expect(cache.value(for: key(0)) == nil)
        cache.insert(try image(4), for: key(0))
        #expect(cache.value(for: key(0)) != nil)
        #expect(cache.statistics.hits == 1)
        #expect(cache.statistics.misses == 1)
    }

    @Test("The least recently used entry is the one evicted")
    func eviction() throws {
        var cache = ThumbnailCache(capacity: 2)
        cache.insert(try image(4), for: key(0))
        cache.insert(try image(4), for: key(1))
        // Touching 0 makes 1 the least recently used.
        #expect(cache.value(for: key(0)) != nil)
        cache.insert(try image(4), for: key(2))
        #expect(cache.count == 2)
        #expect(cache.value(for: key(0)) != nil)
        #expect(cache.value(for: key(1)) == nil)
        #expect(cache.value(for: key(2)) != nil)
        #expect(cache.statistics.evictions == 1)
    }

    @Test("Keys differ by document, page, box and pixel size")
    func keyIdentity() throws {
        var cache = ThumbnailCache(capacity: 8)
        cache.insert(try image(4), for: key(0))
        #expect(cache.value(for: key(0, sha: "b")) == nil)
        #expect(cache.value(for: key(1)) == nil)
        #expect(cache.value(for: key(0, size: 32)) == nil)
        var otherBox = key(0)
        otherBox = ThumbnailCache.Key(
            documentSHA256: otherBox.documentSHA256, pageIndex: 0, box: .media,
            pixelWidth: otherBox.pixelWidth, pixelHeight: otherBox.pixelHeight
        )
        #expect(cache.value(for: otherBox) == nil)
    }

    @Test("A zero capacity cache never retains anything and always misses")
    func zeroCapacity() throws {
        var cache = ThumbnailCache(capacity: 0)
        cache.insert(try image(4), for: key(0))
        #expect(cache.count == 0)
        #expect(cache.value(for: key(0)) == nil)
    }

    @Test("Dropping one document's entries leaves the others")
    func removeByDocument() throws {
        var cache = ThumbnailCache(capacity: 8)
        cache.insert(try image(4), for: key(0, sha: "a"))
        cache.insert(try image(4), for: key(0, sha: "b"))
        cache.removeAll(forDocumentSHA256: "a")
        #expect(cache.count == 1)
        #expect(cache.value(for: key(0, sha: "b")) != nil)
    }

    @Test("The cache is bounded by bytes, not only by count (CR-83)")
    func byteBudgetEvicts() throws {
        // A generous count cap of 100 but a byte budget for only about three images. A
        // count-only cache would keep all ten; the byte budget must evict down to ~three.
        // Old output: count == 10, resident bytes ≈ ten images.
        let perImageBytes = ThumbnailCache.byteCount(of: try image(32))
        var cache = ThumbnailCache(capacity: 100, byteCapacity: perImageBytes * 3)
        for page in 0..<10 { cache.insert(try image(32), for: key(page)) }
        #expect(cache.count <= 3, "byte budget did not evict: \(cache.count) entries retained")
        #expect(cache.count >= 1)
        #expect(cache.residentByteCount <= perImageBytes * 3)
        #expect(cache.statistics.evictions >= 7)
        // The most recently inserted survive; the oldest are gone.
        #expect(cache.value(for: key(9)) != nil)
        #expect(cache.value(for: key(0)) == nil)
    }

    @Test("A single image larger than the whole byte budget is not cached (CR-83)")
    func oversizeImageNotCached() throws {
        let big = try image(64)
        let bytes = ThumbnailCache.byteCount(of: big)
        var cache = ThumbnailCache(capacity: 10, byteCapacity: bytes / 2)
        cache.insert(big, for: key(0))
        #expect(cache.count == 0)
        #expect(cache.value(for: key(0)) == nil)
    }
}
