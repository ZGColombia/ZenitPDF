# Quality requirements

These are acceptance requirements for measurements, snapping, ledger aggregation, and viewer
interaction. They are not a report that all checks have passed. Frozen contracts and the
committed thresholds define behavior; changes require a documented rationale and matching tests.
Use generated synthetic fixtures and record the exact source revision with each result.

In this document, "the acceptance requirements" means the project's original internal product
specification, which is not published. Each requirement used here is stated in place or in the
frozen contracts. Section numbers start at 2; code, tests and scripts cite them by number.

## 2. Measurement acceptance (C1)

### 2.1 Test classes

`rel(a, b)` means `|a − b| / max(|b|, floor)` where `b` is the reference and `floor` is the fixture's declared magnitude floor, so that a near-zero reference does not produce an infinite relative error. Every fixture declares its floor.

| Class | What it contains | Reference source | Criterion |
|---|---|---|---|
| **M-A1** Closed-form, well-conditioned | Unit square; axis-aligned and rotated rectangles; triangle from base and height; regular n-gon, area `(n/2)·R²·sin(2π/n)`; ellipse `πab`; circular arc `rθ`; prism volume `A·d`; sloped length `L·√(1+k²)` | The mathematical identity, written out in the fixture | `rel ≤ 1e-9` |
| **M-A2** Exact-predicate oracle | The same Double coordinates fed to a shoelace implemented with error-free two-sum / two-product expansions, which returns the correctly rounded exact area of those coordinates | Exact expansion arithmetic in the test target | `rel ≤ 1e-12`, and the **sign must always agree**, including for degenerate inputs |
| **M-A3** Closed-form, ill-conditioned | Slivers, near-collinear polygons, cutouts nearly filling the parent | The identity, plus the fixture's recorded condition number κ | `\|computed − exact\| ≤ 16 · κ · 2⁻⁵² · \|exact\|` where `κ = Σ\|xᵢyᵢ₊₁ − xᵢ₊₁yᵢ\| / \|Σ(xᵢyᵢ₊₁ − xᵢ₊₁yᵢ)\|`; a plain relative bound is meaningless here and must not be asserted |
| **M-B** Generated drawing workflows | Traced takeoffs on the fixture PDFs, calibrated against a printed dimension | An independent tool or a hand computation, recorded per section 2.6 | Per the acceptance requirements: length `≤ 0.05%`, area `≤ 0.10%`, volume `≤ 0.15%` |
| **M-C** Method triangulation | Every area fixture in M-A1, M-A3 and M-B | Two further independent algorithms (section 2.3) | Section 2.3 |
| **M-D** Property invariants | Generated inputs | The invariant itself | Section 2.4, per-property tolerance |
| **M-E** Adversarial geometry | Section 2.5 | The specified required behaviour | Section 2.5 — in most rows the required result is a **typed error**, not a number |
| **M-F** Unit algebra | Every supported unit in the acceptance requirements | Exact decimal conversion factors | **Zero tolerance** (section 2.4, P8) |

Class M-A2 exists because M-A1 conflates two error sources: the difference between the exact real-number answer and the exact answer for the rounded coordinates, and the error the implementation itself adds. M-A2 isolates the second, which is the only one the implementation controls.

### 2.2 Numeric conditioning rules

These are requirements on the implementation, not only on the tests, because the tests below cannot be passed without them.

1. **Shoelace must be origin-shifted.** Sum `(xᵢ − x₀)(yᵢ₊₁ − y₀) − (xᵢ₊₁ − x₀)(yᵢ − y₀)` against the first vertex or the centroid, never the raw coordinates. Property P2 (large translation) fails otherwise, and that failure is not theoretical: a page in a site plan can legitimately sit at coordinates far from its own extent after a Scale Region transform.
2. **Summation follows `NumericPolicy`.** Above `NumericPolicy.compensatedSummationThreshold` terms, use `kahanSum` or `pairwiseSum`. The choice must be fixed per call site, not per input, so results are reproducible.
3. **No `Double` value ever reaches storage or aggregation without going through the declared `NumericPolicy.defaultSignificantDigits` normalisation.** The crossing point is a single function; a CI grep must fail on any other `Decimal(_: Double)` construction inside C1 and C3.
4. **Arc and curve length is quadrature on the curve, never the flattened polyline.** Flattening exists for indexing and hit-testing only (the acceptance requirements). Cubic Bézier arc length uses Gauss-Legendre quadrature and must agree with an adaptive-subdivision reference to `rel ≤ 1e-10`.
5. **`NaN` and `±Infinity` must never leave the engine.** `run = 0` returns a typed vertical/undefined result (the acceptance requirements). Every public entry point asserts finiteness of its outputs in debug and returns a typed error in release.

### 2.3 Triangulation of methods

Every asserted area is computed three ways. The three must be genuinely independent: **the test target may not call the production area function to produce methods B or C, and methods A and B may not share a `signedArea` helper.** A CI check on the test target's imports enforces this.

| Method | Algorithm | Tolerance against method A |
|---|---|---|
| A | Production shoelace, origin-shifted, `NumericPolicy` summation | — (the value under test) |
| B | Ear-clipping triangulation, sum of triangle cross products, summed in a different order (pairwise where A used compensated summation, and vice versa). Implemented in the test target. | `rel ≤ 1e-11` for well-conditioned inputs; the M-A3 conditioned bound otherwise |
| C | Seeded Monte Carlo point-in-polygon estimate | `rel ≤ 0.5%` (see below) |

