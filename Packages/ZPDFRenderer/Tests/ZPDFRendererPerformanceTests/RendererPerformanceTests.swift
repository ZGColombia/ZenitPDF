import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import Metal
import ZPDFGeometry
import ZPDFRenderer
import ZPDFRendererScenario

/// Frame build and encode cost, incremental update cost, and buffer memory — measured and
/// printed, at the sizes of the stress corpus.
///
/// # What is being timed
///
/// **Frame build plus encode on the CPU**: everything between the app handing over a scene and
/// the command buffer being committed. That is `update(...)` — the diff against the previous
/// frame, the compile of anything that changed, the slot writes — plus the render-pass encode.
/// It is not GPU execution time, which is measured separately and reported alongside.
///
/// The 16.6 ms budget is a budget on this number, because it is the part that happens on the main
/// actor between one frame and the next. GPU time overlaps the next frame's CPU work.
@Suite("Renderer performance", .serialized)
struct RendererPerformanceTests {

    private static let frameCount = 120
    private static let zoomLevels: [Double] = [0.05, 1.0, 8.0]

    private func makeMetal() throws -> MetalMarkupRenderer {
        try MetalMarkupRenderer()
    }

    private func viewport(_ page: PageDescriptor, zoom: Double) -> RenderViewport {
        // A fixed 1600 x 1000 point canvas on a Retina display, which is what a real window is;
        // fitting the whole page at 800 % would ask for a 78-megapixel drawable that no window
        // has ever had.
        let layout = PageViewLayout(anchor: .zero, zoom: zoom, backingScale: 2.0, isViewFlipped: true)
        return RenderViewport(
            layout: layout,
            viewSize: CGSize(width: 1_600, height: 1_000),
            visiblePageRect: page.visibleBox
        )
    }

    /// Where the remaining GPU time goes when a zoom still misses. Printed, not summarised
    /// away, because the alternative to saying it is lowering the bar.
    private static let gpuShortfallExplanation: [String] = [
        "  Where the time goes, measured on this machine rather than guessed:",
        "  * Batching by material is done, and it was not the lever. A frame issues four draw",
        "    calls and four pipeline binds at 200 markups and the same four at 50 000, which is",
        "    what `MaterialBatchingTests` asserts, and the CPU side of a frame fits its budget at",
        "    every size and zoom. State changes were never the cost.",
        "  * The stroke fragment shader was the second lever. Coverage is computed analytically —",
        "    the exact box filter of the ink interval — instead of by a 4x4 quadrature over a",
        "    signed distance field. It bought 2.1x to 3.6x and it is not arithmetic that is left:",
        "    quadrupling the coverage arithmetic changes the frame time by nothing measurable.",
        "  * Splitting the render pass was the third and largest. Fills keep their four samples,",
        "    which they need because the rasteriser decides where a polygon edge is; strokes,",
        "    atlas quads and the overlay draw in a second single-sample pass over the resolved",
        "    target, because their shaders compute their own coverage and gained nothing from",
        "    multisampling but paid for it four times over. Measured apart from everything else",
        "    by `renderPassSplitSweep`: 3.8x to 12.1x. The segment quad's antialiasing pad then",
        "    narrowed from 1.0 to 0.5 device pixels, which a single-sample attachment makes",
        "    correct, for a further 1.1x to 1.2x. `RenderPassSplitTests` holds both to the",
        "    Core Graphics oracle on ten scenes at the stroke suite's tighter budget.",
        "  * If a cell above still misses, the levers left are about how much is rasterised and",
        "    nothing else: a level of detail that merges a whole markup's segments into one quad",
        "    once the markup projects below a few pixels — which changes pixels and would need",
        "    its own justification and its own counter, exactly as the sub-pixel cutoff has — and",
        "    beyond that, fewer instances rather than cheaper ones."
    ]

    /// Debug builds measure the compiler as much as the renderer, so they get their own
    /// budgets: looser — four frames where release gets one — but real, so a debug-only CI run
    /// still fails on a genuine regression instead of asserting nothing.
    private static var frameBudgetMilliseconds: Double { isReleaseBuild ? 16.6 : 66.4 }

