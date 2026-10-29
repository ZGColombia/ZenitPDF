import Foundation

/// How a frame is divided between render passes, and therefore which of its ink is multisampled.
///
/// # Why this is a policy and not a constant
///
/// Multisampling is not free and it is not uniformly useful. A **polygon fill** has no analytic
/// coverage: the rasteriser decides where its edge is, and with one sample per pixel that edge is
/// a staircase that differs from the Core Graphics oracle by up to half a level of alpha along
/// every diagonal. Fills need their samples (eight where the device has them; see `MetalRuntime`).
///
/// A **stroke** does not. `segment_fragment` computes the exact box-filter coverage of the ink and
/// writes it to every sample the rasteriser marked; multisampling adds nothing to the picture and
/// multiplies the pass's per-sample rasterisation and blending by the sample count. At 5 % zoom, where every
/// segment quad is about two device pixels across and three hundred thousand of them land in a
/// handful of tiles, that multiplier is the frame. The same is true of the atlas quads: a glyph
/// quad is snapped to whole pixels by `glyph_vertex`, so its edges never cut a pixel at all, and a
/// symbol quad's border is the atlas's transparent margin, which `atlas_fragment` discards.
///
/// A pipeline state's sample count is baked in at creation and an attachment's sample count is a
/// property of the attachment, so "some of this frame is multisampled and some is not" cannot be
/// expressed inside one render pass. It needs two, and that is what this policy selects.
///
/// # Why splitting the pass does not change the picture
///
/// One multisampled pass computes, for a pixel the fills partly cover and a stroke fully covers:
/// `mean_i(s·a + d_i·(1 − a))`, where `a` is the stroke's analytic coverage — one value per
/// fragment, written to every sample — and `d_i` is the fill's per-sample result. Two passes
/// compute `s·a + mean_i(d_i)·(1 − a)`. Those are the same number, because `a` does not vary with
/// `i`: the mean commutes with a blend whose source is constant across samples.
///
/// The one thing that would break the equality is a stroke quad whose *edge* cuts through a pixel
/// it has inked, because then the two passes disagree about which samples are covered. They cannot:
/// the quad carries a pad, sized in `segment_vertex` so that every partially inked pixel is wholly
/// inside it. That pad is what ``segmentQuadPadPixels`` reports, and it is smaller in the split
/// configuration precisely because a single-sample pass only has to contain each inked pixel's
/// *centre* rather than all of its samples.
public struct RenderPassPolicy: Sendable, Hashable {

    /// `true` draws fills into the multisample target and everything else — strokes, symbols,
    /// glyphs and the overlay — into a second, single-sample pass over the resolved target.
    ///
    /// `false` is the original single-pass frame: one attachment, one sample count, everything
    /// multisampled. Kept so the benchmark can measure the split's win against it in the same
    /// process rather than across two builds, and so a device with no multisampling at all has a
    /// name for what it is doing.
    public var splitsInkPass: Bool

    /// Whether the narrower segment-quad pad is also in force. Only meaningful when
    /// ``splitsInkPass``; see ``segmentQuadPadPixels``.
    public var shrinksSegmentPad: Bool

    public init(splitsInkPass: Bool = true, shrinksSegmentPad: Bool = true) {
        self.splitsInkPass = splitsInkPass
        self.shrinksSegmentPad = shrinksSegmentPad
    }

    /// Fills multisampled, ink in its own single-sample pass.
    public static let `default` = RenderPassPolicy(splitsInkPass: true)
    /// One pass, everything multisampled — the frame as it was before the split existed.
    public static let singlePass = RenderPassPolicy(splitsInkPass: false)

    /// How far a segment's quad is grown beyond its ink, in device pixels.
    ///
    /// `segment_fragment` box-filters over the fragment's own unit square, so coverage is exactly
    /// zero more than half a pixel outside the ink. The quad must nevertheless be big enough that
    /// **every** rasterisation sample of every partially inked pixel falls inside it, or the
    /// rasteriser multiplies the analytic coverage by a sample fraction a second time and thin ink
    /// comes out light.
    ///
    /// - In a **multisampled** pass that means containing every sample of such a pixel, which
    ///   needs `0.5 + 0.5·(|dx| + |dy|) ≤ 1.03` px in the segment's frame. One pixel is that, near
    ///   enough, and it is what the goldens were measured at. Padding to 0.5 was tried there and
    ///   measured: the outermost row of a 5 %-zoom hairline lost a quarter of its ink and
    ///   `dashes-and-caps-zoom-005` came out 7.5 % light.
    /// - In a **single-sample** pass there is one sample, at the pixel centre, and the fragment is
    ///   generated only if that centre is inside the quad. Coverage is nonzero only where the
    ///   centre is within half a pixel of the ink in the segment's frame, so 0.5 px is exactly the
    ///   requirement and any excess is wasted rasterisation. ``inkPassPad`` is that half pixel plus
    ///   a float-comparison hair, so a centre exactly on the boundary is still shaded.
    ///
    /// This is a *separate* change from the split and is measured separately: the split alone runs
    /// with `multisampledPad` and the benchmark reports both.
    public static let multisampledPad = 1.0
    /// See ``multisampledPad``.
    public static let inkPassPad = 0.5 + 1.0 / 512.0

    /// The pad this policy asks `segment_vertex` for, in device pixels.
    public var segmentQuadPadPixels: Double {
        splitsInkPass && shrinksSegmentPad ? Self.inkPassPad : Self.multisampledPad
    }

    /// The split without the narrower pad, so the benchmark can attribute the two wins apart.
    public static let splitPassWideQuad = RenderPassPolicy(
        splitsInkPass: true,
        shrinksSegmentPad: false
    )
}