**Monte Carlo parameters and the statistics behind them.** Sample `N` points uniformly in the fixture's bounding box of area `A_box`; let `p = A_true / A_box` be the fill ratio and `k` the hit count; the estimator is `Â = A_box · k/N`. The hit count is binomial, so the relative standard error of `Â` is `√((1−p)/(pN))` and the two-sided confidence half-width at level `1−α` is `w = z_{1−α/2} · √((1−p)/(pN))`.

Fixed parameters:

- `N = 2 000 000` samples.
- Fixtures must have `p ≥ 0.25`; a fixture whose polygon fills less than a quarter of its bounding box must supply a tighter enclosing region or be excluded from method C (its exclusion recorded in the fixture).
- At `p = 0.25`, `N = 2·10⁶` and `α = 1e-4` (`z = 3.8906`): `w = 3.8906 · √(0.75 / 500 000) = 4.77·10⁻³`, i.e. **0.48% relative at 99.99% confidence**, which is why the assertion tolerance is set at 0.5%.
- Point-in-polygon uses the same fill rule (even-odd or non-zero) as the geometry under test, so cutouts and self-intersections are treated identically.

Method C is a **blunder detector, not a precision check.** It catches a wrong formula, a dropped cutout, a doubled area, a sign error. It cannot and must not be used to argue that an implementation is accurate.

**Flake control.** The PRNG is seeded from a constant recorded in the fixture, so the PR-CI run is deterministic and cannot flake. The extended stress requirement re-runs method C over 32 additional seeds per fixture. With ~200 area fixtures that is ~6 400 assertions at `α = 1e-4`, so roughly 0.6 spurious stress-run failures per sweep are expected: a stress-run method-C failure is escalated only if it reproduces on re-run with the same seed, or if the deviation exceeds 2× the tolerance. A method-C failure on the recorded CI seed is never spurious and always blocks.

### 2.4 Property-based invariants

Each property is stated as an explicit predicate over generated inputs. Generators produce simple polygons, polygons with holes, polylines, and the adversarial families of section 2.5. The baseline target is 200 cases per property; the extended stress target is 20 000. Report actual executed coverage separately. **Every failing case is minimised, its seed and its shrunk input recorded, and promoted to a permanent named regression fixture in the same commit as the fix** (see verification and evidence below).

| ID | Property | Predicate | Tolerance |
|---|---|---|---|
| P1 | Rotation invariance | `∀θ, ∀S: measure(R_θ · S) = measure(S)` | `rel ≤ 1e-11` for arbitrary θ; **exact equality** for θ ∈ {90°, 180°, 270°}, where the transform is a coordinate swap and sign flip and introduces no rounding |
| P2 | Translation invariance | `∀t, ∀S: measure(S + t) = measure(S)` | `rel ≤ 1e-11` for `‖t‖ ≤ 10·diam(S)`; `rel ≤ 1e-9` for `‖t‖ = 10⁶·diam(S)`. The large-translation case is the test that catches an un-shifted shoelace |
| P3 | Linearity in scale | `∀s>0: length(sS) = s·length(S)`, `area(sS) = s²·area(S)`, `volume(sS,sd) = s³·volume(S,d)` | **`rel ≤ 1e-15`** when `s` is a power of two (coordinate scaling is then exact in binary floating point); `rel ≤ 1e-12` for arbitrary `s` |
| P4 | Scale-transform equivalence | Measuring in page points then applying `A` equals applying `A` to the geometry then measuring, for uniform, anisotropic and rotated `A` (the acceptance requirements) | `rel ≤ 1e-12`; `realArea = \|det(A)\| · pdfArea` must hold to `rel ≤ 1e-14` |
| P5 | Cutout order independence | `net(P, [C₁,…,Cₙ]) = net(P, permutation of [C₁,…,Cₙ])` for every permutation | **Exact equality of the stored `Decimal`**; if the Clipper2 pipeline is order-sensitive at the Double level, the engine must canonically sort cutouts before the boolean op, and the property test asserts that sorting exists |
| P6 | Cutout union equivalence | `((P − C₁) − C₂) = (P − (C₁ ∪ C₂))`. Set subtraction is **not** associative, so this — not "associativity" — is the property that must hold, and it must be stated this way in the test name | `rel ≤ 1e-12` |
| P7 | Vertex-order and orientation independence | Rotating the vertex list by any k, and reversing it, changes no unsigned measurement; `area` is the absolute value and is independent of clockwise/counter-clockwise input; `signedArea` flips sign exactly | **Exact equality** for the rotation and reversal of the vertex list at fixed origin-shift anchor; sign flip exact |
| P8 | Unit-conversion round trip | `toDisplay(toSI(v, u), u) = v` for every unit in the acceptance requirements | **Zero tolerance, bit-exact `Decimal`.** Every supported length/area/volume factor is an exact decimal rational (in = 0.0254, ft = 0.3048, yd = 0.9144, mi = 1609.344, ft² = 0.09290304, acre = 4046.8564224, ft³ = 0.028316846592, yd³ = 0.764554857984, litre = 0.001, …), so an inexact round trip proves the factor table was written as `Double` literals. **A CI grep must fail on any `Double` literal in the unit factor table.** Angles are the sole exception: radian↔degree involves π, tolerance `rel ≤ 1e-15` |
| P9 | Subdivision invariance | Inserting a vertex anywhere on an existing edge changes nothing | Length: `\|L′ − L\| ≤ 4·2⁻⁵²·L`. Area: the M-A3 conditioned bound. Perimeter and cutout results likewise |
| P10 | Imperial display round trip | Display rounding to `whole … 1/64` (the acceptance requirements) never mutates the stored SI value | **Exact equality** of the stored `DecimalQuantity` before and after any display formatting |
| P11 | Cutout monotonicity | Adding a cutout never increases net area; removing one never decreases it; net area is never negative | Exact ordering comparison; a negative net area is a typed error, never a value |
| P12 | Perimeter mode consistency | `outer+cutoutEdges ≥ outerOnly`, and `outerOnly` is unchanged by adding cutouts (the acceptance requirements) | Exact ordering; `rel ≤ 1e-12` for the unchanged case |

