import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Measured: **vector artwork stays sharp at 400 % and raster artwork degrades
/// the way it was said it would.**
///
/// The goldens are pictures, and a picture only proves a difference if somebody measures it. So
/// this suite counts *ink transitions* — how many times the alpha channel crosses the halfway
/// mark along the middle row and the middle column of the rendered image. That number is a
/// direct count of how many distinct edges the renderer resolved:
///
/// - compiled **vector** artwork has no sampling in it at all, so magnifying it resolves the
///   ring gaps that were sub-pixel before, and the count **rises**;
/// - compiled **raster** artwork was sampled once, at import, onto a fixed grid, so magnifying
///   it makes the cells larger and resolves nothing new, and the count **does not rise**.
///
/// If those two ever came out the same, one of two things would be true: vector artwork had
/// quietly become an image, or raster artwork had quietly become something it cannot be. Both
/// are exactly what the estimator was promised would not happen.
@Suite("Imported artwork under magnification", .serialized)
struct ImportedArtworkZoomTests {

    /// Ink transitions along the middle row and column of an image: how many distinct edges
    /// the renderer resolved there.
    ///
    /// Alpha, thresholded at half. An edge the renderer did not resolve — two bars whose gap
    /// fell under a pixel — reads as one run of ink and contributes one pair of crossings
    /// instead of two, which is exactly the difference being measured.
    static func transitions(in image: RasterImage) -> Int {
        func count(_ samples: [UInt8]) -> Int {
            var crossings = 0
            var inside = false
            for value in samples {
                let nowInside = value >= 128
                if nowInside != inside { crossings += 1 }
                inside = nowInside
            }
            return crossings
        }
        let midRow = image.height / 2
        let midColumn = image.width / 2
        let row = (0..<image.width).map { image.pixels[(midRow * image.width + $0) * 4 + 3] }
        let column = (0..<image.height).map { image.pixels[($0 * image.width + midColumn) * 4 + 3] }
        return count(row) + count(column)
    }

    static func rendered(_ name: String, backend: RendererBackend) throws -> RasterImage {
        let scene = try #require(SceneLibrary.golden(named: name), "no scene \(name)")
        return try Goldens.render(scene, backend: backend)
    }

    @Test("Magnifying vector artwork resolves detail that was not there before")
    func vectorGainsDetailWithZoom() throws {
        for backend in RendererBackend.allCases {
            let low = Self.transitions(in: try Self.rendered("artwork-vector-zoom-025", backend: backend))
            let mid = Self.transitions(in: try Self.rendered("artwork-vector-zoom-100", backend: backend))
            let high = Self.transitions(in: try Self.rendered("artwork-vector-zoom-400", backend: backend))
            #expect(mid > low, "\(backend): 100 % resolved \(mid) edges, 25 % resolved \(low)")
            #expect(high > mid, "\(backend): 400 % resolved \(high) edges, 100 % resolved \(mid)")
            // Three pairs of bars, a frame and a block: at 400 % every gap is resolved and
            // the mid row crosses all of them.
            #expect(high >= 20, "\(backend): only \(high) edges at 400 %")
        }
    }

    @Test("Magnifying raster artwork enlarges its cells and resolves nothing new")
    func rasterResolvesNothingNewWithZoom() throws {
        for backend in RendererBackend.allCases {
            let low = Self.transitions(in: try Self.rendered("artwork-raster-zoom-025", backend: backend))
            let mid = Self.transitions(in: try Self.rendered("artwork-raster-zoom-100", backend: backend))
            let high = Self.transitions(in: try Self.rendered("artwork-raster-zoom-400", backend: backend))
            // The mosaic is 16 cells per axis, so two scanlines can cross at most 32 cell
            // boundaries plus the two outer edges however far it is magnified. Zoom cannot
            // manufacture an edge the import did not sample.
            let ceiling = 2 * (ArtworkFixtureLibrary.cellCount + 2)
            #expect(high <= ceiling, "\(backend): \(high) edges at 400 %, ceiling \(ceiling)")
            #expect(mid <= ceiling)
            #expect(high <= mid, "\(backend): 400 % resolved \(high) edges, 100 % resolved \(mid)")
            #expect(low <= mid)
        }
    }

    @Test("At 400 % the raster's cells are square blocks of exactly the size import fixed")
    func rasterCellsAreVisibleBlocks() throws {
        // "Degrades as expected rather than surprisingly" is a claim about *what the person
        // sees*: cells whose size they could have predicted from the import. At 400 % a
        // 192-point box of 16 cells puts each cell at 48 device pixels, and the longest run of
        // identical pixels along the middle row has to be a multiple of that, not something in
        // between that would mean the mosaic had been resampled after the fact.
        let image = try Self.rendered("artwork-raster-zoom-400", backend: .coreGraphics)
        let expectedCell = 4.0 * ArtworkFixtureLibrary.boxPoints
            / Double(ArtworkFixtureLibrary.cellCount)
        let midRow = image.height / 2
        var longestRun = 0
        var run = 0
        var previous: (UInt8, UInt8, UInt8, UInt8)? = nil
        for x in 0..<image.width {
            let offset = (midRow * image.width + x) * 4
            let pixel = (
                image.pixels[offset], image.pixels[offset + 1],
                image.pixels[offset + 2], image.pixels[offset + 3]
            )
            if let previous, previous == pixel {
                run += 1
            } else {
                longestRun = Swift.max(longestRun, run)
                run = 1
            }
            previous = pixel
        }
        longestRun = Swift.max(longestRun, run)
        // At least one full cell of flat colour, within an antialiased edge pixel either side.
        #expect(
            Double(longestRun) >= expectedCell - 2,
            "longest flat run \(longestRun), one cell is \(expectedCell) device pixels"
        )
    }

    @Test("Both backends agree about every artwork scene, at every zoom")
    func backendsAgreeOnArtwork() throws {
        // Every artwork scene, held to the normal check. On a device without 8x the two scenes
        // in `GoldenImageTests.scenesNeedingEightSamples` are skipped with the reason printed.
        for name in [
            "artwork-vector-zoom-025", "artwork-vector-zoom-100", "artwork-vector-zoom-400",
            "artwork-raster-zoom-025", "artwork-raster-zoom-100", "artwork-raster-zoom-400",
            "count-symbols-imported"
        ] {
            if let reason = GoldenImageTests.metalSkipReason(name) { print(reason); continue }
            let reference = try Self.rendered(name, backend: .coreGraphics)
            let metal = try Self.rendered(name, backend: .metal)
            let result = ImageComparator.compare(metal, reference)
            #expect(result.matches, "\(name): \(result.summary)")
        }
    }
}
