import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFUIPresentation
import ZPDFVectorExtraction
import ZPDFTestingSupport
@testable import ZenitPDFAppKit

/// Gate **Z10** and the vector underlay's own honesty conditions.
///
/// The underlay is the one layer of the viewer that is *not* the page, so the assertions here
/// are as much about what it refuses to be as about what it draws.
@MainActor
@Suite(.appTierSerialised)
struct VectorUnderlayTests {

    // MARK: - Z10

    @Test("Z10: the underlay is on with a Metal backend and off, with a reason, without one")
    func z10_availabilityIsStatedEitherWay() async {
        let metal = VectorUnderlay(preference: .metal)
        let metalAvailability = await metal.availability
        await metal.dispose()

        // Forced onto the fallback backend, which is what a Mac without a Metal device gets.
        let fallback = VectorUnderlay(preference: .coreGraphics)
        let fallbackAvailability = await fallback.availability
        await fallback.dispose()

        #expect(!fallbackAvailability.isAvailable, "Z10: the Core Graphics backend must not draw the underlay")
        #expect(
            fallbackAvailability.explanation.count > 40,
            "Z10: switching the underlay off must come with a visible explanation, got \(fallbackAvailability.explanation)"
        )
        #expect(
            fallbackAvailability.explanation.lowercased().contains("underlay"),
            "Z10: the explanation must name what was switched off"
        )
        // The explanation must not claim the page itself is degraded — it is not. Only the
        // skeleton is gone; the raster is still produced at the true device scale.
        #expect(fallbackAvailability.explanation.contains("full sharpness"))

        print("Z10 metal:    \(metalAvailability.explanation)")
        print("Z10 fallback: \(fallbackAvailability.explanation)")

        // On this machine Metal is present. On a machine without it the first value is a
        // refusal with its own reason, which is still a pass: what Z10 forbids is silence.
        if case let .available(deviceName) = metalAvailability {
            #expect(!deviceName.isEmpty)
        } else {
            #expect(metalAvailability.explanation.count > 40)
        }
    }

    @Test("Z10: the fallback backend renders nothing rather than a slow skeleton")
    func z10_fallbackDrawsNothing() async throws {
        let (page, extraction) = try await Self.roofPlanPageAndExtraction()
        let underlay = VectorUnderlay(preference: .coreGraphics)
        await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: [])
        let plan = try Self.plan(page: page, zoom: 2)
        let image = await underlay.render(page: page, plan: plan)
        #expect(image == nil, "Z10: a 98-134 ms per frame underlay must not be drawn at all")
        await underlay.dispose()
    }

    @Test("The Metal underlay draws the roof plan's linework, at the plan's exact pixel size")
    func metalUnderlayDrawsInk() async throws {
        let (page, extraction) = try await Self.roofPlanPageAndExtraction()
        let underlay = VectorUnderlay(preference: .metal)
        guard await underlay.availability.isAvailable else {
            // A machine with no Metal device. Gate Z10 is then satisfied by the refusal test
            // above, and there is nothing here to draw.
            await underlay.dispose()
            print("no Metal device on this machine; the underlay render path is not exercised")
            return
        }
        let compile = await measureViewerMillisecondsAsync {
            await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: [])
        }

        var perZoom: [(CGFloat, Double, Int)] = []
        for zoom in [CGFloat(0.5939), 1, 2, 4, 8] {
            let plan = try Self.plan(page: page, zoom: zoom)
            let image = try #require(await underlay.render(page: page, plan: plan))
            #expect(image.width == plan.pixelSize.width)
            #expect(image.height == plan.pixelSize.height)
            #expect(inkFraction(image) > 0.0005, "the skeleton must have lines in it at zoom \(zoom)")

            var samples: [Double] = []
            for _ in 0..<8 {
                samples.append(await measureViewerMillisecondsAsync {
                    _ = await underlay.render(page: page, plan: plan)
                })
            }
            perZoom.append((zoom, ViewerLatency(samples: samples).p50, plan.pixelCount))
        }
        let statistics = await underlay.statistics
        await underlay.dispose()

        print("--- vector underlay, A1 roof plan, Metal ---")
        print(String(format: "  first compile              %8.1f ms (once per page, off the main actor)", compile))
        for (zoom, p50, pixels) in perZoom {
            print(String(
                format: "  zoom %5.2f  %8d px   update + encode + GPU + readback p50 %7.3f ms",
                Double(zoom), pixels, p50
            ))
        }
        print("  line instances \(statistics.lineInstanceCount), resident \(statistics.residentByteCount) bytes")

        // Gate Z7's underlay clause: 16 MiB per page of instance storage.
        #expect(
            statistics.residentByteCount <= 16 * 1024 * 1024,
            "Z7: the underlay holds \(statistics.residentByteCount) bytes, ceiling 16 MiB"
        )
    }

    /// Fraction of pixels with any alpha. The skeleton is transparent everywhere it is not a
    /// line, which is what lets it sit over paper without hiding it.
    private func inkFraction(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        alpha.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let inked = alpha.reduce(into: 0) { count, value in if value > 8 { count += 1 } }
        return Double(inked) / Double(max(1, width * height))
    }

    // MARK: - The compiler

    @Test("The compiler turns the roof plan into a skeleton of the right size")
    func compilesTheRoofPlan() async throws {
        let (_, extraction) = try await Self.roofPlanPageAndExtraction()
        let markups = PageUnderlayCompiler.markups(from: extraction)
        #expect(markups.count > 10_000, "the roof plan carries 16 341 primitives, got \(markups.count)")
        #expect(markups.count <= extraction.primitives.count)

        // Every compiled markup is a polyline. Nothing else: no fills, no text, no symbols.
        for markup in markups {
            guard case .polyline = markup.shape else {
                Issue.record("the underlay may only contain polylines, found \(markup.shape)")
                return
            }
            #expect(markup.style.fill == nil, "the underlay never fills: the extraction has no paint")
        }

        // Identities are stable, so the renderer's diff-based update does not re-upload the
        // whole sheet on every frame.
        let again = PageUnderlayCompiler.markups(from: extraction)
        #expect(markups.map(\.id) == again.map(\.id))
        print("underlay: \(markups.count) polylines from \(extraction.primitives.count) primitives")
    }

    @Test("The compiler honours a hidden layer, so the skeleton cannot show what the page hides")
    func honoursHiddenLayers() async throws {
        // The layered variant: the hatch on /L0 ("Hatch"), the grid axes and their label circles on
        // /L1 ("Grid"), both visible by default (`FIXTURES.md`).
        let (_, extraction) = try await Self.roofPlanPageAndExtraction(.syntheticRoofPlanLayered)
        let all = PageUnderlayCompiler.markups(from: extraction)
        let names = Set(extraction.primitives.compactMap(\.layerID))
        #expect(names == ["L0", "L1"], "\(names)")
        // One markup per open segment and per closed shape, never per edge of a shape: the sheet's
        // 16 341 primitives less the 75 edges of its shapes (the border's 4, the scale bar's 40,
        // the north arrow's 3 and its ring's 4, five axis circles' 20, the distractor circle's 4).
        #expect(all.count == 16_341 - 75, "\(all.count)")
        // Hiding the hatch takes its 14 085 strokes out; hiding the grid its 262 axis elements and
        // the 5 label circles.
        let withoutHatch = PageUnderlayCompiler.markups(from: extraction, hiddenLayerIDs: ["L0"])
        #expect(all.count - withoutHatch.count == 14_085, "\(all.count - withoutHatch.count)")
        let withoutGrid = PageUnderlayCompiler.markups(from: extraction, hiddenLayerIDs: ["L1"])
        #expect(all.count - withoutGrid.count == 262 + 5, "\(all.count - withoutGrid.count)")
        // A limit turns an adversarial page into a truncated skeleton, never an allocation.
        let bounded = PageUnderlayCompiler.markups(from: extraction, limit: 100)
        #expect(bounded.count == 100)
    }

    @Test("A cubic is flattened, a ring keeps its vertices, a line stays two points")
    func geometryConversion() {
        let line = PageUnderlayCompiler.polyline(
            for: .line(VectorLine(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10)))
        )
        #expect(line?.points.count == 2)
        #expect(line?.isClosed == false)

        let cubic = PageUnderlayCompiler.polyline(
            for: .cubic(VectorCubic(
                p0: CGPoint(x: 0, y: 0),
                p1: CGPoint(x: 0, y: 10),
                p2: CGPoint(x: 10, y: 10),
                p3: CGPoint(x: 10, y: 0)
            ))
        )
        #expect(cubic?.points.count == PageUnderlayCompiler.cubicSegments + 1)
        // Endpoints are exact, not approximated by the flattening.
        #expect(cubic?.points.first?.x == 0 && cubic?.points.first?.y == 0)
        #expect(cubic?.points.last?.x == 10 && cubic?.points.last?.y == 0)
    }

    // MARK: - What the canvas does with it

    @Test("The underlay replaces a stale raster and never covers a settled one")
    func layerOrder() throws {
        let box = PDFRectValue(x: 0, y: 0, width: 400, height: 300)
        let transform = PageDisplayTransform(pageBox: box, rotation: 0, zoom: 1, origin: .zero)
        let view = CanvasPageView()
        view.backingScaleOverride = 1
        view.transform = transform
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        // A settled raster: a red page.
        let settled = PageRaster(
            image: try solid(width: 400, height: 300, red: 1, green: 0, blue: 0),
            coverage: .region(box),
            scale: 1
        )
        // An underlay: a green page. Never seen while the raster is settled.
        let underlay = PageRaster(
            image: try solid(width: 400, height: 300, red: 0, green: 1, blue: 0),
            coverage: .region(box),
            scale: 1
        )
        view.pageRaster = settled
        view.underlayRaster = underlay
        #expect(colour(of: view, atX: 200, y: 150).red > 0.8, "a settled raster wins")

        // Now the user zooms: the same raster is stale at twice the zoom, and the underlay,
        // which was made for the new zoom, takes its place.
        let zoomed = PageDisplayTransform(pageBox: box, rotation: 0, zoom: 2, origin: .zero)
        view.transform = zoomed
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.underlayRaster = PageRaster(
            image: try solid(width: 800, height: 600, red: 0, green: 1, blue: 0),
            coverage: .region(box),
            scale: 2
        )
        #expect(colour(of: view, atX: 400, y: 300).green > 0.8, "a stale raster gives way to the underlay")

        // And with no underlay at all — a Mac without Metal — the stale raster is still shown
        // rather than a blank page. Degradation, never a hole.
        view.underlayRaster = nil
        #expect(colour(of: view, atX: 400, y: 300).red > 0.8, "without an underlay the stale raster stays")
    }

    // MARK: - Support

    private func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func colour(of view: CanvasPageView, atX x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (0, 0, 0)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        guard let colour = rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)) else {
            return (0, 0, 0)
        }
        let srgb = colour.usingColorSpace(.sRGB) ?? colour
        return (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
    }

    /// Page 0 of a synthetic roof plan and its extraction, hidden optional content included.
    static func roofPlanPageAndExtraction(
        _ kind: FixtureKind = .syntheticRoofPlan
    ) async throws -> (ZPDFContracts.PageDescriptor, VectorPageExtraction) {
        let url = kind == .syntheticRoofPlan ? try ViewerZoomGateTests.roofPlan() : try ZPDFFixtures.shared(kind).url
        let drawing = try await DocumentSessionLoader.load(pdfAt: url)
        let page = drawing.pages[0]
        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let extraction = try #require(
            try? await VectorExtractor(options: options).extract(documentAt: url, pageIndex: 0)
        )
        await drawing.rasterSource.close()
        return (page, extraction)
    }

    static func plan(page: ZPDFContracts.PageDescriptor, zoom: CGFloat) throws -> ViewportRasterPlan {
        let box = ViewerZoomGateTests.pageBoxValue(page)
        let transform = PageDisplayTransform(
            pageBox: box,
            rotation: page.rotation.rawValue,
            zoom: zoom,
            origin: CGPoint(x: 24, y: 24)
        )
        let frame = transform.pageFrame
        let visible = CGRect(
            x: frame.midX - min(800, frame.width) / 2,
            y: frame.midY - min(500, frame.height) / 2,
            width: min(800, frame.width),
            height: min(500, frame.height)
        )
        return try ViewportRasterPlanner.plan(
            transform: transform,
            visibleViewRect: visible,
            backingScale: 2
        )
    }
}