### 2.5 Adversarial geometry

For most of these rows the correct behaviour is a **typed error or an explicit warning**, not a number. An engine that returns a plausible-looking value for a self-intersecting polygon has failed the row even if the value is "reasonable".

| Case | Construction | Required behaviour |
|---|---|---|
| Near-degenerate triangle | Height `1e-9` × base `1e3` | Value satisfying the M-A3 conditioned bound, plus a `degenerateGeometry` warning in `MeasurementResult.warnings`. Never `0`, never `NaN` |
| Collinear points | 3+ vertices exactly collinear; and off-collinear by `1e-15` | Area `0` with warning; three-point circle rejected per the acceptance requirements; no division by a near-zero determinant |
| Self-intersecting input | Figure-eight, bowtie, and a 200-vertex random self-intersecting polygon | Blocked, or normalised through Clipper2 **after explicit confirmation** (the acceptance requirements). Never silently shoelaced — the shoelace of a bowtie is the *difference* of the lobes and is meaningless |
| Duplicate vertices | Consecutive duplicates; duplicates separated by other vertices; every vertex duplicated | Deduplicated deterministically; result identical to the deduplicated polygon (exact equality); "fewer than three unique points" rejected per the acceptance requirements |
| Cutout touching parent edge | Cutout edge exactly coincident with a parent edge; sharing one vertex; sharing a full edge | Net area equals the closed-form value to `rel ≤ 1e-12`. No sliver artefacts, no duplicated boundary in the perimeter |
| Cutout equals parent | Identical polygon | Net area exactly `0`, typed warning, **not** a negative or `1e-16` value; downstream volume also exactly `0` |
| Cutout outside parent | No overlap | Rejected — the acceptance requirements require a cutout to overlap its parent |
| Cutout larger than parent | Contains the parent | Net area exactly `0` with warning; never negative |
| Extreme aspect ratio | 1e6 : 1 and 1e-6 : 1 rectangles and slivers | Conditioned bound; must never report `0` for an area that is representable |
| Tiny coordinates | All coordinates at magnitude `1e-6` page points | Full accuracy: M-A1 tolerances apply. This is inside the legitimate range |
| Huge coordinates | Coordinates at magnitude `1e9` page points | **Typed rejection.** The engine declares a coordinate magnitude bound of `1e7` page points (a PDF user-space page cannot legitimately exceed 14 400 units; anything beyond `1e7` is a corrupt file or a bad CTM). Above the bound: `coordinateOutOfRange` error. No `NaN`, no `Infinity`, no silently garbage value. The test asserts the error, not a number |
| Mixed magnitudes | One segment `1e-6`, the next `1e6`, in the same polyline | Compensated summation must hold; `rel ≤ 1e-12` against the exact-expansion reference |
| Zero-length segment | Repeated point mid-polyline | Contributes exactly `0`; angle at that vertex is a typed undefined, not `NaN` |
| Unclosed polygon | Last vertex ≠ first | Closed implicitly with the closure recorded as a warning, or rejected — one behaviour, declared in the contract, never both depending on the tool |
| Empty and single-point input | 0 and 1 vertices | Typed error, no crash, no `0` masquerading as a measurement |

### 2.6 Synthetic fixture provenance

All published fixtures are generated. Record their seed, units, calibration, reference formula,
and independent expected values. Use `Packages/ZPDFTestingSupport` and the golden measurement
cases in `Tests/GoldenMeasurements`. No private drawings are required or published.

## 3. Snap acceptance (C2)

### 3.1 Criteria

