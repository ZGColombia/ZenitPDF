import Foundation
import Testing
import ZPDFRenderer
import ZPDFRendererScenario

/// What splitting the frame into a multisampled fill pass and a single-sample ink pass is allowed
/// to change about the picture, measured rather than argued.
///
/// # Why this suite exists, and why the stored goldens are not enough on their own
///
/// The stored goldens are rendered through the **default** policy, so once the split is the
/// default they compare the split renderer against Core Graphics and say nothing at all about the
/// single-pass renderer they used to compare. A change that moved both away from Core Graphics by
/// the same amount would still be green. The rule this suite obeys: *a change the goldens cannot
/// see is not automatically invisible to a user.*
///
/// So the comparison here is **configuration against configuration on the same machine**, over the
/// scenes built to expose stroke coverage, and it is held to `StrokeCoverageTests`' budgets rather
/// than `ImageComparator`'s general-purpose ones — the general budget (0.5 % of pixels, 0.025 per
/// tile, 2 % ink) is loose enough to hide everything this change could plausibly break.
///
/// # The two changes, separated
///
/// The split carries a second change with it: the segment quad's antialiasing pad drops from 1.0
/// to 0.5 device pixels, because a single-sample pass only has to contain each inked pixel's
/// centre rather than all four of its samples. Those are different changes with different failure
/// modes — one is about where samples land, the other about how much is rasterised — so
/// ``RenderPassPolicy/splitPassWideQuad`` exists to hold the pad still while the pass splits, and
/// the two tests below measure them apart. Conflating them would make both unmeasurable, which is
/// the mistake item 1 records about batching and shading.
///
/// # What "invisible" is being claimed to mean
///
/// The same three budgets `StrokeCoverageTests` states, for the same reasons:
///
/// - **worst 16×16-tile mean coverage difference ≤ 0.012.** No *region* of the picture may change.
///   A stroke that lost its outermost row of ink, a cap drawn at the wrong radius, or an edge
///   shifted by half a pixel all move a tile by more than this. This is the budget the 0.5 px pad
///   failed by a wide margin when it was tried on a *multisampled* attachment: the outermost row
///   of a 5 %-zoom hairline lost a quarter of its ink.
/// - **perceptibly differing pixels ≤ 0.02 %**, where "perceptible" is a 3×3-blurred channel
///   difference over 8 %. No visible edge may move.
/// - **total ink within 0.8 %.** Catches a systematic bias too small to fail either of the others
///   but present on every edge — which is exactly the shape a pad error takes.
///
/// Individual edge pixels may still differ, and do: the two configurations resolve a stroke's own
/// quad boundary differently in principle, and floating-point blending is not associative. What
/// may not differ is a region, an edge position, or the total.
@Suite("Render pass split", .serialized)
struct RenderPassSplitTests {

    /// The scenes whose whole purpose is to police stroke coverage, plus the two that carry the
    /// atlas quads the split also moves out of the multisampled pass, plus the two zoom extremes
    /// where a pad error shows first.
    static let scenes = [
        "stroke-angles",
        "dash-angles",
        "round-caps-and-corners",
        "translucent-overlap",
        "count-symbols",
        "text-three-sizes",
        "dashes-and-caps-zoom-005",
        "dashes-and-caps-zoom-800",
        "retina-hairlines",
        "mixed-200"
    ]

    static let tileBudget = 0.012
    static let differingPixelBudget = 0.0002
    static let inkBudget = 0.008

    private static func render(
        _ scene: RenderScene,
        policy: RenderPassPolicy
    ) throws -> RasterImage {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        renderer.renderPassPolicy = policy
        return try scene.render(with: renderer)
    }

