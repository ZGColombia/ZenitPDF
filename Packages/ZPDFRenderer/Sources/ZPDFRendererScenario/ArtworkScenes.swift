import Foundation
import ZPDFContracts
import ZPDFRenderer

/// Deterministic imported-artwork fixtures, and the scenes that render them at three zooms.
///
/// # Why three zooms, and why these two pictures
///
/// The claim under test is a *difference between two kinds of artwork*, so a fixture that only
/// showed one of them would prove nothing. Both pictures are built from the same motif:
///
/// - ``vectorSeal()`` is what an imported PDF page compiles to — contours in a unit box. Its
///   three pairs of bars are separated by 0.002, 0.008 and 0.032 of the box, so one pair is
///   resolved at 25 %, two at 100 % and all three at 400 %: detail that magnification
///   *recovers*, because the geometry was never sampled in the first place.
/// - ``rasterSeal()`` is what an imported image compiles to — a mosaic of `cellCount` cells per
///   axis. Magnifying it makes the cells bigger and adds nothing, because the sampling already
///   happened, at import, at a resolution the estimator was told about.
///
/// Rendering both at 25 %, 100 % and 400 % is what turns "vector stays sharp" from a sentence
/// into a measurement: `ImportedArtworkZoomTests` counts the ink transitions across the middle
/// of each image and asserts that the vector count rises with zoom and the raster count does not.
public enum ArtworkFixtureLibrary {

    /// Cells per axis in the raster mosaic. Fixed here so the tests can assert against it.
    public static let cellCount = 16

    /// How far each mosaic cell overlaps its neighbours, as a fraction of a cell — the same
    /// number the importer uses, so the fixture is the shape the product really produces.
    public static let cellBleed = ArtworkLimits.rasterCellBleed

    /// The stamp box used by every artwork scene, in PDF points.
    public static let boxPoints = 192.0

    /// Where the artwork is placed on the page.
    public static let center = PDFPoint(x: 306, y: 500)

    /// Compiled vector artwork: a frame, a solid block, and three pairs of bars whose gaps
    /// differ by a factor of sixteen.
    ///
    /// Nothing here is a picture of anything. It is a **resolution target**, and every choice in
    /// it is made so that a scanline can count what a person would otherwise have to squint at:
    ///
    /// - the ink is *filled*, not stroked, because a sub-pixel stroke meets the renderer's
    ///   one-pixel legibility floor and the two backends floor it differently — a real
    ///   difference, tested by `retina-hairlines`, and not what this scene is for;
    /// - every bar is several device pixels wide **even at the lowest zoom**. Measured: an
    ///   earlier version of this fixture whose features were a fifth of a pixel at 25 % made
    ///   the two backends disagree by 8 % of the total ink, which is a fact about how each one
    ///   rounds sub-pixel coverage and, again, not about artwork;
    /// - what *is* sub-pixel at 25 % is the **gaps** — 0.002, 0.008 and 0.032 of the box, so
    ///   one pair is separated at 25 %, two at 100 % and all three at 400 %. A sub-pixel gap
    ///   between two solid fills is solid on both backends, so the picture they disagree about
    ///   is nothing, and the count of edges each of them resolves is the measurement.
    public static func vectorSeal() -> ArtworkGeometry {
        var regions: [ArtworkRegion] = []

        func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            regions.append(ArtworkRegion(outer: [
                PDFPoint(x: x0, y: y0), PDFPoint(x: x1, y: y0),
                PDFPoint(x: x1, y: y1), PDFPoint(x: x0, y: y1)
            ]))
        }

        // A frame, as four bars rather than one contour with a hole: an imported drawing
        // arrives as many small contours, and — measured — one region whose bounding box spans
        // the whole artwork costs the independent coverage oracle a hundred times what the same
        // ink costs as small ones. The first version of this fixture took the golden tool from
        // twenty seconds to minutes.
        quad(0.02, 0.02, 0.98, 0.05)
        quad(0.02, 0.95, 0.98, 0.98)
        quad(0.02, 0.05, 0.05, 0.95)
        quad(0.95, 0.05, 0.98, 0.95)

        let barWidth = 0.03
        var x = 0.12
        for gap in [0.032, 0.008, 0.002] {
            quad(x, 0.15, x + barWidth, 0.85)
            quad(x + barWidth + gap, 0.15, x + 2 * barWidth + gap, 0.85)
            x += 2 * barWidth + gap + 0.10
        }