| ID | Criterion | Measurement | Threshold |
|---|---|---|---|
| S1 | **Candidate correctness** | For a cursor at page point `q`, the winning candidate's `kind` and `id` must equal the winner computed by a brute-force scorer in the test target that evaluates every primitive on the page under the documented priority order of the acceptance requirements | Exact match of `(kind, id, snappedPoint)` on 100% of fixture positions. Ties are broken by a **total order** — `(score, kind priority, primitive id)` — so a tie has exactly one legal winner |
| S2 | **Snapped point accuracy** | Distance between the returned snap point and the closed-form point of the named primitive feature (endpoint, midpoint, centre, quadrant, foot of perpendicular, tangent point) | `≤ 1e-9` page points |
| S3 | **Intersection accuracy, well-conditioned** | Crossing angle ≥ 5°: line-line, line-circle, circle-circle, line-cubic (Cardano or Newton refined to 1e-14), cubic-cubic | `≤ 1e-9` page points from the closed-form point |
| S4 | **Intersection accuracy, shallow** | Crossing angle in [0.5°, 5°): the location is genuinely ill-conditioned, so proximity to a closed-form point is the wrong assertion | Perpendicular distance from the returned point to **both** primitives `≤ 1e-7` page points |
| S5 | **Near-parallel refusal** | Crossing angle < 0.5°, and exactly parallel | **No intersection candidate is emitted.** An arbitrary far-away point is a failure even if it is mathematically the true intersection |
| S6 | **Tolerance derivation** | Section 3.2 | Computed page tolerance equals the closed-form value to `rel ≤ 1e-12` at every tested zoom, and the returned candidate set equals the brute-force set within that radius, exactly |
| S7 | **Zoom extremes** | Zoom 0.05 (5%) and 64.0 (6400%), plus 0.25, 1.0, 4.0, 16.0 | S1 through S6 hold unchanged at every zoom. The **candidate identity must not change with zoom** for a cursor at a fixed *page* point that is unambiguous at all zooms |
| S8 | **Retina invariance** | The same gesture, in view points, on `backingScaleFactor` 1 and 2 | Byte-identical candidate sequence (section 3.2) |
| S9 | **Stability / no oscillation** | Replay of synthetic pointer paths (section 3.3) | A monotone path across the midline between two candidates produces **exactly one** switch. A path that dithers within the hysteresis band after acquiring a candidate produces **zero** switches. No path produces more switches than the number of times it fully crosses `tolerance + hysteresis` |
| S10 | **Rotated and cropped pages** | `/Rotate` 0/90/180/270 × non-zero `/CropBox` offset × `/MediaBox` origin ≠ (0,0) | S1–S7 hold; snapped points are asserted in **unrotated PDF user space**, and the round trip view→page→view is exact to `1e-12` |
| S11 | **Nested form XObjects** | Forms nested 4 deep with non-identity `/Matrix` at each level, including a mirroring and a shearing matrix | Extracted primitive coordinates match a hand-composed CTM to `1e-9` page points |
| S12 | **Performance** | Section 3.5 | **p95 ≤ 8 ms, p99.9 ≤ 16 ms** per snap query at an index of **250 000 primitives on one page**, over ≥ 10 000 replayed pointer events |
| S13 | **Index build** | Time to a queryable index for the visible page | p95 ≤ 400 ms for a 250 000-primitive page; the page is usable (grid/markup snap live, Vector Snap reported as `building`) before it completes |
| S14 | **Scanned-page honesty** | Section 3.6 | A page with no usable vector content reports `unavailable` with a reason, grid and markup snap continue to work, and **no vector candidate is ever emitted for that page** |
| S15 | **Determinism** | Section 3.4 | Identical candidate ID sequence across 100 repeats in one process, across 20 fresh processes, and across arm64 and x86_64 |
| S16 | **Layer and visibility respect** | Hidden OCG layers, clipping-only paths, invisible paths, filtered background rectangles (the acceptance requirements) | No candidate from a hidden or excluded primitive, at any zoom, ever |

Rationale for S12: the acceptance requirements set `snapFeedbackP95Ms: 16`, which is the entire 60 fps frame budget. In the frame where a snap query runs, the renderer, the overlay, the label atlas and AppKit also need time. Half the frame is the most snap may take if the 60 fps target in the same section is to survive; 16 ms is retained as the p99.9 hard ceiling.

### 3.2 Screen-pixel to page-point tolerance — the exact rule

The acceptance requirements specify the snap radius in pixels (`default 10`, `min 4`, `max 24`, `hysteresis 4`; the frozen snap contract, `Docs/Contracts/SNAP_CONTRACT.json`, records the same values in its `snapRadiusDefaults` table). "Pixel" is ambiguous on Retina and the ambiguity is a correctness question, so it is resolved here:

> **The snap radius is defined in AppKit view points, i.e. device-independent points, not backing-store pixels.**

Therefore:

```
tolerancePageUnits = radiusViewPoints / zoom
```

and `backingScaleFactor` **does not appear in the formula**. A 10-point radius is the same physical target on a 1× and a 2× display; making it depend on the backing scale would halve the snap target on every Retina Mac, which is every Mac the product ships to. Reversing this decision requires an ADR.

Worked values the tests assert:

| Zoom | `tolerancePageUnits` at 10 view points | at 4 | at 24 | Hysteresis band (10 + 4) |
|---|---|---|---|---|
| 0.05 | 200 | 80 | 480 | 280 |
| 0.25 | 40 | 16 | 96 | 56 |
| 1.00 | 10 | 4 | 24 | 14 |
| 4.00 | 2.5 | 1 | 6 | 3.5 |
| 16.00 | 0.625 | 0.25 | 1.5 | 0.875 |
| 64.00 | 0.15625 | 0.0625 | 0.375 | 0.21875 |

Every value in that table is exactly representable in binary floating point, so S6 asserts them at `rel ≤ 1e-12` rather than approximately. The conversion must be recomputed **per event** (the acceptance requirements) — a cached tolerance that survives a zoom change is a defect, and there is a test that zooms between events and asserts the tolerance changed.

At 5% zoom the 200-page-point radius will often contain many primitives; the candidate scorer must still return one deterministic winner, and S1 applies unchanged. At 6400% the radius is a sixth of a page point; the test asserts that a primitive 0.2 page points away is *not* a candidate, i.e. that the tolerance genuinely shrinks and the engine does not fall back to a floor.

### 3.3 Stability: how oscillation is actually tested

Hysteresis (the acceptance requirements) is asserted by replaying recorded pointer paths, not by inspecting state:

1. A path is a deterministic list of `(viewPoint, zoom, modifiers, timestamp)` samples stored as a fixture. Paths are generated synthetically, not captured from a human, so they are reproducible.
2. The engine is driven event by event and emits a **snap decision log**: one line per event with the winning candidate id, kind, score and snapped point.
3. Assertions run over the log, not over screenshots.

Required path families:

