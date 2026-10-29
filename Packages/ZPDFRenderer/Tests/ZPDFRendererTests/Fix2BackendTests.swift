import CoreGraphics
import Foundation
import Metal
import Testing
import ZPDFContracts
@testable import ZPDFRenderer
@testable import ZPDFRendererScenario

/// Bug hunt 2: the backends, the factory, the arena, and the golden oracle.
@Suite("Fix2 backends", .serialized)
struct Fix2BackendTests {

    private static let page = SceneIdentity.page()

    private static func id(_ n: UInt8) -> MarkupID {
        MarkupID(UUID(uuid: (0xF2, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)))
    }

    // MARK: BH-202

    @Test("BH-202: encoding into a one-sample attachment binds the one-sample pipelines")
    func encodeHonoursTheAttachmentSampleCount() throws {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let (page, markups) = SceneLibrary.stress(count: 300, seed: 0x202)
        let viewport = RenderViewport.fittingWholePage(page, zoom: 0.5, backingScale: 1)
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        let reference = try renderer.renderOffscreen()

        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = viewport.pixelSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let queue = try #require(device.makeCommandQueue())
        let buffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
        // Old API: `encode(into:)` bound the multisampled set whatever the attachment was; with
        // `MTL_DEBUG_LAYER=1` that aborts in setRenderPipelineState (measured), without it the
        // draw is undefined.
        renderer.encode(into: encoder, attachmentSampleCount: 1)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)
        #expect(renderer.statistics.drawCallCount > 0)

        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        texture.getBytes(&bytes, bytesPerRow: size.width * 4,
                         from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
        let image = try #require(RasterImage.fromBGRA(width: size.width, height: size.height, bytes: bytes))
        let comparison = ImageComparator.compare(image, reference)
        #expect(comparison.matches, "\(comparison.failureReasons)")

        // A sample count nothing was built for encodes nothing instead of something undefined.
        let other = try #require(queue.makeCommandBuffer())
        let otherEncoder = try #require(other.makeRenderCommandEncoder(descriptor: pass))
        renderer.encode(into: otherEncoder, attachmentSampleCount: 3)
        otherEncoder.endEncoding()
        other.commit()
        other.waitUntilCompleted()
        #expect(renderer.statistics.drawCallCount == 0)
    }

    // MARK: BH-629