    @Test("Frame build, encode and GPU execution at 1 000 to 100 000 markups, at 5 %, 100 % and 800 %")
    func frameBuildAndEncode() throws {
        print("")
        print("=== ZPDFRenderer benchmark: frame build + encode, milliseconds ===")
        print("build: \(isReleaseBuild ? "release" : "debug — budgets are budgets on optimised code")")
        let renderer = try makeMetal()
        defer { renderer.dispose() }
        print("device: \(renderer.deviceName), \(renderer.sampleCount)x multisampling")

        var met60fpsAt100k = true
        var worstGPUAt100k = 0.0
        var worstGPUZoom = 0.0
        var gpuTable: [(count: Int, zoom: Double, p50: Double, meets: Bool)] = []
        for markupCount in [1_000, 10_000, 50_000, 100_000] {
            let scene = SceneLibrary.stress(count: markupCount)
            for zoom in Self.zoomLevels {
                let viewport = viewport(scene.page, zoom: zoom)

                // The first update builds everything; it is reported separately because it is a
                // different operation from a steady-state frame and averaging them hides both.
                let coldBuild = measureMilliseconds {
                    renderer.update(
                        page: scene.page,
                        markups: scene.markups,
                        selection: .empty,
                        snapFeedback: nil,
                        viewport: viewport
                    )
                }
                let statistics = renderer.statistics

                var buildSamples: [Double] = []
                var encodeSamples: [Double] = []
                var totalSamples: [Double] = []
                var gpuSamples: [Double] = []
                buildSamples.reserveCapacity(Self.frameCount)
                for frame in 0..<Self.frameCount {
                    // A steady-state frame: the scene is unchanged, the viewport pans by a pixel,
                    // which is what scrolling actually is.
                    var panned = viewport
                    panned.layout.anchor = CGPoint(x: Double(frame % 40) * -1, y: 0)
                    let build = measureMilliseconds {
                        renderer.update(
                            page: scene.page,
                            markups: scene.markups,
                            selection: .empty,
                            snapFeedback: nil,
                            viewport: panned
                        )
                    }
                    var commandBuffer: (any MTLCommandBuffer)?
                    let encode = measureMilliseconds {
                        commandBuffer = try? renderer.encodeFrame()
                    }
                    buildSamples.append(build)
                    encodeSamples.append(encode)
                    totalSamples.append(build + encode)
                    // Every eighth frame is waited on, so GPU time is a measurement and not an
                    // inference. Waiting on every frame would serialise the pipeline and make the
                    // CPU figures a measurement of the GPU.
                    if frame % 8 == 0, let commandBuffer {
                        commandBuffer.waitUntilCompleted()
                        let gpu = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
                        if gpu > 0 { gpuSamples.append(gpu) }
                    }
                }
                let build = LatencySummary(
                    name: "\(markupCount) markups, zoom \(zoom): frame build",
                    samples: buildSamples
                )
                let encode = LatencySummary(
                    name: "\(markupCount) markups, zoom \(zoom): encode + commit",
                    samples: encodeSamples
                )
                let total = LatencySummary(
                    name: "\(markupCount) markups, zoom \(zoom): build + encode (CPU)",
                    samples: totalSamples
                )
                print(build.line)
                print(encode.line)
                print(total.line)
                if !gpuSamples.isEmpty {
                    print(LatencySummary(
                        name: "\(markupCount) markups, zoom \(zoom): GPU execution",
                        samples: gpuSamples
                    ).line)
                }
                let lastFrame = renderer.statistics
                print(String(
                    format: "  cold build %8.3f ms | %d lines, %d triangles, %d symbols, %d glyphs | %.1f MB resident",
                    coldBuild,
                    statistics.lineInstanceCount,
                    statistics.triangleCount,
                    statistics.symbolInstanceCount,
                    statistics.glyphInstanceCount,
                    Double(statistics.residentByteCount) / 1_048_576
                ))
                print(String(
                    format: "  culled %d of %d markups, %d below the half-pixel cutoff",
                    lastFrame.culledMarkupCount,
                    lastFrame.markupCount,
                    lastFrame.subPixelMarkupCount
                ))
                print(String(
                    format: "  %d draw calls, %d pipeline binds (batched by material; flat in markup count)",
                    lastFrame.drawCallCount,
                    lastFrame.pipelineStateChangeCount
                ))
                // The batching claim, asserted where the frame rate is measured and not only in
                // the unit suite: a frame is four materials, whatever the page holds.
                #expect(
                    lastFrame.drawCallCount <= 8,
                    "\(markupCount) markups issued \(lastFrame.drawCallCount) draw calls"
                )

                #expect(total.count == Self.frameCount)
                let gpuP50 = LatencySummary(name: "", samples: gpuSamples).p50
                gpuTable.append((
                    count: markupCount,
                    zoom: zoom,
                    p50: gpuP50,
                    meets: gpuP50 <= 16.6 && total.p99 <= 16.6
                ))
                if markupCount == 100_000 {
                    if total.p99 > 16.6 { met60fpsAt100k = false }
                    if gpuP50 > worstGPUAt100k {
                        worstGPUAt100k = gpuP50
                        worstGPUZoom = zoom
                    }
                }
                // The real (if loose in debug) budget: the CPU side of a frame
                // must fit the budget at every size and zoom, in every build configuration.
                #expect(
                    total.p99 < Self.frameBudgetMilliseconds,
                    "CPU frame build + encode p99 \(total.p99) ms at \(markupCount) markups, zoom \(zoom), missed the \(Self.frameBudgetMilliseconds) ms budget"
                )
            }
        }

        print("")
        print("--- GPU p50 by size and zoom (release figures are the ones that count) ---")
        for row in gpuTable {
            print(String(
                format: "%8d markups  zoom %5.2f   GPU p50 %9.3f ms   60 fps %@",
                row.count, row.zoom, row.p50, row.meets ? "MET" : "not met"
            ))
        }

        print("")
        print("--- 60 fps at 100 000 markups, stated plainly ---")
        if met60fpsAt100k {
            print("CPU, frame build + encode:  MET. p99 is under 16.6 ms at 5 %, 100 % and 800 %.")
        } else {
            print("CPU, frame build + encode:  NOT MET — see the p99 figures above.")
        }
        if worstGPUAt100k > 16.6 {
            print(String(
                format: "GPU, execution:             NOT MET. Worst p50 is %.0f ms, at zoom %.2f.",
                worstGPUAt100k, worstGPUZoom
            ))
            for line in Self.gpuShortfallExplanation { print(line) }
        } else {
            print(String(format: "GPU, execution:             MET. Worst p50 is %.1f ms.", worstGPUAt100k))
        }
        print("")

        // Asserted only in a release build: a -Onone build measures the compiler, not the
        // renderer, and asserting a release budget on it would either fail permanently or force
        // the budget up for everyone. The figures are printed in both configurations.
        if isReleaseBuild {
            #expect(met60fpsAt100k, "the 16.6 ms frame budget was missed at 100 000 markups")
            // GPU execution became an assertion on 2026-08-26, when the render pass split took the
            // worst cell in the corpus from 72 ms to 7.3 ms. It was *reported and not asserted* for
            // as long as the renderer missed it, because lowering the bar to make the suite green
            // would have been the wrong repair — but a measurement that has become a guarantee and
            // is still only printed is how a regression ships unnoticed, and this repository has
            // shipped seven of those.
            //
            // The bar is the real one, 16.6 ms, not the measured figure with a little headroom.
            // Five isolated release runs measured the worst cell at 6.251–7.793 ms while a second
            // build was running in the same tree at load average 5.7–17.3, so a failure here is
            // very unlikely to be contention — but a loaded machine is still the first thing to
            // rule out before reading it as a code regression.
            #expect(
                worstGPUAt100k <= 16.6,
                "GPU execution p50 \(worstGPUAt100k) ms at 100 000 markups, zoom \(worstGPUZoom), missed the 16.6 ms budget"
            )
        }
    }

    /// What each of the two render-pass changes is worth, measured apart from the other.
    ///
    /// # Why the sweep exists and why it is three configurations rather than two
    ///
    /// Batching by material was once assumed to be the lever, was
    /// implemented, and was worth **nothing** — four draw calls at 200 markups and four at 50 000.
    /// The lesson it draws is that a change to submission and a change to shading must be measured
    /// separately or neither is measurable. The render-pass split carries two changes with the same
    /// relationship: the frame **splits** into a multisampled fill pass and a single-sample ink
    /// pass, and, because the ink pass has one sample at the pixel centre, the segment quad's
    /// antialiasing **pad** narrows from 1.0 to 0.5 device pixels. The first changes how many
    /// samples each fragment is blended into; the second changes how many fragments there are.
    /// They are separable and here they are separated.
    ///
    /// Fewer frames than the verdict test above — the point is a ratio between configurations
    /// measured back to back on one machine, not an absolute p50 to hold a budget to. The absolute
    /// numbers that count are the ones the verdict test prints.
    @Test("What the render pass split and the narrower quad pad are each worth")
    func renderPassSplitSweep() throws {
        let renderer = try makeMetal()
        defer { renderer.dispose() }
        let frames = 48
        let configurations: [(String, RenderPassPolicy)] = [
            ("one pass, 4x, 1.0 px pad", .singlePass),
            ("split, 4x fills, 1.0 px pad", .splitPassWideQuad),
            ("split, 4x fills, 0.5 px pad", .default)
        ]

        print("")
        print("=== ZPDFRenderer benchmark: render pass configurations, GPU p50 milliseconds ===")
        print("build: \(isReleaseBuild ? "release" : "debug — ratios are indicative, absolutes are not")")
        print("device: \(renderer.deviceName), \(renderer.sampleCount)x multisampling, \(frames) frames per cell")
        func column(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        print(
            column("  markups", 10) + column("  zoom", 8)
                + column("one pass 4x", 24)
                + column("split, wide pad", 24)
                + column("split, narrow pad (shipping)", 24)
        )

        for markupCount in [1_000, 10_000, 50_000, 100_000] {
            let scene = SceneLibrary.stress(count: markupCount)
            for zoom in Self.zoomLevels {
                let target = viewport(scene.page, zoom: zoom)
                var measured: [Double] = []
                for (_, policy) in configurations {
                    renderer.renderPassPolicy = policy
                    measured.append(gpuP50(renderer: renderer, scene: scene, viewport: target, frames: frames))
                }
                let baseline = measured[0]
                func cell(_ value: Double) -> String {
                    guard baseline > 0 else { return String(format: "%8.3f", value) }
                    return String(format: "%8.3f  (%.2fx)", value, baseline / Swift.max(value, 1e-9))
                }
                print(
                    column(String(format: "%9d", markupCount), 10)
                        + column(String(format: "%6.2f", zoom), 8)
                        + column(String(format: "%8.3f", baseline), 24)
                        + column(cell(measured[1]), 24)
                        + column(cell(measured[2]), 24)
                )
                // Not a budget — a guard against the sweep silently measuring nothing. A cell
                // that produced no GPU sample at all would print 0.000 and look like a triumph.
                for value in measured {
                    #expect(value > 0, "\(markupCount) markups, zoom \(zoom): no GPU sample was taken")
                }
            }
        }
        renderer.renderPassPolicy = .default
        print("")
    }

    /// GPU p50 over `frames` steady-state frames of a scene, the viewport panning by a pixel each
    /// time, waiting on every fourth command buffer so the figure is measured and not inferred.
    private func gpuP50(
        renderer: MetalMarkupRenderer,
        scene: (page: PageDescriptor, markups: [RenderableMarkup]),
        viewport: RenderViewport,
        frames: Int
    ) -> Double {
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        var samples: [Double] = []
        for frame in 0..<frames {
            var panned = viewport
            panned.layout.anchor = CGPoint(x: Double(frame % 40) * -1, y: 0)
            renderer.update(
                page: scene.page,
                markups: scene.markups,
                selection: .empty,
                snapFeedback: nil,
                viewport: panned
            )
            let commandBuffer = try? renderer.encodeFrame()
            if frame % 4 == 0, let commandBuffer {
                commandBuffer.waitUntilCompleted()
                let gpu = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
                if gpu > 0 { samples.append(gpu) }
            }
        }
        return LatencySummary(name: "", samples: samples).p50
    }

    @Test("Moving one markup in a 100 000-markup scene costs a fraction of a full rebuild")
    func incrementalUpdate() throws {
        let renderer = try makeMetal()
        defer { renderer.dispose() }
        let scene = SceneLibrary.stress(count: 100_000)
        let viewport = viewport(scene.page, zoom: 1.0)

        // A full rebuild: every markup's revision has changed, so every slot is rewritten.
        var bumped = scene.markups
        for index in bumped.indices { bumped[index].revision = 1 }
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )
        let fullRebuild = measureMilliseconds {
            renderer.update(
                page: scene.page,
                markups: bumped,
                selection: .empty,
                snapFeedback: nil,
                viewport: viewport
            )
        }
        let fullStatistics = renderer.statistics

        // One markup moves. Dragging is a stream of these, sixty times a second.
        var samples: [Double] = []
        var dirtySlots = 0
        var uploadedBytes = 0
        for step in 0..<60 {
            var moved = bumped
            let index = 50_000
            moved[index].revision = UInt64(2 + step)
            if case let .polyline(line) = moved[index].shape {
                moved[index].shape = .polyline(RenderPolyline(
                    points: line.points.map { PDFPoint(x: $0.x + 0.25, y: $0.y + 0.25) },
                    isClosed: line.isClosed
                ))
            }
            let elapsed = measureMilliseconds {
                renderer.update(
                    page: scene.page,
                    markups: moved,
                    selection: .empty,
                    snapFeedback: nil,
                    viewport: viewport
                )
            }
            samples.append(elapsed)
            dirtySlots = renderer.statistics.dirtySlotCount
            uploadedBytes = renderer.statistics.uploadedByteCount
            bumped = moved
        }
        let incremental = LatencySummary(name: "one markup moved in 100 000", samples: samples)

        print("")
        print("=== ZPDFRenderer benchmark: incremental update ===")
        print(String(format: "full rebuild                     %10.3f ms, %d slots, %.2f MB uploaded",
                     fullRebuild, fullStatistics.dirtySlotCount,
                     Double(fullStatistics.uploadedByteCount) / 1_048_576))
        print(incremental.line)
        print(String(format: "one markup moved                 %10.3f ms (p50), %d slots, %d bytes uploaded",
                     incremental.p50, dirtySlots, uploadedBytes))
        let timeRatio = fullRebuild / Swift.max(incremental.p50, 1e-9)
        let byteRatio = Double(fullStatistics.uploadedByteCount) / Double(Swift.max(uploadedBytes, 1))
        print(String(format: "ratio: %.1fx less time, %.0fx fewer bytes uploaded", timeRatio, byteRatio))
        print("")

        #expect(dirtySlots <= 2, "moving one markup dirtied \(dirtySlots) slots")
        #expect(byteRatio > 1_000, "one markup uploaded 1/\(Int(byteRatio)) of a full rebuild, expected far less")
        #expect(timeRatio > 5, "incremental update was only \(timeRatio)x faster than a full rebuild")
    }

    @Test("Hover and selection changes never touch the geometry buffers")
    func overlayIsIsolated() throws {
        let renderer = try makeMetal()
        defer { renderer.dispose() }
        let scene = SceneLibrary.stress(count: 100_000)
        let viewport = viewport(scene.page, zoom: 1.0)
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport
        )

        var samples: [Double] = []
        for step in 0..<120 {
            let hovered = scene.markups[step * 37 % scene.markups.count].id
            let selection = SelectionSnapshot(
                selectedIDs: [hovered],
                primaryID: hovered,
                hoveredID: scene.markups[(step * 53 + 11) % scene.markups.count].id
            )
            let feedback = RenderSnapFeedback(
                point: PDFPoint(x: Double(step), y: Double(step)),
                glyph: .cross,
                guide: .segment(from: PDFPoint(x: 0, y: 0), to: PDFPoint(x: Double(step), y: 100))
            )
            let elapsed = measureMilliseconds {
                renderer.update(
                    page: scene.page,
                    markups: scene.markups,
                    selection: selection,
                    snapFeedback: feedback,
                    viewport: viewport
                )
            }
            samples.append(elapsed)
            #expect(renderer.statistics.dirtySlotCount == 0, "a hover dirtied a geometry slot")
            #expect(renderer.statistics.uploadedByteCount == 0, "a hover uploaded geometry bytes")
        }
        let summary = LatencySummary(name: "hover + selection + snap, 100 000 markups: frame build", samples: samples)
        print("")
        print("=== ZPDFRenderer benchmark: overlay-only frame ===")
        print(summary.line)
        print("")
        #expect(
            summary.p99 < Self.frameBudgetMilliseconds,
            "an overlay-only frame missed the \(Self.frameBudgetMilliseconds) ms budget"
        )
    }

    @Test("Peak buffer memory at 100 000 markups is reported")
    func memoryAt100k() throws {
        let before = residentMemoryBytes()
        let renderer = try makeMetal()
        defer { renderer.dispose() }
        let scene = SceneLibrary.stress(count: 100_000)
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport(scene.page, zoom: 1.0)
        )
        _ = try renderer.encodeFrame()
        let statistics = renderer.statistics
        let after = residentMemoryBytes()

        print("")
        print("=== ZPDFRenderer benchmark: memory at 100 000 markups ===")
        print(String(format: "GPU instance + atlas + target bytes  %10.2f MB",
                     Double(statistics.residentByteCount) / 1_048_576))
        print(String(format: "  line instances   %8d  (%6.2f MB)",
                     statistics.lineInstanceCount,
                     Double(statistics.lineInstanceCount * MetalInstanceLayout.segmentStride) / 1_048_576))
        print(String(format: "  triangles        %8d  (%6.2f MB)",
                     statistics.triangleCount,
                     Double(statistics.triangleCount * 3 * MetalInstanceLayout.triangleVertexStride) / 1_048_576))
        print(String(format: "  symbols          %8d  (%6.2f MB)",
                     statistics.symbolInstanceCount,
                     Double(statistics.symbolInstanceCount * MetalInstanceLayout.symbolStride) / 1_048_576))
        print(String(format: "  glyphs           %8d  (%6.2f MB)",
                     statistics.glyphInstanceCount,
                     Double(statistics.glyphInstanceCount * MetalInstanceLayout.glyphStride) / 1_048_576))
        if let before, let after {
            print(String(format: "process resident delta               %10.2f MB (%0.2f -> %0.2f MB)",
                         Double(after - before) / 1_048_576,
                         Double(before) / 1_048_576,
                         Double(after) / 1_048_576))
        }
        print(String(format: "markups accepted %d, rejected %d",
                     statistics.markupCount, statistics.rejectedMarkupCount))
        print("")

        #expect(statistics.markupCount == 100_000)
        #expect(statistics.rejectedMarkupCount == 0)
        #expect(statistics.residentByteCount > 0)
        // A page's instance storage must stay well inside the 1.5 GB process budget of
        // `QUALITY_BAR` 4.7, which the ledger also has to fit inside.
        #expect(statistics.residentByteCount < 512 * 1_048_576)
    }

    @Test("The Core Graphics fallback's cost at the same sizes is measured, not guessed")
    func coreGraphicsBaseline() throws {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        print("")
        print("=== ZPDFRenderer benchmark: Core Graphics fallback, same scenes ===")
        for markupCount in [10_000, 100_000] {
            let scene = SceneLibrary.stress(count: markupCount)
            let viewport = viewport(scene.page, zoom: 1.0)
            let cold = measureMilliseconds {
                renderer.update(
                    page: scene.page,
                    markups: scene.markups,
                    selection: .empty,
                    snapFeedback: nil,
                    viewport: viewport
                )
            }
            var samples: [Double] = []
            for frame in 0..<10 {
                var panned = viewport
                panned.layout.anchor = CGPoint(x: Double(frame) * -1, y: 0)
                samples.append(measureMilliseconds {
                    renderer.update(
                        page: scene.page,
                        markups: scene.markups,
                        selection: .empty,
                        snapFeedback: nil,
                        viewport: panned
                    )
                })
            }
            let rasterize = measureMilliseconds { _ = try? renderer.renderOffscreen() }
            print(LatencySummary(name: "\(markupCount) markups: CG scene update", samples: samples).line)
            print(String(format: "  cold build %8.3f ms | full raster %8.3f ms", cold, rasterize))
            #expect(renderer.statistics.markupCount == markupCount)
        }
        print("")
    }

    @Test("Hit testing a 100 000-markup page stays inside a frame")
    func hitTestLatency() throws {
        let renderer = try makeMetal()
        defer { renderer.dispose() }
        let scene = SceneLibrary.stress(count: 100_000)
        renderer.update(
            page: scene.page,
            markups: scene.markups,
            selection: .empty,
            snapFeedback: nil,
            viewport: viewport(scene.page, zoom: 1.0)
        )
        var random = DeterministicRandom(seed: 0xA11CE)
        var samples: [Double] = []
        for _ in 0..<2_000 {
            let point = CGPoint(x: random.double(0, 612), y: random.double(0, 792))
            samples.append(measureMilliseconds {
                _ = renderer.hitTest(pagePoint: point, toleranceInPagePoints: 3)
            })
        }
        let summary = LatencySummary(name: "hit test, 100 000 markups", samples: samples)
        print("")
        print("=== ZPDFRenderer benchmark: hit test ===")
        print(summary.line)
        print("")
        #expect(summary.count == 2_000)
        // Debug hit testing measured 36.1 ms p99 at 100 000 markups on this machine; the debug
        // budget is above that with headroom but still catches an order-of-magnitude slide.
        #expect(
            summary.p99 < Self.frameBudgetMilliseconds,
            "hit testing missed the \(Self.frameBudgetMilliseconds) ms budget"
        )
    }
}