| Path | Assertion |
|---|---|
| Straight traverse across the perpendicular bisector of two equal-priority endpoints | Exactly one switch, occurring after the cursor leaves `tolerance + hysteresis` of the first |
| Dither: 200 samples of ±2 view points of jitter centred exactly on the midline, after acquiring candidate A | **Zero switches** |
| Dither at ±3.9 view points (just inside the 4-point hysteresis) | Zero switches |
| Dither at ±4.1 view points | Switches permitted, but bounded by the number of full crossings |
| Slow approach to a cluster of 8 primitives within one tolerance radius | Monotone, non-oscillating candidate sequence; `Tab` cycling (the acceptance requirements) visits every one of the 8 exactly once per cycle, in a stable order |
| Zoom change mid-path with the cursor stationary | Candidate may change (the tolerance changed), but the change is deterministic and reported |
| Path crossing from a vector primitive onto a scanned region of a mixed page | Clean transition to `unavailable` for the vector class with no phantom candidate |

### 3.4 Determinism

S15 is a real risk in Swift, not a formality: `Hasher` is randomly seeded per process, so any candidate ordering that depends on `Set` or `Dictionary` iteration order will differ between runs and produce a snap engine that behaves differently on Tuesday.

Rules:

1. Candidate collection and ordering must never depend on `Set` or `Dictionary` iteration order. Ordering comes from the R-tree traversal order plus the total order in S1.
2. No dependence on wall-clock time, `Date`, elapsed time, or on how many events have been processed.
3. No dependence on concurrency scheduling: if index queries are parallelised, results are merged in a deterministic order, not in completion order.
4. The determinism test runs the same fixture path in **20 freshly spawned processes with `SWIFT_DETERMINISTIC_HASHING` unset** and requires byte-identical decision logs. Running that test with deterministic hashing forced on defeats it and is forbidden.
5. Cross-architecture: the same fixture must produce the same log on arm64 and on x86_64. Where an FMA contraction would differ, the affected expression is written to forbid contraction.

### 3.5 Performance measurement definition

The snap benchmark must report:

- Index size actually used: **250 000 primitives on one page** for the headline number, plus curves at 10 k, 50 k, 100 k, 500 k so the scaling shape is visible and a regression in complexity is distinguishable from a regression in constants.
- Event count ≥ 10 000, replayed from fixture paths so the number is reproducible.
- p50, p95, p99, p99.9, max — **max included**, because a 200 ms outlier is a dropped frame the user sees, and a p95 alone hides it.
- Allocations per query and peak resident memory for the index. A query that allocates per event will stutter under memory pressure regardless of its p95.
- The full machine and toolchain block recorded with the result.

### 3.6 Architecture note — vector extraction via CGPDFScanner

Vector geometry for snap is extracted with CoreGraphics `CGPDFScanner` over the page content stream. **No third-party PDF engine is required for the snap engine to ship.**

The scanner is driven by a `CGPDFOperatorTable` with callbacks for the path construction operators — `m`, `l`, `c`, `v`, `y`, `h`, `re` — and the extractor itself maintains everything the scanner does not:

| Concern | What the extractor must do |
|---|---|
| Graphics state | Maintain the `q` / `Q` stack and the CTM under `cm`. `CGPDFScanner` reports operators and operands; **it does not apply the CTM for you.** Every emitted primitive is transformed to page user space by the composed CTM at the moment of emission |
| Form XObjects | On `Do`, resolve the name in the current `/Resources /XObject` dictionary; if `/Subtype` is `/Form`, push `/Matrix`, intersect `/BBox`, and recurse with `CGPDFContentStreamCreateWithStream(stream, resources, parentContentStream)` so resource inheritance is correct. Depth is capped at **32**, and a visited-set of stream object references prevents cyclic form recursion — a malformed file can reference a form from inside itself |
| Clipping | Track `W` / `W*` followed by `n`. Paths whose only role is to set the clip are **clipping-only** and must not become snap primitives (the acceptance requirements). The active clip is also carried so out-of-clip geometry can be excluded |
| Page transform | Apply `/Rotate` and the `/CropBox`↔`/MediaBox` offset once, at the top of the composed transform, and record which convention was used so S10 can assert the inverse |
| Inline images | `BI … ID … EI` must be skipped without attempting to parse the binary payload |
| Background filtering | Rectangles covering ≥ 95% of the crop box, and paths whose bounds exceed the crop box, are filtered per the acceptance requirements — but the filter decision is **recorded per primitive**, so a false filter is debuggable rather than invisible |
| Provenance | Every `SnapPrimitive` records `sourceObjectID` and `layerID`, and the index is cached keyed by document SHA + page + extractor version (the acceptance requirements) |
| Curves | `c`, `v`, `y` are stored as cubics. Flattening happens only for R-tree bounds and hit-testing; snap points on curves are solved on the curve |

**What CGPDFScanner will struggle with, and the required degradation.** In every case the rule is the same: *degrade to fewer candidates, never to wrong candidates, and always say so.*