    @Test("BH-629: a slot that cannot grow keeps its previous instances instead of vanishing")
    func failedGrowKeepsTheMarkup() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let stride = MemoryLayout<SegmentInstance>.stride
        // Room for the first 1 024-element buffer, not for the 2 048 a grow would need.
        let arena = InstanceArena<SegmentInstance>(
            device: device, dead: .dead, label: "test", maximumByteCount: 1_500 * stride
        )
        let markup = Self.id(1)
        arena.beginTargetedFrame()
        let small = (0..<10).map { SegmentInstance(p0x: Float($0), p0y: 0, p1x: 1, p1y: 0, width: 1) }
        #expect(arena.upsert(markup, revision: 1, elements: small))
        let big = (0..<1_200).map { SegmentInstance(p0x: Float($0), p0y: 0, p1x: 1, p1y: 0, width: 1) }
        #expect(!arena.upsert(markup, revision: 2, elements: big))
        arena.endFrame()
        // Old output: nil — the slot was released (instances stamped dead) before the failed
        // allocation, and the markup disappeared.
        let span = try #require(arena.slotSpan(of: markup))
        #expect(span.count == 10)
        #expect(arena.allocationFailureCount == 1)
    }

    // MARK: BH-631 / IM-197 / IM-084

    @Test("BH-631: the resident figure includes the render targets")
    func residentBytesIncludeTargets() throws {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let (page, markups) = SceneLibrary.stress(count: 50, seed: 0x631)
        let viewport = RenderViewport.fittingWholePage(page, zoom: 1, backingScale: 2)
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        let before = renderer.residentByteCount
        _ = try renderer.renderOffscreen()
        let pixels = viewport.pixelSize.pixelCount
        // Old output: unchanged by rendering — neither the resolve texture nor the readback
        // buffer (each at least w·h·4 bytes) was counted.
        #expect(renderer.residentByteCount >= before + 2 * pixels * 4)
        #expect(renderer.renderTargetByteCount >= 2 * pixels * 4)
    }

    @Test("Z7: the statistics' resident figure is instance storage; render targets are reported beside it")
    func statisticsKeepInstanceStorageApartFromTargets() throws {
        // The app's underlay renders a 1600 x 1000 px plan (an 800 x 500 pt window at 2x) and
        // holds its instance storage to 16 MiB per page (gate Z7). BH-631 folded the targets
        // into that figure: measured here, +14.7 MB (1792 x 1024 resolve + readback), which is
        // what took the app test to 22 810 624 bytes.
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let (page, markups) = SceneLibrary.stress(count: 20_000, seed: 0x27)
        guard let viewport = RenderViewport.window(page, zoom: 2, backingScale: 2, pageRect: PDFRect(x: 100, y: 200, width: 400, height: 250))
        else { Issue.record("no viewport"); return }
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        _ = try renderer.renderOffscreen()
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        let statistics = renderer.statistics
        print("Z7 probe at \(viewport.pixelSize.width)x\(viewport.pixelSize.height): statistics.residentByteCount \(statistics.residentByteCount), renderTargetByteCount \(statistics.renderTargetByteCount), renderer.residentByteCount \(renderer.residentByteCount)")
        #expect(statistics.residentByteCount == renderer.instanceResidentByteCount)
        #expect(statistics.renderTargetByteCount == renderer.renderTargetByteCount)
        #expect(statistics.renderTargetByteCount >= 2 * viewport.pixelSize.pixelCount * 4)
        #expect(renderer.residentByteCount == statistics.residentByteCount + statistics.renderTargetByteCount)
    }

    @Test("IM-197: twenty zoom steps a few pixels apart allocate the render targets once")
    func targetsAreReusedAcrossSmallResizes() throws {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let (page, markups) = SceneLibrary.stress(count: 50, seed: 0x197)
        var first: RasterImage?
        for step in 0..<20 {
            let zoom = 0.85 + Double(step) * 0.004  // 520…567 × 673…733 px: inside one 256-px bucket
            let viewport = RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 1)
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
            let image = try renderer.renderOffscreen()
            #expect(image.size == viewport.pixelSize)
            if step == 0 { first = image }
        }
        // Old output: 20 — every size change reallocated resolve, MSAA and readback.
        #expect(renderer.targetAllocationCount == 1, "\(renderer.targetAllocationCount) allocations")

        // The sub-rectangle render is the same picture a fresh, exactly sized target gives.
        let fresh = try MetalMarkupRenderer()
        defer { fresh.dispose() }
        let viewport = RenderViewport.fittingWholePage(page, zoom: 0.85, backingScale: 1)
        fresh.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        let reference = try fresh.renderOffscreen()
        #expect(first == reference)

        // A sheet that shrinks to a quarter of the area gives the memory back.
        let small = RenderViewport.fittingWholePage(page, zoom: 0.2, backingScale: 1)
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: small)
        _ = try renderer.renderOffscreen()
        #expect(renderer.targetAllocationCount == 2)
    }

    @Test("IM-084: the CGImage path skips the array, swizzle and data copies, and is faster")
    func cgImagePathIsCheaper() throws {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        let (page, markups) = SceneLibrary.stress(count: 2_000, seed: 0x84)
        let viewport = RenderViewport.fittingWholePage(page, zoom: 2.5, backingScale: 2)
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
        _ = try renderer.renderOffscreen() // warm up targets and pipelines

        func median(_ body: () throws -> Void) rethrows -> Double {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                try body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return samples.sorted()[2]
        }
        let old = try median { _ = try renderer.renderOffscreen().makeCGImage() }
        let new = try median { _ = try renderer.renderOffscreenImage() }
        print("IM-084 at \(viewport.pixelSize.width)x\(viewport.pixelSize.height): renderOffscreen().makeCGImage() p50 \(old) ms, renderOffscreenImage() p50 \(new) ms")
        #expect(new < old)
    }

    // MARK: BH-620

    @Test("BH-620: a stroke with two different caps has no seam at its midpoint")
    func splitCapStrokeHasNoSeam() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        // At zoom 1 a page point is a pixel; the midpoint x = 200.5 splits pixel column 200.
        let line = RenderableMarkup(
            id: Self.id(2),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 150, y: 400), PDFPoint(x: 251, y: 400)])),
            style: RenderStyle(stroke: .opaqueBlack, lineWidth: 6, startCap: .butt, endCap: .round)
        )
        renderer.update(
            page: Self.page, markups: [line], selection: .empty, snapFeedback: nil,
            viewport: RenderViewport.fittingWholePage(Self.page, zoom: 1, backingScale: 1)
        )
        let image = try renderer.renderOffscreen()
        let row = 792 - 400
        // Old output: alpha ≈ 0.75 in column 200 — the two antialiased clip halves each gave it
        // half coverage and composited to 1 − c(1 − c).
        #expect(image.alpha(x: 200, y: row) > 0.99, "seam alpha \(image.alpha(x: 200, y: row))")
        #expect(image.alpha(x: 199, y: row) > 0.99)
        #expect(image.alpha(x: 201, y: row) > 0.99)
        // The caps are still the two that were asked for: butt at the start, round past the end.
        #expect(image.alpha(x: 148, y: row) < 0.01)
        #expect(image.alpha(x: 253, y: row) > 0.5)
    }

    // MARK: BH-622

    @Test("BH-622: a Metal start-up failure that is not about pipelines is not called one")
    func factoryNamesTheRealCause() {
        let degradation = MarkupRendererFactory.degradation(from: RendererError.commandEncodingFailed("no queue"))
        // Old output: .pipelineCreationFailed("commandEncodingFailed(…)").
        guard case let .startupFailed(message) = degradation else {
            Issue.record("classified as \(degradation)")
            return
        }
        #expect(message.contains("no queue"))
        #expect(!degradation.description.contains("pipeline creation failed"))
        #expect(MarkupRendererFactory.degradation(from: RendererError.pipelineCreationFailed("p"))
            == .pipelineCreationFailed("p"))
        #expect(MarkupRendererFactory.degradation(from: RendererError.metalDeviceUnavailable) == .noMetalDevice)
    }

    // MARK: BH-637

    @Test("BH-637: a size mismatch says so, instead of '-1 tiles over'")
    func provenanceNamesASizeMismatch() {
        let image = RasterImage(width: 20, height: 10)
        let reference = ReferenceRasterizer.Coverage(width: 30, height: 10)
        let result = GoldenProvenance.compare(image: image, reference: reference)
        #expect(!result.matches)
        #expect(result.summary.contains("size mismatch"), "\(result.summary)")
        #expect(result.summary.contains("20x10") && result.summary.contains("30x10"))
        #expect(!result.summary.contains("-1"))
    }

    // MARK: BH-638 / BH-639 / BH-640 / BH-641

    @Test("BH-638: the oracle rejects the degenerate contours the compiler rejects")
    func oracleRejectsDegenerateContours() {
        let twoPointOuter = RenderableMarkup(
            id: Self.id(3),
            shape: .filledPolygon(RenderPolygon(outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 10)])),
            style: RenderStyle(stroke: .opaqueBlack, fill: .opaqueBlack)
        )
        // Old output: stroked as a closed two-segment outline with round caps.
        #expect(ReferenceRasterizer.usable(twoPointOuter) == nil)
        let compiler = MarkupCompiler(glyphAtlases: GlyphAtlasCache(), pixelsPerPagePoint: 1)
        #expect(compiler.compile(twoPointOuter) == nil, "the compiler agrees")

        let twoPointHole = RenderableMarkup(
            id: Self.id(4),
            shape: .filledPolygon(RenderPolygon(
                outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0), PDFPoint(x: 50, y: 50)],
                holes: [[PDFPoint(x: 10, y: 5), PDFPoint(x: 20, y: 6)]]
            ))
        )
        guard case let .filledPolygon(kept)? = ReferenceRasterizer.usable(twoPointHole)?.shape else {
            Issue.record("the polygon itself is usable")
            return
        }
        #expect(kept.holes.isEmpty, "a two-point hole encloses nothing and is skipped, as by the compiler")
    }

    @Test("BH-639: the oracle drops consecutive duplicates before placing caps")
    func oracleDeduplicatesVertices() throws {
        let line = RenderableMarkup(
            id: Self.id(5),
            shape: .polyline(RenderPolyline(points: [PDFPoint(x: 5, y: 5), PDFPoint(x: 5, y: 5), PDFPoint(x: 40, y: 5)])),
            style: RenderStyle(lineWidth: 4, startCap: .square, endCap: .square)
        )
        guard case let .polyline(kept)? = ReferenceRasterizer.usable(line)?.shape else {
            Issue.record("usable")
            return
        }
        // Old output: [A, A, B] — a zero-length first segment capped +x at A, and a round cap
        // where the square one belongs.
        #expect(kept.points == [PDFPoint(x: 5, y: 5), PDFPoint(x: 40, y: 5)])
    }

    @Test("BH-640: the oracle scales dash offsets with the factor it scales the runs with")
    func oracleDashRuleMatchesDashPattern() throws {
        for runs in [[9.0, 5, 9, 5, 1], [6, 2, 1], [1.2, 3.6], [0.01, 2.2], [4, 2]] {
            let style = RenderStyle(dash: .pattern(runs: runs, phase: 0))
            for ppp in [0.05, 0.1, 1, 2] {
                let rule = try #require(ReferenceRasterizer.dashRule(style: style, pixelsPerPagePoint: ppp))
                let pattern = DashPattern(style.dash)
                // Old output for [9,5,9,5,1] at 0.1: offsets scaled by 1.5 (the whole list's
                // smallest run, 1) while the runs were scaled by 0.3.
                #expect(abs(rule.scale - pattern.deviceScale(pixelsPerPagePoint: ppp)) < 1e-12, "\(runs) @ \(ppp)")
                #expect(rule.runs == pattern.runArray)
            }
        }
    }

    @Test("BH-641: an infinite fill vertex does not trap the oracle")
    func oracleSurvivesInfiniteVertices() {
        let scene = RenderScene(
            name: "infinite-vertex",
            purpose: "test",
            page: Self.page,
            markups: [RenderableMarkup(
                id: Self.id(6),
                shape: .filledPolygon(RenderPolygon(outer: [
                    PDFPoint(x: .infinity, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100)
                ])),
                style: RenderStyle(stroke: nil, fill: .opaqueBlack)
            )],
            viewport: RenderViewport.fittingWholePage(Self.page, zoom: 0.25, backingScale: 1)
        )
        // Old output: a trap in `Int(box.maxX.rounded(.up))`.
        let coverage = ReferenceRasterizer.rasterize(scene)
        #expect(coverage.alpha.allSatisfy { $0 == 0 }, "rejected, as the compiler rejects it")
    }
}
