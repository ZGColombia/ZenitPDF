import Foundation

/// The Metal shading language source, compiled at runtime.
///
/// # Why runtime compilation
///
/// A `.metal` file in a SwiftPM target is compiled by the build system into a `default.metallib`
/// inside a resource bundle, and finding that bundle at runtime differs between a test binary, a
/// command line tool and an app bundle. Compiling from source with `makeLibrary(source:options:)`
/// removes the bundle from the picture entirely, costs a few milliseconds once per process, and —
/// the reason that actually decides it — makes **shader compilation failure a runtime condition
/// the fallback path can be tested against**. `MetalRuntimeFailureInjection` corrupts this string
/// and the factory is required to come back with a working Core Graphics renderer and a logged
/// reason. A shader baked into a metallib at build time cannot fail that way, so the degradation
/// path would ship untested.
///
/// # What the shaders implement
///
/// - `segment_vertex` / `segment_fragment`: one instanced quad per segment, expanded in **pixel**
///   space so the minimum-width floor is applied after the transform, with analytic antialiasing
///   and a dash evaluated along the segment. The dash scale is the same two lines as
///   `DashPattern.deviceScale(pixelsPerPagePoint:)` — that duplication is deliberate and is what
///   the dashed golden scenes exist to police.
/// - `triangle_vertex` / `triangle_fragment`: the cached triangulation of a filled polygon.
/// - `symbol_vertex` / `atlas_fragment`: count markers sampled from the symbol atlas.
/// - `glyph_vertex` / `atlas_fragment`: text sampled from the glyph atlas.
/// - `*_fragment_multiply`: the same ink, blended multiplicatively for a highlighter
///   (`RenderBlendMode.multiply`) through dual-source blending; see `MultiplyOutput`.
///
/// A dead instance — one whose slot has been freed but not yet compacted — is sent outside the
/// clip volume by the vertex stage rather than left in the buffer as stale geometry.
public enum MetalShaderSource {

    public static let library: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant uint CAP_BUTT   = 0u;
    constant uint CAP_ROUND  = 1u;
    constant uint CAP_SQUARE = 2u;
    constant uint FLAG_DEAD  = 256u;
    // Stroke coverage is computed analytically; see `segment_fragment`. The one number left is
    // how many horizontal strips the pixel is cut into, which exists only so a round cap's reach
    // can vary across the pixel. Four is what the 4x4 quadrature this replaced used across, so
    // no cap is resolved more coarsely than it was before.
    constant uint SEGMENT_STRIPS = 4u;
    // DashPattern.dotRunFraction, interpolated so the two cannot drift apart.
    constant float DOT_RUN_FRACTION = \#(DashPattern.dotRunFraction);

    struct FrameUniforms {
        float4 matrix;                  // a, b, c, d
        float4 translationAndViewport;  // tx, ty, width, height
        float4 strokeParameters;        // pixelsPerPagePoint, minPx, maxPx, backingScale
        float4 dashParameters;          // dashMinimumRunPixels, segmentQuadPadPixels, unused
    };

    struct SegmentInstance {
        float4 dashRuns;
        float2 p0;
        float2 p1;
        float  width;
        float  dashOffset;
        uint   color;
        uint   flags;
    };

    struct TriangleVertexIn {
        float2 position;
        uint   color;
        uint   flags;
    };

    struct SymbolInstance {
        float4 uv;
        float2 center;
        float  sizePagePoints;
        float  sizeViewPoints;
        uint   color;
        uint   flags;
        float  rotation;
        uint   pad1;
    };

    struct GlyphInstance {
        float4 uv;
        float2 anchor;
        float2 offset;
        float2 size;
        uint   color;
        uint   flags;
    };

    static inline float4 unpackColor(uint packed) {
        return float4(
            float((packed >>  0u) & 0xFFu) / 255.0,
            float((packed >>  8u) & 0xFFu) / 255.0,
            float((packed >> 16u) & 0xFFu) / 255.0,
            float((packed >> 24u) & 0xFFu) / 255.0
        );
    }

    static inline float2 pageToPixel(float2 page, constant FrameUniforms &u) {
        return float2(
            u.matrix.x * page.x + u.matrix.z * page.y + u.translationAndViewport.x,
            u.matrix.y * page.x + u.matrix.w * page.y + u.translationAndViewport.y
        );
    }