| Limitation | Why | Required behaviour |
|---|---|---|
| Shading patterns (`sh`, pattern colour spaces) | The visible edge is produced by the shading and the clip, not by a path operator, so there is no path to snap to | Emit nothing from the shading itself. The surrounding clip path may be emitted as a primitive with reduced `confidence`, clearly typed as clip-derived. **Never synthesise an edge where the content stream contains none.** The page is marked `partial` with reason `shadingGeometryNotExtracted` |
| Type 3 fonts as geometry | Type 3 glyphs are content streams; treating them as building geometry would require executing glyph procedures under the text matrix | **Not extracted.** Text is never a snap source, consistent with the acceptance requirements and the frozen snap contract ("OCR text is never used as a construction line"). A page whose linework is drawn with Type 3 glyphs is marked `partial` with reason `type3GlyphGeometryNotExtracted`, so the user is told rather than left wondering why nothing snaps |
| Huge content streams | Multi-megabyte streams with tens of millions of operators; unbounded scanning blocks the page and can exhaust memory | Hard budgets, all recorded in the threshold file: **operator count 20 000 000**, **primitive count 2 000 000**, **wall clock 10 s**, **index memory 512 MB** per page. On exceeding any budget the index is marked `partial(budgetExceeded:)` with the budget that was hit and the fraction of the stream consumed. **A truncated index must never be reported as complete** — that is the failure mode that produces a confidently wrong snap |
| Annotation appearance streams | They are separate streams, not page content | Out of scope for Vector Snap in 1.0, stated explicitly in the availability reason rather than silently omitted. Zenit's own markups are a separate snap source (the acceptance requirements) |
| Soft masks, transparency groups, text-render-mode-7 clips | The visible geometry depends on compositing the extractor does not perform | Extract the underlying paths where they exist; never infer geometry from compositing. Mark `partial` where the omission is detectable |
| Optional content (OCG) currently off | A hidden layer must not be snappable | Excluded, per S16, with the exclusion recorded |

**Availability states.** Exactly three, and they are part of the contract, not UI decoration:

| State | Predicate | UI obligation |
|---|---|---|
| `available` | Extraction completed within budget and yielded ≥ 1 primitive after filtering | Normal Vector Snap |
| `partial(reason:)` | Extraction hit a budget or a known limitation above | Vector Snap works on what was extracted and the UI states that it is incomplete, with the reason. **Never presented as `available`** |
| `unavailable(reason:)` | Zero primitives after filtering — a scanned page, or a page whose only path was a filtered background rectangle | "Vector Snap unavailable" per the acceptance requirements; grid and markup snap continue to work; OCR text is used for search only |

A vector page that yields only a border rectangle resolves to `unavailable`, not `available` with one useless primitive — the test asserts that specifically, because the alternative teaches users that the feature is unreliable.

A future replacement extractor requires differential testing across the generated corpus. Any divergence affecting a golden measurement requires an architecture decision.

---

## 4. Aggregation acceptance (C3)

### 4.1 Totals are exact — zero tolerance

| ID | Criterion | Threshold |
|---|---|---|
| A1 | A total equals the `Decimal` sum of its parts | `total == parts.reduce(Decimal(0), +)` compared with `Decimal` equality. **No tolerance, no epsilon, no `isApproximatelyEqual`.** The comparison is on the stored SI `Decimal`, never on a formatted string |
| A2 | The sum is exact, not merely close | Every `NSDecimalAdd` in the aggregation path is checked for `NSDecimalNumber.CalculationError.noError`. A `lossOfPrecision`, `overflow` or `underflow` result is a **typed error surfaced to the user**, never a rounded value. Inputs are normalised to ≤ 15 significant digits (`NumericPolicy.defaultSignificantDigits`), so a sum of 10⁶ terms needs at most ~21 significant digits against `Decimal`'s 38 — exactness is achievable and therefore required |
| A3 | Order independence | Summing a randomly permuted multiset yields a bit-identical `Decimal`. Property test over 1 000 permutations of 10 000-element sets |
| A4 | No `Double` in the aggregation path | CI grep: no `Double` arithmetic between the `NumericPolicy` normalisation boundary and the export formatter, in C3 |

### 4.2 Grouping and regrouping

| ID | Criterion | Threshold |
|---|---|---|
| A5 | Subtotals reconstitute the total | For every grouping key `g`: `Σ subtotal(group) == grandTotal`, exactly |
| A6 | Regrouping is total-preserving | Grouping by key `g₁`, then `g₂`, then back to `g₁`, leaves the grand total bit-identical and the `g₁` subtotals bit-identical |
| A7 | Nested grouping | For a two-level grouping, every parent subtotal equals the exact sum of its child subtotals, and the grand total equals the sum of the top level. Exactly |
| A8 | Partition completeness | Every row belongs to exactly one group at each level; the union of group member-ID sets equals the full row-ID set and the pairwise intersections are empty. Rows with a null key go to an explicit "(none)" group, never disappear |
| A9 | Non-sum aggregates | `Count` equals the group's row count exactly. `Average` is defined as `sum / count` computed in `Decimal` with a declared scale and rounding mode, and the definition is identical in the table, in subtotals and in every export. `Min`/`Max`/`Distinct count` return actual member values, never recomputed approximations |
| A10 | Weighted total | The weighting expression is declared per column and evaluated identically everywhere; a weighted total is never silently substituted for a plain sum |

### 4.3 Mixed dimensions

Per the acceptance requirements, incompatible dimensions are never summed in the same cell. That is a modelling requirement before it is a test:

| ID | Criterion | Threshold |
|---|---|---|
| A11 | Mixed units are a state, not an absence | An aggregate cell is a sum type with an explicit `mixedDimensions([QuantityDimension])` case. It is **never** rendered as blank, `0`, `—`, or `nil`, because each of those reads as "nothing here" instead of "these cannot be added" |
| A12 | Detection is by `QuantityDimension`, not by display unit | Rows in m and mm are the **same** dimension and must be converted and summed. Rows in m² and m are different dimensions and must produce `mixedDimensions`. Currency with different ISO codes is mixed. Angles are never summed with lengths |
| A13 | The state propagates | A mixed subtotal makes the parent subtotal and the grand total mixed; it is never quietly dropped from the parent's sum |
| A14 | The state exports | Every export format carries an explicit, machine-distinguishable mixed-units token in that cell, and the same token in all four formats. Never an empty CSV field, never a blank XLSX cell, never `null` in JSON without a typed discriminator. The exact wording is owned by `Docs/Design/UX_COPY_STANDARD.md`; the requirement here is that it exists, is non-empty, and is identical across CSV, XLSX, JSON and PDF |
| A15 | Formulas refuse | A formula that adds incompatible dimensions is a **parse/type error at column definition time**, not a runtime `nil`. Dimensional analysis is required by the acceptance requirements |