        // Solid mass, so the ink the two backends have to agree about is dominated by area
        // rather than by edges.
        quad(0.62, 0.30, 0.90, 0.70)

        return ArtworkGeometry(
            kind: .vector, strokes: [], regions: regions, sourceAspectRatio: 1
        )
    }

    /// Compiled raster artwork: the same motif sampled onto a `cellCount x cellCount` grid,
    /// with horizontally adjacent cells of equal colour merged into one run — exactly what
    /// `StampArtworkImporter.mosaic` produces from an image file.
    ///
    /// Built here rather than imported so a golden does not depend on ImageIO's resampler,
    /// which is a different thing from the renderer and would make a golden a test of it.
    public static func rasterSeal() -> ArtworkGeometry {
        let cells = cellCount
        let cellSize = 1.0 / Double(cells)
        var regions: [ArtworkRegion] = []

        func color(atColumn column: Int, row: Int) -> RGBAColor? {
            // Row 0 is the top, matching the importer's own buffer convention.
            let x = (Double(column) + 0.5) * cellSize
            let y = 1.0 - (Double(row) + 0.5) * cellSize
            let distance = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)).squareRoot()
            if distance > 0.46 { return nil }
            if distance < 0.12 {
                return RGBAColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
            }
            if distance > 0.40 {
                return RGBAColor(red: 0.75, green: 0.15, blue: 0.30, alpha: 1)
            }
            return (column + row) % 2 == 0
                ? RGBAColor(red: 0.36, green: 0.55, blue: 0.85, alpha: 1)
                : RGBAColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
        }

        for row in 0..<cells {
            let top = 1.0 - Double(row) * cellSize
            let bottom = top - cellSize
            var runStart = 0
            var runColor: RGBAColor? = nil

            func flush(end: Int) {
                guard let runColor, end > runStart else { return }
                // The importer's own overlap, for the reason stated on
                // ``ArtworkLimits/rasterCellBleed``.
                let bleed = cellSize * ArtworkFixtureLibrary.cellBleed
                let left = Swift.max(0, Double(runStart) * cellSize - bleed)
                let right = Swift.min(1, Double(end) * cellSize + bleed)
                let low = Swift.max(0, bottom - bleed)
                let high = Swift.min(1, top + bleed)
                regions.append(ArtworkRegion(
                    outer: [
                        PDFPoint(x: left, y: low), PDFPoint(x: right, y: low),
                        PDFPoint(x: right, y: high), PDFPoint(x: left, y: high)
                    ],
                    color: runColor
                ))
            }

            for column in 0..<cells {
                let next = color(atColumn: column, row: row)
                if next != runColor {
                    flush(end: column)
                    runColor = next
                    runStart = column
                }
            }
            flush(end: cells)
        }
        return ArtworkGeometry(
            kind: .raster, strokes: [], regions: regions, sourceAspectRatio: 1
        )
    }

    /// The identity the **vector** artwork scenes place their artwork under.
    ///
    /// Vector and raster get different identities on purpose. A renderer reused across scenes
    /// keeps a slot per identity and skips the upload when `(id, revision, element count)` is
    /// unchanged — so two different pictures sharing one identity, one revision and one
    /// primitive count would leave the first one's geometry on screen under the second one's
    /// scene. `GoldenImageTests.rendererReuseIsClean` caught exactly that, which is what it is
    /// for; the fixture was wrong, not the arena.
    public static let vectorArtworkID = MarkupID(
        UUID(uuidString: "A27C0010-0000-4000-8000-000000000001") ?? UUID()
    )

    /// The identity the **raster** artwork scenes place their artwork under.
    public static let rasterArtworkID = MarkupID(
        UUID(uuidString: "A27C0020-0000-4000-8000-000000000001") ?? UUID()
    )

    /// The viewport an artwork scene is rendered through: a window on the stamp box with a
    /// small margin, so all three zooms frame the same thing at three resolutions.
    public static func viewport(for page: PageDescriptor, zoom: Double) -> RenderViewport {
        let margin = boxPoints * 0.08
        let rect = PDFRect(
            x: center.x - boxPoints / 2 - margin,
            y: center.y - boxPoints / 2 - margin,
            width: boxPoints + 2 * margin,
            height: boxPoints + 2 * margin
        )
        // The low-zoom scene is rendered on a Retina backing store, for the reason
        // `dashesAndCaps` gives for doing the same at 5 %: at 25 % on a 1x store the whole seal
        // is forty-eight pixels and every band is a fifth of one, so a comparison between the
        // two backends becomes a comparison of how each rounds sub-pixel coverage rather than
        // of what either drew. Still 25 % zoom, still the same geometry, in a picture where a
        // real difference would be visible instead of buried.
        let backingScale = zoom < 0.5 ? 2.0 : 1.0
        return RenderViewport.window(page, zoom: zoom, backingScale: backingScale, pageRect: rect)
            ?? RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: backingScale)
    }
}