    static inline float4 pixelToClip(float2 pixel, constant FrameUniforms &u) {
        float2 size = u.translationAndViewport.zw;
        return float4(
            (pixel.x / size.x) * 2.0 - 1.0,
            1.0 - (pixel.y / size.y) * 2.0,
            0.0,
            1.0
        );
    }

    // The one place off the clip volume that a dead or degenerate instance is sent.
    static inline float4 offscreen() { return float4(4.0, 4.0, 0.0, 1.0); }

    // ------------------------------------------------------------ multiply blend
    //
    // A highlighter (`RenderBlendMode.multiply`) multiplies with what is under it. Core Graphics'
    // `.multiply`, which the reference backend and every PDF export use, is the separable PDF
    // blend, and in premultiplied terms it is
    //
    //     result = Cs·(1 − αd) + Cd·(1 − αs) + Cs·Cd
    //
    // The fixed-function blender computes `S0·Fs + D·Fd`. Regrouping gives
    // `Cs·(1 − αd) + Cd·(Cs + 1 − αs)`, so the pipeline takes `Fs = 1 − αd`
    // (oneMinusDestinationAlpha) and a per-channel `Fd` supplied by the shader as the second
    // blend source (`Cs + 1 − αs`, dual-source blending). Over opaque paper the first term
    // vanishes and this is plain `Cs·Cd`; over a transparent target it is the ink itself, which
    // is what Core Graphics draws there too. Alpha composes source-over, as it does in CG.
    struct MultiplyOutput {
        float4 color  [[color(0), index(0)]];
        float4 factor [[color(0), index(1)]];
    };

    static inline MultiplyOutput multiplied(float4 ink) {
        MultiplyOutput out;
        out.color = ink;
        out.factor = float4(ink.rgb + (1.0 - ink.a), 1.0);
        return out;
    }

    // ------------------------------------------------------------------ segments

    struct SegmentVaryings {
        float4 position [[position]];
        float2 local;          // along, across, in device pixels from p0
        float  segmentLength;  // in device pixels
        float  halfWidth;      // in device pixels
        float4 color;
        float4 dashRunsPixels;
        float  dashPhasePixels;
        uint   flags;
    };