### 4.4 Filters

| ID | Criterion | Threshold |
|---|---|---|
| A16 | Strict subset | `Set(filtered.ids) ⊆ Set(unfiltered.ids)`, asserted on IDs, not on counts |
| A17 | Consistent subtotals | Every subtotal in a filtered view equals the exact `Decimal` sum of the *visible* members of that group. A filtered subtotal that still includes hidden rows, or a "hidden rows excluded" footnote that does not match the arithmetic, is a failure |
| A18 | Idempotence | Applying the same filter twice equals applying it once, as an ID set |
| A19 | Commutativity | `filter(A) ∘ filter(B) == filter(B) ∘ filter(A)` as ID sets, for all pairs in the generated suite |
| A20 | Complement | `filtered ∪ complement == all`, `filtered ∩ complement == ∅`, and `sum(filtered) + sum(complement) == grandTotal` exactly |
| A21 | Round trip | Clearing a filter restores bit-identical totals and subtotals to the pre-filter values |
| A22 | Filter/group order independence | Filter-then-group and group-then-filter produce identical visible rows and identical subtotals |
| A23 | Regex guard | The complexity/time guard of the acceptance requirements fires as a typed, user-visible error; a guarded filter never returns a **partial** result set that looks complete |

### 4.5 Formula identity across surfaces

The trap here is real and specific: for a column such as `UnitCost * Area`, evaluating per row and summing gives a different number than evaluating the formula on the aggregated inputs. Both are defensible; silently mixing them is not.

| ID | Criterion | Threshold |
|---|---|---|
| A24 | Declared aggregation semantics | Every formula column declares `evaluateThenAggregate` (default) or `aggregateThenEvaluate`. The declaration is part of the column definition, is versioned with the grammar, and is written into every export's metadata |
| A25 | One evaluator | The row cell, the group subtotal, the grand total, the PDF report, the CSV, the XLSX and the JSON all obtain the value from the **same** evaluator call path. A differential test asserts the four export paths and the two on-screen paths return a bit-identical `Decimal` for the same input row set |
| A26 | Determinism | The same AST over the same inputs yields the same `Decimal` across processes and architectures; the AST is deterministic (the acceptance requirements) and hash-order independent |
| A27 | Cycles and errors | Cycle detection is exhaustive over the column graph; a cycle is a typed error naming the cycle, never a partial evaluation or a zero. Division by zero, domain errors and dimension mismatches are typed errors that render as an error state, never as `0` |
| A28 | Grammar versioning | A change to the grammar or to a function's semantics bumps `formulaVersion`; stored results record the version they were computed with, and a version mismatch triggers explicit recalculation, never a silent reinterpretation |

### 4.6 Export fidelity

| ID | Criterion | Threshold |
|---|---|---|
| A29 | Digit-for-digit agreement | For every cell, the exported representation equals the on-screen string produced by the same formatter, at the same precision, in the same locale, **byte for byte**. Golden export fixtures store the expected bytes |
| A30 | Round once, at the boundary | Rounding is applied exactly once, from the stored full-precision `Decimal`, at the export formatter. Never from an already-rounded display string; never twice |
| A31 | Double-rounding detector | The golden set includes values engineered so that round-then-round differs from single rounding — e.g. `0.4449` to 2 decimals is `0.44` when rounded once and `0.45` when rounded via 3 decimals. Every such value must export as the single-rounded form. This test is mandatory and may not be removed |
| A32 | Per-format policy, declared | **CSV**: UTF-8, optional BOM, locale delimiter, and both raw and display columns with separate unit columns (the acceptance requirements); the raw column is the unrounded `Decimal`. **XLSX**: the cell holds the full-precision numeric value with a number format applied; the golden test asserts the *rendered* string under that format equals the on-screen string. **Zenit JSON**: exact raw decimal strings with dimension/unit metadata and separate display strings; display text must never replace the raw value. **PDF**: display values only, with the unit and scale notes |
| A33 | Locale coverage | The golden export set covers at least `en-US` (period decimal, comma delimiter), `sv-SE` (comma decimal, semicolon delimiter) and one right-to-left or non-Latin-digit locale, and asserts digit-for-digit in each |
| A34 | Stable order | Row and group order in an export is fully determined by the visible sort plus a documented tie-breaker; two exports of the same view are byte-identical |
| A35 | Reconciliation inside the export | The totals printed in an export equal the exact sum of the rows printed in that same export. An export that filters rows but carries the unfiltered total is a failure |
| A36 | Batch summary | Combining N project ledgers (the acceptance requirements) preserves A1–A14: the combined total equals the exact sum of the per-project totals, unit normalisation is dimension-checked, and a project that fails to normalise is reported, never silently dropped |

### 4.7 The 100 000-row performance envelope

Envelope: **100 000 ledger rows, 20 visible columns, 5 formula columns, one grouping level**, on the hardware declared in the benchmark report. Benchmark reports include p50/p95/p99/max; see the test runners below.