    /// The premise the rest of the suite rests on: this machine really is taking the split path.
    /// Without this, every comparison below could be a configuration against itself.
    @Test("The frame really is split into two passes on this device")
    func theSplitIsActuallyTaken() throws {
        let renderer = try MetalMarkupRenderer()
        defer { renderer.dispose() }
        print("render pass split | device \(renderer.deviceName), \(renderer.sampleCount)x multisampling")
        #expect(
            renderer.sampleCount > 1,
            "this device offers no multisampling, so there is nothing to split and every comparison in this suite is vacuous"
        )
        renderer.renderPassPolicy = .default
        #expect(renderer.requiresSeparateInkPass, "the default policy did not ask for the split")
        renderer.renderPassPolicy = .splitPassWideQuad
        #expect(renderer.requiresSeparateInkPass)
        renderer.renderPassPolicy = .singlePass
        #expect(!renderer.requiresSeparateInkPass, "the single-pass policy asked for a split")
    }

    /// Change one: the pass splits, the pad does not move.
    @Test("Splitting the pass alone changes no region, no edge and no total")
    func splitAloneIsInvisible() throws {
        try compare(
            "split, pad held at 1.0 px",
            RenderPassPolicy.splitPassWideQuad,
            against: .singlePass
        )
    }

    /// Change two, on top of change one: the pad narrows to half a pixel, which is what the
    /// single-sample attachment makes correct and which is where the rasterisation saving is.
    @Test("Narrowing the segment pad to half a pixel changes no region, no edge and no total")
    func narrowPadIsInvisible() throws {
        try compare(
            "split + 0.5 px pad",
            RenderPassPolicy.default,
            against: .splitPassWideQuad
        )
    }

    /// And the end-to-end statement: the shipping configuration against the one the stored
    /// goldens were originally measured with.
    @Test("The shipping configuration matches the single-pass frame it replaced")
    func shippingConfigurationMatchesSinglePass() throws {
        try compare("shipping", RenderPassPolicy.default, against: .singlePass)
    }

    private func compare(
        _ label: String,
        _ policy: RenderPassPolicy,
        against baseline: RenderPassPolicy
    ) throws {
        var checked = 0
        var worstTile = 0.0
        var worstDiffering = 0.0
        var worstInk = 0.0
        for name in Self.scenes {
            let scene = try #require(SceneLibrary.golden(named: name), "no scene \(name)")
            let reference = try Self.render(scene, policy: baseline)
            let subject = try Self.render(scene, policy: policy)
            let result = ImageComparator.compare(subject, reference)
            print(String(
                format: "%-22s | %-26s tileΔ %.4f  differing %.4f%%  inkΔ %.4f%%  maxΔ %.3f",
                (label as NSString).utf8String ?? "",
                (name as NSString).utf8String ?? "",
                result.maximumTileCoverageDifference,
                result.differingPixelFraction * 100,
                abs(result.inkRatio - 1) * 100,
                result.maximumChannelDifference
            ))
            worstTile = Swift.max(worstTile, result.maximumTileCoverageDifference)
            worstDiffering = Swift.max(worstDiffering, result.differingPixelFraction)
            worstInk = Swift.max(worstInk, abs(result.inkRatio - 1))
            #expect(
                result.maximumTileCoverageDifference <= Self.tileBudget,
                "\(label)/\(name): tile coverage difference \(result.maximumTileCoverageDifference) over \(Self.tileBudget)"
            )
            #expect(
                result.differingPixelFraction <= Self.differingPixelBudget,
                "\(label)/\(name): \(result.differingPixelFraction * 100)% of pixels differ perceptibly, over \(Self.differingPixelBudget * 100)%"
            )
            #expect(
                abs(result.inkRatio - 1) <= Self.inkBudget,
                "\(label)/\(name): total ink ratio \(result.inkRatio) outside 1 ± \(Self.inkBudget)"
            )
            checked += 1
        }
        print(String(
            format: "%-22s | worst across %d scenes: tileΔ %.4f  differing %.4f%%  inkΔ %.4f%%",
            (label as NSString).utf8String ?? "", checked, worstTile, worstDiffering * 100, worstInk * 100
        ))
        #expect(checked == Self.scenes.count)
    }

    /// The split must not cost draw calls or pipeline binds. It cannot in principle — each
    /// material is still bound once and drawn once, the cut simply falls between two of them —
    /// and this asserts it rather than trusting the argument, because `MaterialBatchingTests`
    /// measures the single-encoder path and would not notice.
    @Test("Splitting the pass costs no extra draw call and no extra pipeline bind")
    func splitCostsNoStateChanges() throws {
        let scene = try #require(SceneLibrary.golden(named: "mixed-200"))
        var counts: [(String, Int, Int)] = []
        for (label, policy) in [
            ("single pass", RenderPassPolicy.singlePass),
            ("split", RenderPassPolicy.default)
        ] {
            let renderer = try MetalMarkupRenderer()
            defer { renderer.dispose() }
            renderer.renderPassPolicy = policy
            _ = try scene.render(with: renderer)
            let statistics = renderer.statistics
            print("render pass split | \(label): \(statistics.drawCallCount) draw calls, \(statistics.pipelineStateChangeCount) pipeline binds")
            counts.append((label, statistics.drawCallCount, statistics.pipelineStateChangeCount))
        }
        #expect(counts.count == 2)
        #expect(counts[0].1 > 0, "the single-pass frame issued no draw calls at all")
        #expect(counts[0].1 == counts[1].1, "the split changed the draw call count")
        #expect(counts[0].2 == counts[1].2, "the split changed the pipeline bind count")
    }
}