extension SceneLibrary {

    /// Imported **vector** artwork at one zoom.
    public static func importedVectorArtwork(zoom: Double, name: String) -> RenderScene {
        let page = SceneIdentity.page()
        return RenderScene(
            name: name,
            purpose: "imported vector artwork, compiled to geometry, at zoom \(zoom)",
            page: page,
            markups: StampArtworkScene.markups(
                artwork: ArtworkFixtureLibrary.vectorSeal(),
                center: ArtworkFixtureLibrary.center,
                size: PDFSize(
                    width: ArtworkFixtureLibrary.boxPoints,
                    height: ArtworkFixtureLibrary.boxPoints
                ),
                style: RenderStyle(stroke: nil, fill: SceneColors.outline),
                baseID: ArtworkFixtureLibrary.vectorArtworkID
            ),
            viewport: ArtworkFixtureLibrary.viewport(for: page, zoom: zoom)
        )
    }

    /// Imported **raster** artwork at one zoom.
    public static func importedRasterArtwork(zoom: Double, name: String) -> RenderScene {
        let page = SceneIdentity.page()
        return RenderScene(
            name: name,
            purpose: "imported raster artwork, compiled to a bounded mosaic, at zoom \(zoom)",
            page: page,
            markups: StampArtworkScene.markups(
                artwork: ArtworkFixtureLibrary.rasterSeal(),
                center: ArtworkFixtureLibrary.center,
                size: PDFSize(
                    width: ArtworkFixtureLibrary.boxPoints,
                    height: ArtworkFixtureLibrary.boxPoints
                ),
                style: RenderStyle(stroke: nil, fill: SceneColors.ink),
                baseID: ArtworkFixtureLibrary.rasterArtworkID
            ),
            viewport: ArtworkFixtureLibrary.viewport(for: page, zoom: zoom)
        )
    }

    /// A grid of count marks drawn from imported artwork rather than from the atlas.
    ///
    /// A count mark with a chosen symbol, rendered through exactly the
    /// pipeline a stamp's picture goes through. Half the grid is a mark whose artwork the
    /// store still has; the other half is a mark whose artwork it does not, so the fallback
    /// glyph is in the golden too — a count of twenty that draws ten marks would be a wrong
    /// quantity, and this is the picture that says it does not happen.
    public static func importedCountSymbols() -> RenderScene {
        let page = SceneIdentity.page()
        let artwork = ArtworkFixtureLibrary.vectorSeal()
        var markups: [RenderableMarkup] = []
        var index = 0
        for row in 0..<4 {
            for column in 0..<5 {
                let center = PDFPoint(x: 110 + Double(column) * 100, y: 200 + Double(row) * 120)
                let identity = MarkupID(
                    // The family key is the first twelve bytes, so the index has to live in
                    // an *early* one. Putting it in the last four made all twenty marks share
                    // a family and collapse onto one another in the Metal arena — which is
                    // how this fixture found ADR-0011 §2.6's defect a second time.
                    UUID(uuidString: String(
                        format: "A27D%04d-0000-4000-8000-000000000001", index
                    )) ?? UUID()
                )
                let hasArtwork = index % 2 == 0
                let symbol = hasArtwork
                    ? MarkupSymbol(
                        artworkDigest: String(repeating: "c", count: 64),
                        kind: .vector,
                        sizePoints: 56,
                        rotationDegrees: Double(row) * 15
                      )
                    : MarkupSymbol.builtIn(
                        CountSymbol.allCases[index % CountSymbol.allCases.count].name,
                        sizePoints: 56
                      )
                markups.append(contentsOf: StampArtworkScene.markups(
                    symbol: symbol,
                    artwork: hasArtwork ? artwork : nil,
                    center: center,
                    style: RenderStyle(
                        stroke: SceneColors.count, fill: SceneColors.count, lineWidth: 0.5
                    ),
                    baseID: identity,
                    zIndex: index
                ))
                index += 1
            }
        }
        return RenderScene(
            name: "count-symbols-imported",
            purpose: "count marks drawn from imported artwork, with the built-in fallback",
            page: page,
            markups: markups,
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
    }
}