| Operation | Budget |
|---|---|
| Cold open of the ledger to first painted row | p95 ≤ 1 000 ms |
| Sustained scroll frame time while flinging | p95 ≤ 8 ms per frame; **no frame > 33 ms** |
| Sort by one column | p95 ≤ 300 ms |
| Group by one column, including subtotals | p95 ≤ 500 ms |
| Regroup to a different key | p95 ≤ 500 ms |
| Apply a text filter | p95 ≤ 300 ms, and cancellable within 50 ms of the cancel |
| Apply a numeric range filter | p95 ≤ 200 ms |
| Single row edit → every affected subtotal and total correct on screen | p95 ≤ 100 ms (the acceptance requirements) |
| Ledger row → canvas jump (activate, page, select, zoom, flash) | p95 ≤ 100 ms (the acceptance requirements) |
| Canvas selection → ledger row located, group expanded, scrolled | p95 ≤ 100 ms |
| Recompute one formula column over all rows | p95 ≤ 2 000 ms, off the main actor, cancellable |
| Recompute all 5 formula columns | p95 ≤ 8 000 ms, off the main actor, cancellable, with progress |
| CSV export | p95 ≤ 5 s, peak RSS delta ≤ 200 MB |
| XLSX export in constant-memory mode | p95 ≤ 15 s, peak RSS delta ≤ 300 MB |
| JSON export | p95 ≤ 8 s |
| PDF report, table only | p95 ≤ 30 s |
| Peak resident memory with the ledger loaded | ≤ 1.5 GB process total |

Two rules that apply to every row of that table:

1. **No operation may block the main actor for more than 16 ms in a single contiguous span.** A 400 ms regroup that runs off the main actor is acceptable; a 400 ms regroup that freezes the window is not, and the two are indistinguishable in a p95 that only measures completion.
2. **Correctness is asserted after every benchmarked operation.** A fast path that produces a wrong subtotal fails the benchmark, not just the correctness suite. The benchmark harness runs the A1/A5 invariants at the end of each iteration.

The stress corpus of the acceptance requirements — 10 000 count points on one page, 500 custom columns, multiple Scale Regions — is run at the envelope's outer edge in a separately reported stress run; the budgets above are for the 100 000-row configuration specifically.

---


## 5. Verification and evidence

Use the grouped runners in [Tests](../../Tests/README.md). Numeric tests need independent
oracles, property tests, adversarial cases, and end-to-end save/reopen/export checks. An
unrun or skipped case must be reported explicitly, never counted as a passing check.

Record configuration, fixture seed, sample count, runtime/toolchain, and benchmark hardware
with results. Separate debug and optimized timings. Changing a threshold requires a reason;
never relax it solely to hide a regression. Performance results also assert correctness.

The [machine-readable thresholds](quality-thresholds.json) hold viewer and automation budgets.
The tables above retain requirements not yet represented there. Avoid inventing executable
commands for a requirement that has no harness; identify that gap in the result report.

## 6. Viewer requirements

| ID | Gate | Threshold | Asserted by |
| --- | --- | --- | --- |
| **Z1** | Main-thread work per frame while zooming or panning, page presentation only | **p50 ≤ 2.0 ms, p99 ≤ 4.0 ms** | `ViewerZoomGateTests.z1_mainThreadBlit` |
| **Z2** | Frames missed in a 36-step fit → 400 % pinch, and rasterisation off the main actor | **0 of 36**, no main-actor rasterisation | `z2_theRealisticPinch`, `z2_rasterisationIsNotOnTheMainActor` |
| **Z3** | Zoom settled → fully sharp viewport, page already parsed | **p50 ≤ 16 ms, p95 ≤ 40 ms, p99 ≤ 80 ms**, n ≥ 120 per zoom | `z3z4_viewportRasterLatency` |
| **Z4** | Same, first viewport of an unparsed page | **p95 ≤ 120 ms** | `z3z4_viewportRasterLatency` |
| **Z5** | **Sharpness.** Magnification of the displayed raster once the viewport has settled | **≤ 1.00× at every zoom in 5 %…800 %** | `z5_settledMagnificationIsOne`, `z5_theDefectThisGateExistsFor` |
| **Z6** | **Pixel alignment.** Every raster destination rectangle, in device pixels | **origin and size integral** | `z6_destinationsAreIntegral` |
| **Z7** | **Memory, enforced.** Steady state per open document | tile cache ≤ 256 MiB · one viewport raster ≤ 32 MiB · vector underlay ≤ 16 MiB per page · total ≤ 304 MiB | `z8_theArithmeticThatMakesTheViewportPathNecessary`, `VectorUnderlayTests.metalUnderlayDrawsInk` |
| **Z8** | Whole-page rasterisation above the pixel budget | **forbidden, not clamped.** 24 MP in the canvas, 64 MP in the bridge, both as typed errors | `z8_wholePageOverBudgetIsRefused`, `z8_plannerRefuses`, `CanvasGeometryTests.wholePageRasterIsRefusedNotClamped` |
| **Z9** | Cancellation grain: work committed when a render is superseded | **≤ 1.0 ms** | No current passing result is recorded here; measure cancellation separately from raster completion |
| **Z10** | Vector underlay availability | present at every zoom on a Metal machine; **switched off, and said so in the diagnostics panel**, on a Core Graphics fallback | `VectorUnderlayTests.z10_availabilityIsStatedEitherWay`, `z10_fallbackDrawsNothing` |

For current debug/release timing values and gesture budgets, use
[quality-thresholds.json](quality-thresholds.json). See the
[benchmark method](ZOOM_BENCHMARK.md). Private-input timing history is not a public fixture
or proof that a release candidate passes. Use generated inputs for reproducible results.