    // `visible` is the submission list: an array of instance indices, either the identity
    // (no culling) or the storage indices of the markups the CPU-side culler kept. One level
    // of indirection lets the persistent arenas stay untouched across a viewport change while
    // the draw covers exactly the visible subset.
    vertex SegmentVaryings segment_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device SegmentInstance *instances [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]],
        const device uint *visible [[buffer(2)]]
    ) {
        SegmentVaryings out;
        SegmentInstance s = instances[visible[instanceID]];
        if ((s.flags & FLAG_DEAD) != 0u) {
            out.position = offscreen();
            out.local = float2(0.0);
            out.segmentLength = 0.0;
            out.halfWidth = 0.0;
            out.color = float4(0.0);
            out.dashRunsPixels = float4(0.0);
            out.dashPhasePixels = 0.0;
            out.flags = FLAG_DEAD;
            return out;
        }

        float2 a = pageToPixel(s.p0, u);
        float2 b = pageToPixel(s.p1, u);

        float pixelsPerPagePoint = u.strokeParameters.x;
        float widthPixels = clamp(s.width * pixelsPerPagePoint,
                                  u.strokeParameters.y,
                                  u.strokeParameters.z);
        float halfWidth = widthPixels * 0.5;

        float2 delta = b - a;
        float length2 = dot(delta, delta);
        float segmentLength = sqrt(max(length2, 0.0));
        float2 direction = segmentLength > 0.0 ? delta / segmentLength : float2(1.0, 0.0);
        float2 normal = float2(-direction.y, direction.x);

        // Core Graphics draws no cap at all on a stroke of one device pixel or less — it takes a
        // thin-line path — and this renderer is required to agree with it, so the same rule is
        // applied here rather than left as a difference the golden suite would have to tolerate.
        uint startCap = (halfWidth <= 0.5) ? CAP_BUTT : (s.flags & 3u);
        uint endCap = (halfWidth <= 0.5) ? CAP_BUTT : ((s.flags >> 2u) & 3u);
        float startExtension = (startCap == CAP_BUTT) ? 0.0 : halfWidth;
        float endExtension = (endCap == CAP_BUTT) ? 0.0 : halfWidth;

        // How far the quad reaches beyond the ink. This looks like slack — `segment_fragment`
        // box-filters over the fragment's own unit square, so coverage is already exactly zero
        // half a pixel outside the ink — and whether it is depends on the attachment, which is
        // why the number arrives in the uniform block instead of standing here as a constant.
        //
        // On a **multisampled** attachment a fragment shader writes its result only to the
        // samples the rasteriser marked covered, so a quad edge cutting through a partially inked
        // pixel multiplies the analytic coverage by the sample fraction a second time. Padding to
        // 0.5 was tried there and measured: the outermost row of a 5 %-zoom hairline lost a
        // quarter of its ink and `dashes-and-caps-zoom-005` came out 7.5 % light against Core
        // Graphics. The pad has to keep every sample of every partially inked pixel inside the
        // quad, which needs 0.5 + 0.5·(|dx| + |dy|) ≤ 1.03 px, and one pixel is that.
        //
        // On a **single-sample** attachment there is one sample, at the pixel centre, and the
        // fragment exists only if that centre is inside the quad. Coverage is nonzero only where
        // the centre is within half a pixel of the ink, so half a pixel is the exact requirement
        // and the other half is rasterisation nobody reads. `RenderPassPolicy` chooses; see the
        // derivation there.
        // Zero means "not supplied" — an older uniform block, or a caller that never set the
        // policy — and the honest fallback is the wide pad, which is correct on either attachment
        // and only costs rasterisation.
        float pad = (u.dashParameters.y > 0.0) ? u.dashParameters.y : 1.0;
        float alongOffset = (vertexID == 0u || vertexID == 1u)
            ? -(startExtension + pad)
            : (segmentLength + endExtension + pad);
        float acrossOffset = (vertexID == 0u || vertexID == 2u)
            ? -(halfWidth + pad)
            : (halfWidth + pad);

        float2 pixel = a + direction * alongOffset + normal * acrossOffset;
        out.position = pixelToClip(pixel, u);
        out.local = float2(alongOffset, acrossOffset);
        out.segmentLength = segmentLength;
        out.halfWidth = halfWidth;
        out.color = unpackColor(s.color);

        // The dash scale, identical to DashPattern.deviceScale(pixelsPerPagePoint:).
        uint dashCount = (s.flags >> 4u) & 15u;
        float scale = pixelsPerPagePoint;
        if (dashCount > 0u) {
            // DashPattern.smallestFlooredRun: positive runs only, and an on-run (even index)
            // shorter than DOT_RUN_FRACTION of the period is a dot drawn by its caps and takes
            // no part in the floor (BH-624).
            float4 r = s.dashRuns;
            float period = r.x + r.y + ((dashCount > 2u) ? (r.z + r.w) : 0.0);
            float dotLimit = period * DOT_RUN_FRACTION;
            float smallest = 1.0e30;
            if (r.x > 0.0 && r.x >= dotLimit) smallest = min(smallest, r.x);
            if (r.y > 0.0) smallest = min(smallest, r.y);
            if (dashCount > 2u) {
                if (r.z > 0.0 && r.z >= dotLimit) smallest = min(smallest, r.z);
                if (r.w > 0.0) smallest = min(smallest, r.w);
            }
            if (smallest < 1.0e30) {
                scale = max(pixelsPerPagePoint, u.dashParameters.x / smallest);
            }
        }
        out.dashRunsPixels = s.dashRuns * scale;
        out.dashPhasePixels = s.dashOffset * scale;
        out.flags = s.flags;
        return out;
    }

    // ------------------------------------------------------- stroke coverage
    //
    // # Why this is arithmetic and not sampling
    //
    // A stroke's ink, in the frame that runs along the segment, is a **rectangle**: the interval
    // `[0, length]` along the centreline (narrowed by the dash pattern, widened by the caps)
    // crossed with `[-halfWidth, halfWidth]` across it. Antialiasing means integrating that
    // rectangle's indicator function against a unit box centred on the fragment — and the box
    // filter of an indicator function on a rectangle *separates*: it is the product of two
    // one-dimensional coverages, each of them two clamps.
    //
    // The 4x4 quadrature over a signed distance field that stood here estimated that same
    // integral with sixteen samples of a 0.25 px ramp — sixteen samples of a quantity that can
    // be written down exactly. Replacing it costs no accuracy and removes one source of error
    // outright: the ramp's corner excess, (4+pi)/24 times the ramp width squared per convex blob
    // of ink, which is why the ramp had to be kept narrow and the quadrature fine enough to
    // resolve it. A product of exact interval coverages has no corner error to trade against.
    // Measured: GPU p50 fell by between 2.1x and 3.6x across the stress corpus, and the model is
    // at least as close to Core Graphics as the quadrature on all four of the scenes built to
    // expose the difference (`StrokeCoverageTests`).
    //
    // Two things the rectangle model does not describe, and what is done about each:
    //
    // - **A round cap** is a half-disc, so its reach along the centreline depends on how far
    //   across the centreline you are, and the integral no longer separates. The pixel is
    //   therefore cut into `SEGMENT_STRIPS` horizontal strips, each strip weighted by the exact
    //   fraction of it that lies inside the stroke's width, and the cap's reach is evaluated per
    //   strip. Where the reach does not vary — every butt and square cap — the strips would be
    //   identical and the sum collapses back to the exact separable product, so that case skips
    //   the loop and takes the product directly. Round is not a rare case: `MarkupCompiler`
    //   gives every interior joint of a polyline round caps, which is how a round join is drawn.
    // - **The pixel is a square in device space, not in the segment's frame.** Both this and the
    //   quadrature it replaces integrate over a unit box in the *segment's* frame, so a diagonal
    //   stroke is filtered by a rotated box of the same area. That approximation is unchanged.
    //
    // What holds this to account: `GoldenImageTests` (24 stored Core Graphics renders, both
    // backends) and `StrokeCoverageTests`, whose four scenes and tighter budget exist for
    // exactly this shader.

    // Exact box-filter coverage of the interval [lo, hi] by a unit-wide box centred at p.
    static inline float intervalCoverage(float lo, float hi, float p) {
        return clamp(hi - p + 0.5, 0.0, 1.0) - clamp(lo - p + 0.5, 0.0, 1.0);
    }

    // How far ink reaches past the end of an inked interval, at one distance across the
    // centreline. Butt adds nothing; square adds the half width everywhere; round follows the
    // cap circle.
    static inline float capReach(uint cap, float halfWidth, float across) {
        if (cap == CAP_SQUARE) { return halfWidth; }
        if (cap == CAP_ROUND) { return sqrt(max(halfWidth * halfWidth - across * across, 0.0)); }
        return 0.0;
    }

    // The premultiplied ink of one stroke fragment. Shared by the normal and the multiply entry
    // points, which differ only in how the blend stage combines this with the target.
    static inline float4 segmentInk(SegmentVaryings in) {
        if ((in.flags & FLAG_DEAD) != 0u) { discard_fragment(); }

        float along = in.local.x;
        float across = in.local.y;
        float halfWidth = in.halfWidth;
        float segmentLength = in.segmentLength;
        // Core Graphics draws no cap at all on a stroke of one device pixel or less — it takes a
        // thin-line path — and this renderer is required to agree with it.
        uint startCap = (halfWidth <= 0.5) ? CAP_BUTT : (in.flags & 3u);
        uint endCap = (halfWidth <= 0.5) ? CAP_BUTT : ((in.flags >> 2u) & 3u);
        // Which cap governs here. A segment whose two caps differ is stroked by the Core Graphics
        // backend as two halves, each with its own cap, and the oracle re-derives the same rule;
        // this is that rule.
        uint cap = (along < segmentLength * 0.5) ? startCap : endCap;
        uint dashCount = (in.flags >> 4u) & 15u;

        // The inked interval along the centreline before caps: the segment itself, intersected
        // with the dash pattern's run at this position. `DashPattern.minimumRunPixels` is 1.5, so
        // no unit-wide box can straddle two runs and the intersection really is one interval.
        float inkStart = 0.0;
        float inkEnd = segmentLength;
        if (dashCount > 0u) {
            float4 runs = in.dashRunsPixels;
            float period = runs.x + runs.y + ((dashCount > 2u) ? (runs.z + runs.w) : 0.0);
            if (period <= 0.0) { discard_fragment(); }
            // The dash runs along the centreline only; past an end the last state persists, which
            // is what Core Graphics does when a path's end cuts a dash short.
            float onPath = clamp(along, 0.0, segmentLength);
            float position = fmod(onPath + in.dashPhasePixels, period);
            if (position < 0.0) { position += period; }
            float accumulated = 0.0;
            float behind = 0.0;
            float ahead = 0.0;
            bool inked = false;
            bool found = false;
            for (uint index = 0u; index < 4u; ++index) {
                if (found || index >= dashCount) { break; }
                float run = (index == 0u) ? runs.x
                          : ((index == 1u) ? runs.y : ((index == 2u) ? runs.z : runs.w));
                if (position < accumulated + run) {
                    behind = position - accumulated;
                    ahead = (accumulated + run) - position;
                    inked = (index % 2u == 0u);
                    found = true;
                }
                accumulated += run;
            }
            if (inked) {
                inkStart = max(inkStart, onPath - behind);
                inkEnd = min(inkEnd, onPath + ahead);
            } else if (behind < ahead) {
                // The pixel is in a gap, close enough to the inked run behind it to catch its end.
                inkEnd = min(inkEnd, onPath - behind);
            } else {
                inkStart = max(inkStart, onPath + ahead);
            }
        }

        // An empty interval is not ink, and a cap does not create ink where there is none.
        //
        // This guard is a bug fix, not a formality, and `round-caps-and-corners` is the scene
        // that found it. Where a dashed path ends inside a *gap*, the nearest inked run starts
        // beyond the path's end, so the intersection above is empty — `inkStart` past `inkEnd`.
        // Extending both ends by the cap's reach then turned that empty interval back into a
        // real one and painted a cap at the end of a path that Core Graphics leaves bare. The
        // signed-distance version this shader replaced had the same defect by the same route:
        // it measured the distance to the nearest run boundary without asking whether that run
        // was inside the segment at all.
        if (inkEnd < inkStart) { discard_fragment(); }

        float coverage;
        if (cap == CAP_ROUND) {
            // The cap's reach varies across the pixel, so integrate strip by strip. The weights
            // are the exact fraction of each strip inside the stroke's width, so they sum to the
            // exact across coverage.
            float stripHeight = 1.0 / float(SEGMENT_STRIPS);
            float sum = 0.0;
            for (uint strip = 0u; strip < SEGMENT_STRIPS; ++strip) {
                float centre = across + (float(strip) + 0.5) * stripHeight - 0.5;
                float low = centre - stripHeight * 0.5;
                float high = centre + stripHeight * 0.5;
                float weight = clamp((min(high, halfWidth) - max(low, -halfWidth)) / stripHeight,
                                     0.0, 1.0);
                if (weight <= 0.0) { continue; }
                float reach = capReach(CAP_ROUND, halfWidth, centre);
                sum += weight * intervalCoverage(inkStart - reach, inkEnd + reach, along);
            }
            coverage = sum * stripHeight;
        } else {
            float reach = capReach(cap, halfWidth, across);
            coverage = intervalCoverage(inkStart - reach, inkEnd + reach, along)
                     * intervalCoverage(-halfWidth, halfWidth, across);
        }

        if (coverage <= 0.0) { discard_fragment(); }
        float4 color = in.color;
        return float4(color.rgb * color.a * coverage, color.a * coverage);
    }

    fragment float4 segment_fragment(SegmentVaryings in [[stage_in]]) {
        return segmentInk(in);
    }

    fragment MultiplyOutput segment_fragment_multiply(SegmentVaryings in [[stage_in]]) {
        return multiplied(segmentInk(in));
    }

    // ----------------------------------------------------------------- triangles

    struct TriangleVaryings {
        float4 position [[position]];
        float4 color;
    };

    vertex TriangleVaryings triangle_vertex(
        uint vertexID [[vertex_id]],
        const device TriangleVertexIn *vertices [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]]
    ) {
        TriangleVaryings out;
        TriangleVertexIn v = vertices[vertexID];
        if ((v.flags & FLAG_DEAD) != 0u) {
            out.position = offscreen();
            out.color = float4(0.0);
            return out;
        }
        out.position = pixelToClip(pageToPixel(v.position, u), u);
        out.color = unpackColor(v.color);
        return out;
    }

    static inline float4 triangleInk(TriangleVaryings in) {
        float4 color = in.color;
        return float4(color.rgb * color.a, color.a);
    }

    fragment float4 triangle_fragment(TriangleVaryings in [[stage_in]]) {
        return triangleInk(in);
    }

    fragment MultiplyOutput triangle_fragment_multiply(TriangleVaryings in [[stage_in]]) {
        return multiplied(triangleInk(in));
    }

    // ------------------------------------------------------------------- atlases

    struct AtlasVaryings {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    vertex AtlasVaryings symbol_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device SymbolInstance *instances [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]],
        const device uint *visible [[buffer(2)]]
    ) {
        AtlasVaryings out;
        SymbolInstance s = instances[visible[instanceID]];
        if ((s.flags & FLAG_DEAD) != 0u) {
            out.position = offscreen();
            out.uv = float2(0.0);
            out.color = float4(0.0);
            return out;
        }
        float sizePixels = s.sizePagePoints > 0.0
            ? s.sizePagePoints * u.strokeParameters.x
            : s.sizeViewPoints * u.strokeParameters.w;
        float2 center = pageToPixel(s.center, u);
        float halfSize = sizePixels * 0.5;
        float2 corner = float2(
            (vertexID == 0u || vertexID == 1u) ? -halfSize : halfSize,
            (vertexID == 0u || vertexID == 2u) ? -halfSize : halfSize
        );
        if (s.rotation != 0.0) {
            // Counter-clockwise on the page: a page-to-pixel matrix that flips (negative
            // determinant, every unmirrored view) reverses the sense in pixel space.
            float determinant = u.matrix.x * u.matrix.w - u.matrix.y * u.matrix.z;
            float angle = determinant < 0.0 ? -s.rotation : s.rotation;
            float c = cos(angle);
            float sn = sin(angle);
            corner = float2(corner.x * c - corner.y * sn, corner.x * sn + corner.y * c);
        }
        out.position = pixelToClip(center + corner, u);
        out.uv = float2(
            (vertexID == 0u || vertexID == 1u) ? s.uv.x : s.uv.z,
            (vertexID == 0u || vertexID == 2u) ? s.uv.y : s.uv.w
        );
        out.color = unpackColor(s.color);
        return out;
    }

    vertex AtlasVaryings glyph_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device GlyphInstance *instances [[buffer(0)]],
        constant FrameUniforms &u [[buffer(1)]],
        const device uint *visible [[buffer(2)]]
    ) {
        AtlasVaryings out;
        GlyphInstance g = instances[visible[instanceID]];
        if ((g.flags & FLAG_DEAD) != 0u) {
            out.position = offscreen();
            out.uv = float2(0.0);
            out.color = float4(0.0);
            return out;
        }
        // The anchor is quantised to whole pixels exactly as the Core Graphics backend does it,
        // so a glyph lands on the same texel grid in both.
        float2 anchor = round(pageToPixel(g.anchor, u) + g.offset);
        float2 corner = float2(
            (vertexID == 0u || vertexID == 1u) ? 0.0 : g.size.x,
            (vertexID == 0u || vertexID == 2u) ? 0.0 : g.size.y
        );
        // A stamp's field text turns with the seal (T-065): the quad turns about its top-left
        // corner by the steps in the flags word's upper half, as the Core Graphics backend
        // rotates its context. Zero for every screen-upright label, which keeps the corner as is.
        uint steps = g.flags >> 16u;
        if (steps != 0u) {
            float turn = float(steps) * (6.283185307179586 / 65536.0);
            float c = cos(turn);
            float s = sin(turn);
            corner = float2(corner.x * c - corner.y * s, corner.x * s + corner.y * c);
        }
        out.position = pixelToClip(anchor + corner, u);
        out.uv = float2(
            (vertexID == 0u || vertexID == 1u) ? g.uv.x : g.uv.z,
            (vertexID == 0u || vertexID == 2u) ? g.uv.y : g.uv.w
        );
        out.color = unpackColor(g.color);
        return out;
    }

    static inline float4 atlasInk(AtlasVaryings in, texture2d<float> atlas, sampler atlasSampler) {
        float coverage = atlas.sample(atlasSampler, in.uv).r;
        float alpha = in.color.a * coverage;
        if (alpha <= 0.0) { discard_fragment(); }
        return float4(in.color.rgb * alpha, alpha);
    }

    fragment float4 atlas_fragment(
        AtlasVaryings in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        return atlasInk(in, atlas, atlasSampler);
    }

    fragment MultiplyOutput atlas_fragment_multiply(
        AtlasVaryings in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        return multiplied(atlasInk(in, atlas, atlasSampler));
    }
    """#
}
