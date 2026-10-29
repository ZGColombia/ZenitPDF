# ZPDFTestingSupport — the synthetic PDF corpus

Every fixture below is generated at test time by `ZPDFFixtures`, written to a
caller-supplied directory, and accompanied by a `FixtureManifest` that states in exact
numbers what is drawn. **Assert against the manifest.** Do not re-derive the truth from
the file: a test that recomputes what it is checking is a test of self-consistency, not
of correctness.

```swift
let handle = try ZPDFFixtures.make(.lShape, in: temporaryDirectory)
let path   = handle.manifest.path(id: "l-shape")   // area 75000, length 1300, exactly
```

## Contents

- [How the corpus is built](#how-the-corpus-is-built)
- [Coordinate system](#coordinate-system)
- [Reading a manifest](#reading-a-manifest)
- [Geometric fixtures](#geometric-fixtures)
- [Page-geometry fixtures](#page-geometry-fixtures)
- [Content fixtures](#content-fixtures)
- [Hostile fixtures](#hostile-fixtures)
- [Synthetic drawing sheets](#synthetic-drawing-sheets)
- [Caching and determinism](#caching-and-determinism)
- [What the corpus does not cover](#what-the-corpus-does-not-cover)

---

## How the corpus is built

Every fixture except one is serialised by a small hand-written PDF writer
(`RawPDFWriter`, `PDFDocumentBuilder`, `PDFContentStream`) rather than by
`CGPDFContext`. That is a deliberate choice, for two reasons.

1. **`CGPDFContext` cannot express most of what the corpus needs.** There is no API for
   page `/Rotate`, for an exact form-XObject `/Matrix`, for a cyclic page tree, for a
   deliberately wrong cross-reference table, or for an object that is declared and then
   missing. Those fixtures would have to be hand-written regardless.
2. **`CGPDFContext` re-encodes coordinates at its own precision.** The central promise
   of this corpus is that the number in the manifest is byte-for-byte the number in the
   file, so that a consumer comparing an extracted coordinate against the manifest at
   `1e-9` page points is comparing like with like. `PDFNumber.string(_:)` emits the
   shortest representation that parses back to the identical `Double`, and
   `PDFNumber.roundTrips(_:)` is asserted over every manifest coordinate in the test
   target.

The single exception is `hostile-encrypted-user-password`, which **is** produced by
`CGPDFContext` with `kCGPDFContextUserPassword`. A hand-rolled standard security handler
would be a fixture testing our own encryption code; the OS's output is what a real
encrypted PDF looks like.

There are no third-party dependencies, and no dependency on any other Zenit package.

## Coordinate system

PDF points, 72 per inch, origin at the lower-left corner, y increasing
upwards, `/Rotate` explicit. Manifest coordinates are **page-space coordinates with every
form `/Matrix` and every `cm` already composed in**, so a consumer never has to reproduce
the transform stack to know where geometry landed. Where a path lives inside a form
XObject the manifest also records `sourcePoints` (untransformed) and `transform` (the
composed matrix), so an extractor's transform handling can be checked independently.

`/Rotate` is a presentation instruction. It does not move page-space geometry, and the
rotation fixtures' coordinates are stated pre-rotation.

## Reading a manifest

| Field | Meaning |
|---|---|
| `pages` | One `FixturePage` per page: media box, crop box, `declaresCropBox`, rotation, clip path, whether the page has text or raster content. |
| `paths` | Every drawn path, with page-space `points`, `holes`, `cubics`, `length`, `area`. |
| `texts` | Every searchable string, with its exact baseline origin, size and font. |
| `rasters` | Every image, with placement, pixel dimensions and colour space. |
| `derivation` | Per path: how `length` and `area` were derived (QUALITY_BAR 2.6). `method` can never be `code_under_test` — the enumeration has no such case. |
| `derivation.conditionNumber` | κ = Σ\|xᵢyᵢ₊₁ − xᵢ₊₁yᵢ\| / \|Σ(xᵢyᵢ₊₁ − xᵢ₊₁yᵢ)\|, for the M-A3 bound. Note that κ depends on distance from the origin, so two congruent rectangles at different positions have different κ. |
| `derivation.magnitudeFloor` | The floor in `rel(a, b) = \|a − b\| / max(\|b\|, floor)`. |
| `hostileTraits` | What is wrong with the file, for the hostile corpus. |
| `isStructurallyValid` | `false` when the file is deliberately not a conforming PDF, so a test must not require it to open. |

For an **open** path, `length` is the polyline length and `area` is `0`. For a **closed**
path, `length` is the total boundary length including every hole, and `area` is the net
enclosed area.

---

## Geometric fixtures

All on a single US Letter page, `MediaBox [0 0 612 792]`, no rotation, no crop box.

### `geo-single-line` — one line, length exactly 500

| | |
|---|---|
| **For** | The smallest possible length check. |
| **Path `line`** | Open, `(100, 100) → (400, 500)`. |
| **Truth** | `sqrt(300² + 400²) = 500`. A 3-4-5 triple, so exact in binary floating point. |

### `geo-rectangle` — 288 × 180

| | |
|---|---|
| **For** | Closed-form area and perimeter for the simplest closed shape (QUALITY_BAR M-A1). |
| **Path `rect`** | Closed, corners `(72,72) (360,72) (360,252) (72,252)`. |
| **Truth** | Area `288 × 180 = 51 840`. Perimeter `2 × (288 + 180) = 936`. κ = 1.65. |

### `geo-l-shape` — concave hexagon

| | |
|---|---|
| **For** | A concave polygon. Catches implementations that assume convexity. |
| **Path `l-shape`** | Closed, `(100,100) (400,100) (400,250) (250,250) (250,450) (100,450)`. |
| **Truth** | Decomposition into two disjoint rectangles: `300×150 = 45 000` plus `150×200 = 30 000`, total **75 000**. Perimeter `300+150+150+200+150+350 = 1300`. κ = 1.8666666666666667. |

### `geo-polygon-one-hole` — 400 × 400 square, one 100 × 100 hole

| | |
|---|---|
| **For** | Net area with a single cutout; even-odd versus non-zero fill. |
| **Path `square-one-hole`** | Outer ring counter-clockwise `(100,100) (500,100) (500,500) (100,500)`; hole clockwise `(200,200) (200,300) (300,300) (300,200)`. |
| **Truth** | Area `160 000 − 10 000 = 150 000`. Boundary `4×400 + 4×100 = 2000`. κ = 1.9333333333333333. |
| **Note** | Outer CCW, hole CW, so non-zero and even-odd produce the same filled region. |

### `geo-polygon-three-holes` — 400 × 400 square, three holes

| | |
|---|---|
| **For** | Multiple cutouts of differing size; hole ordering must not matter. |
| **Holes** | 100 × 100 at (150,150); 50 × 50 at (350,150); 80 × 60 at (200,350). |
| **Truth** | Area `160 000 − (10 000 + 2 500 + 4 800) = 142 700`. Boundary `1600 + 400 + 200 + 280 = 2480`. κ = 2.468815697267694. |

### `geo-bezier-circle` — circle of radius 144 as four cubics

| | |
|---|---|
| **For** | Curve flattening, arc length and circle fitting, with the approximation error written down so a test never mistakes the approximation for a defect. |
| **Geometry** | Centre `(306, 396)`, radius `R = 144`. Four cubics with control offset `K·R`, `K = 4/3·(√2 − 1) = 0.5522847498307935`, `K·R = 79.52900397563425`. All four sets of control points are in `paths[0].cubics`. |
| **`length`** | The **true circle's** circumference, `2πR = 904.7786842338604`. |
| **`area`** | The **true circle's** area, `πR² = 65144.06526483795`. |
| **Exact Bézier area** | `R²·(−3/5·K² + 12/5·K + 2) = 65162.30628996533`, from Green's theorem `∮(x dy − y dx)/2` over the four cubics. That is `1.0002800105436 ×` the true circle. |
| **Max radial error** | `2.725300074275516e-4 · R = 0.03924432106956743` page points, at `t ≈ 0.211325` on each arc. The manifest carries a strict upper bound of `2.7254e-4` relative. |

**How to assert.** Either compare against `πR²` with a tolerance of at least the recorded
`2.8001e-4` relative area excess, or compare against the exact Bézier area
`65162.30628996533` at `1e-9`. Do not compare a flattened trace against `πR²` at `1e-9`;
that asserts that the four-arc approximation is a circle, which it is not.

### `geo-nested-form-xobjects` — two levels, non-identity matrices at both

| | |
|---|---|
| **For** | Transform composition. An extractor that drops or misorders a form `/Matrix` misses the manifest by a visible margin. |
| **Structure** | Page CTM at the outer `Do` is `[1 0 0 1 40 30]`. Outer form `/Matrix [1.5 0 0 1.5 20 10]`. Inner form `/Matrix [2 0 0 2 10 5]`. |
| **Composed** | Outer: `[1.5 0 0 1.5 60 40]`. Inner: `[3 0 0 3 75 47.5]`. |
| **Path `outer-form-rect`** | Source 100 × 50 at origin; page space `(60,40) (210,40) (210,115) (60,115)`; perimeter `2×(100+50)×1.5 = 450`; area `100×50×1.5² = 11 250`. κ = 1.9333333333333333. |
| **Path `inner-form-rect`** | Source 30 × 20 at origin; page space `(75,47.5) (165,47.5) (165,107.5) (75,107.5)`; perimeter `2×(30+20)×3 = 300`; area `30×20×9 = 5400`. κ = 2.625. |
| **The classic bug** | PDF composes a form's `/Matrix` **before** the CTM in force at `Do`. Reversing the order gives `[1.5 0 0 1.5 50 40]` for the outer form. |

### `geo-clipped-content` — geometry crossing a clipping path

| | |
|---|---|
| **For** | A reader that ignores `W n` reports the full path instead of the visible one. |
| **Clip** | `[200 200 400 400]`, installed with `re W n` before any painting. |
| **Path `crossing-line`** | `(100,300) → (500,300)`. `length` 400, `clippedVisibleLength` **200**. |
| **Path `overhanging-rect`** | Filled `[150 450] × [150 450]`. `area` 90 000, `clippedVisibleArea` **40 000**. `clippedVisibleLength` **0** — no part of the rectangle's own boundary lies inside the clip box. κ = 2.0. |

### `geo-giant-background-rectangle` — something enormous for snap to ignore

| | |
|---|---|
| **For** | Snap must prefer the two small paths. An implementation that scores by proximity alone snaps to the background edge from anywhere on the page. |
| **Path `background`** | Full media box, `area = 484 704`, `isBackground = true`. **Snap and measurement must never select this path.** |
| **Path `foreground-line`** | `(200,200) → (400,200)`, length 200. |
| **Path `foreground-rect`** | 120 × 80 at (250,300); area 9600; perimeter 400. κ = 6.833333333333333. |

### `geo-ten-thousand-segments` — extraction and snap-index stress

| | |
|---|---|
| **For** | Throughput and index construction at a scale where an O(n²) candidate search shows up immediately. |
| **Geometry** | A closed-form lattice, no PRNG: `x = 6 + 6·column`, `y = 6 + 6·row`, `column, row ∈ 0..<100`. Each segment is `(x, y) → (x+3, y+4)`. |
| **Truth** | Every segment is a 3-4-5 triple, so its length is exactly **5**. 10 000 segments, total length exactly **50 000**. |
| **Manifest** | Carries all 10 000 paths, `seg-0` … `seg-9999`; segment *i* is at column `i % 100`, row `i / 100`. |
| **File** | Content stream is Flate-compressed; ≈ 40 KB on disk. |

### `geo-huge-malformed-operator-stream` — one page, one megabyte of token soup

| | |
|---|---|
| **For** | The extractor must terminate, allocate nothing unbounded, and report a typed error or an empty page — never hang. |
| **Structure** | Page dictionary, page tree and xref are all **valid**. Only the content stream is nonsense. |
| **Contents** | ≈ 1 048 576 bytes, stored uncompressed. Unknown operators (`zzq`, `qqqq`), wrong operand counts, unbalanced `Q`, references to resources that do not exist. |

---

## Page-geometry fixtures

### `page-rotation-0` / `-90` / `-180` / `-270`

| | |
|---|---|
| **For** | Golden coordinate tests. `/Rotate` must be honoured for display without moving page-space geometry. |
| **Page** | Letter, `/Rotate` 0 / 90 / 180 / 270. |
| **Path `rotation-marker`** | Asymmetric open polyline `(72,72) → (72,672) → (172,672)`, length `600 + 100 = 700`. Asymmetric on purpose: a rotation applied in the wrong direction is visible rather than self-cancelling. |

### `page-crop-smaller-than-media`

| | |
|---|---|
| **For** | The crop box, not the media box, defines the visible page. |
| **Boxes** | `MediaBox [0 0 612 792]`, `CropBox [72 72 540 720]` — 468 × 648 visible. |
| **Path `crop-marker`** | 200 × 150 at (100,100); area 30 000; perimeter 700; κ = 2.1666666666666665. A converter that silently rebases on the crop box reports `(28, 28)` for the lower-left corner. |

### `page-crop-negative-origin`

| | |
|---|---|
| **For** | Nothing may assume a box origin at `(0, 0)`. |
| **Boxes** | `MediaBox [-100 -50 512 742]` (612 × 792), `CropBox [-50 -25 250 375]` (300 × 400). |
| **Path `negative-origin-line`** | `(-100,-50) → (140,270)`, length `sqrt(240² + 320²) = 400` — a 3-4-5 triple scaled by 80. The line starts exactly on the media-box corner. |

### `page-mixed-sizes` — four pages, four sizes

| Page | Size | Media box |
|---|---|---|
| 0 | US Letter | 612 × 792 |
| 1 | ISO A4, 210 × 297 mm | 595.2755905511812 × 841.8897637795277 |
| 2 | ISO A1, 594 × 841 mm | 1683.7795275590554 × 2383.937007874016 |
| 3 | ARCH D, 24 × 36 in | 1728 × 2592 |

Each page carries a border rectangle inset 36 pt on every side; the manifest states its
area as `(w − 72)·(h − 72)` and its perimeter as `2·((w − 72) + (h − 72))`. A reader that
caches the first page's box reports the wrong size for pages 1 to 3.

### `page-size-a1` and `page-size-arch-d`

Single sheets at construction dimensions, so page-box handling is exercised at the sizes
Zenit meets in the field. Each carries a border inset 36 pt and a **scale bar of exactly
1000 points** (`scale-bar`), which gives a calibration test an exact reference length.
ARCH D border: 1656 × 2520, area **4 173 120**, perimeter **8352**.

### `page-300-pages` and `page-1000-pages`

| | |
|---|---|
| **For** | Page-tree traversal, page-count reporting and lazy page loading at a scale where eager loading is measurably wrong. |
| **Pages** | 300 / 1 000 uniform Letter pages. |
| **Per page** | Marker line `(72,72) → (172,72)`, length exactly **100**, plus the searchable string `PAGE n OF 300` / `PAGE n OF 1000` at baseline `(72, 40)`, Helvetica 10 pt. |
| **Generation** | Streamed object by object straight to the file. Peak generator memory is one page, not one document. `page-1000-pages.pdf` is ≈ 314 KB. |

---

## Content fixtures

### `content-title-block-sheet` — ARCH D drawing sheet

| | |
|---|---|
| **For** | Text extraction and search: nine strings at exactly known baseline origins, five of them inside the title block, plus four measurable rectangles. |

Paths:

| id | Geometry | Area | Perimeter | κ |
|---|---|---|---|---|
| `border` | `[36 36 1692 2556]`, 1656 × 2520 | 4 173 120 | 8352 | 1.036024844720497 |
| `title-block` | `[1128 36 1692 288]`, 564 × 252 | 142 128 | 1632 | 3.142857142857143 |
| `room-101-outline` | 720 × 576 at (144, 1728) | 414 720 | 2592 | 4.2 |
| `room-102-outline` | 720 × 576 at (864, 1728) | 414 720 | 2592 | 5.2 |

The two rooms are congruent and differ only in position, so a search result must be
disambiguated by coordinate, not by area. Their κ differ because κ depends on distance
from the origin.

Strings, all Helvetica with WinAnsiEncoding, placed with an explicit `1 0 0 1 x y Tm`, so
the recorded origin is the exact baseline origin of the first glyph:

| id | text | origin | size | title block |
|---|---|---|---|---|
| `title` | `ZENIT PDF FIXTURE SHEET` | (1152, 240) | 18 | yes |
| `drawing-number` | `DRAWING NO ZP-0001` | (1152, 204) | 12 | yes |
| `scale` | `SCALE 1:50` | (1152, 168) | 12 | yes |
| `revision` | `REVISION A` | (1152, 132) | 12 | yes |
| `date` | `DATE 2026-01-01` | (1152, 96) | 12 | yes |
| `room-101` | `ROOM 101` | (200, 2000) | 14 | no |
| `room-102` | `ROOM 102` | (920, 2000) | 14 | no |
| `corridor` | `CORRIDOR` | (200, 1600) | 14 | no |
| `grid` | `GRID A1` | (120, 120) | 10 | no |

### `content-scanned-look-page` — no text layer at all

| | |
|---|---|
| **For** | The OCR path and the "Vector Snap unavailable" path. |
| **Content** | One 612 × 792 `DeviceGray`, 8 bits-per-component image at 1 sample per point, filling the media box. |
| **Truth** | Text extraction must return **nothing**, and vector extraction must return **no paths**. The page dictionary carries no `/Font` resource at all, so there is nothing to find even by accident. Verified: PDFKit returns a zero-length string for this page. |
| **Determinism** | The bitmap is generated by a fixed linear-congruential rule, so the bytes are identical on every run and machine. |

### `content-mixed-text-and-raster` — the realistic case

| | |
|---|---|
| **For** | A scanned detail pasted onto a vector sheet. Vector snap must work below `y = 396` and report unavailable above it. |
| **Raster** | `[0 396 612 792]`, 612 × 396 `DeviceGray`. |
| **Path `vector-line`** | `(72,120) → (372,120)`, length 300. |
| **Text** | Exactly three strings: `VECTOR LAYER BELOW` (72, 300), `SCANNED BLOCK ABOVE` (72, 270), `ROOM 201` (72, 240), Helvetica 12. The raster contains glyph-shaped marks that are **not** text and must not appear in extraction output. |

---

## Hostile fixtures

A PDF is hostile data. These are real files so that security tests can be real rather
than hypothetical. The expected result for most of them is a **typed error**, not a
number. `isStructurallyValid` is `false` for the four that are not conforming PDFs; a
test must not require those to open.

Observed behaviour of PDFKit on this machine is recorded below as a sanity reference, not
as a requirement — Zenit's own reader is what the downstream tests judge.

### `hostile-truncated`

A well-formed two-page document cut off at 55 % of its length. No `trailer`, no
`startxref`, no `%%EOF`. The surviving prefix is byte-identical to the first 55 % of the
intact document, so the failure is purely a missing tail. *PDFKit: refuses to open.*

### `hostile-broken-xref`

Correct objects; every cross-reference offset is wrong by exactly 37 bytes. 37 is prime
and larger than any object header in the file, so no offset accidentally lands on a valid
`N 0 obj` boundary. The trailer, `/Root` and `%%EOF` are all present and correct. A
reader that trusts the table finds garbage; one that reconstructs it recovers the
document. Either outcome is acceptable — a crash is not. *PDFKit: refuses to open.*

### `hostile-cyclic-page-tree`

- object 2 is `/Pages` with `/Kids [3 0 R]`
- object 3 is `/Pages` with `/Parent 2 0 R /Kids [4 0 R 2 0 R]` — the second kid is its own parent
- object 4 is the one real page

`/Count` claims 2 while only one page exists, so a reader that trusts `/Count` allocates
for a page it will never find. A depth-first walk without a visited set recurses forever.
*PDFKit: opens, reports 2 pages.*

### `hostile-missing-object`

The page's `/Contents` and `/Font` both point at `9999 0 R`, which the file does not
contain, and `/Size` in the trailer counts only the objects that exist. A second defect
is layered on: object 2's body is claimed by the xref table but omitted from the file
body. A dangling indirect reference must resolve to null, not to a wild read.
*PDFKit: opens, reports 1 page.*

### `hostile-deeply-nested-forms`

100 form XObjects, each drawing the next, each with `/Matrix [1 0 0 1 1 1]`. The
innermost form draws `(0,0) → (50,0)`; in page space that is `(100,100) → (150,100)`.
Because each level contributes exactly one unit of translation, **an extractor that stops
early lands short by the number of levels it skipped**, which makes the truncation depth
directly measurable. The file is structurally valid; the hazard is depth, not corruption.
An extractor must impose and enforce a nesting cap without blowing the stack.

### `hostile-decompression-bomb`

| | |
|---|---|
| **On disk** | ≈ 131 KB |
| **Inflated** | 67 108 864 bytes (64 MiB), recorded in `manifest.declaredInflatedByteCount` |
| **Ratio** | ≈ 512 : 1 |

The declared `/Length` is the *compressed* length, as the format requires, so the inflated
size is not discoverable without inflating. The inflated payload is valid PDF content
syntax, so a reader cannot bail out on a syntax error before it has already allocated.
Decompression must be capped.

### `hostile-encrypted-user-password`

| | |
|---|---|
| **User password** | `zenit-fixture-user` (`ZPDFFixtures.encryptedUserPassword`) |
| **Owner password** | `zenit-fixture-owner` (`ZPDFFixtures.encryptedOwnerPassword`) |
| **Content** | The same 3-4-5 line as `geo-single-line`, so decrypted extraction can be compared against it directly. |

Opening without a password must fail with a typed error and must never prompt. Produced
by `CGPDFContext`, so the encryption dictionary is whatever the current OS emits rather
than a hand-rolled one that might match no real writer. This is the only fixture whose
bytes are not fixed by `ZPDFTestingSupport`.

### `hostile-embedded-file-launch-action`

A real `/EmbeddedFile` stream named `zenit-payload.sh`, reachable through
`/Names /EmbeddedFiles`, plus `/OpenAction << /S /Launch /F (zenit-payload.sh) >>`. The
payload is inert — it echoes a string. Zenit must never execute, extract or offer to open
an embedded file, and must never honour a `/Launch` action. **A reader that surfaces the
attachment in a UI has already failed this test.**

### `hostile-javascript`

`app.alert('ZPDFTestingSupport javascript fixture');`, reachable twice: through
`/Names /JavaScript` and through `/OpenAction`. Harmless, and observable if it ever runs.
Zenit executes no PDF JavaScript, ever.

## Synthetic drawing sheets

Four fixtures stand in for a real construction drawing wherever a test needs a heavy,
realistic A1 sheet: tracing caps, Detect Rooms, symbol matching, the scale proposal's
title-block reading, the CORE_LOOP acceptance walk and the viewer's millisecond budgets.
They are drawn from scratch: every coordinate is a design decision written in
`Sources/ZPDFTestingSupport/Fixtures/SyntheticRoofPlan.swift` (`SyntheticRoofPlan`), and
every number below is derived by hand from those coordinates. None was read back from the
code under test. No real drawing, name, address or project appears anywhere in them.

Use them through `ZPDFFixtures.shared(_:)` (a per-user cache directory, for read-only
use) or `ZPDFFixtures.make(_:in:)` (a directory the caller owns, when the file may be
modified or its directory deleted).

### `synthetic-roof-plan` — the Synthetic Roof Plan, version 1

| | |
|---|---|
| **Page** | One page, `/MediaBox` = `/CropBox` = `[0 0 2383.94 1683.78]` (ISO A1 landscape), no `/Rotate`, no optional content, no annotations. |
| **Scale** | Drawn at 1:50: one point is 50 × 0.0254 / 72 = 1.27 / 72 = 0.0176388… m of building. |
| **Identity** | `synthetic-roof-plan/1`, SHA-256 `424c2fad6aa7284bcdc410d9c209c24d10e7eac8b4d1027dd4fd1b2952295d44`, 1 398 025 bytes. Pinned in `SyntheticRoofPlan.sha256` / `.byteCount`, in `Tests/CoreLoop` and in `Scripts/acceptance-core-loop.sh`. A change that moves one byte bumps `SyntheticRoofPlan.version` and every pin, and `FixtureRegistry.generatorVersion`. |
| **Encoding** | Content stream stored uncompressed; both rasters `/RunLengthDecode`, encoded by this package. No platform compressor, so the bytes are the same on every macOS. |

**What is drawn**, in page points:

| Part | Geometry |
|---|---|
| Sheet border | `re` 14 14 2355.94 1655.78, 0.992 pt. |
| Title column | Divider x = 2050 (full height); title block below y = 640 with rules at y = 640, 510, 460, 410, 360, 310, 260, 210, 160, 110 and bottom-row dividers x = 2190, 2280. Notes column above. |
| Control ruler | Base line (1050, 42) → (1050 + 36000/127, 42) = (1333.464566929134, 42): **100 mm of paper** = 100 × 72 / 25.4 = 36000/127 pt, 5 000 mm at 1:50. Eleven ticks at x = 1050 + 3600·k/127, 1800/127 pt (5 mm) tall. |
| Free measuring band | x 1720…2045, y 520…1200: nothing is drawn within 40 pt of it except the title-column divider, 5 pt beyond its right edge. A pick anywhere inside never snaps. |
| House, hip roof | Eaves (900, 300)–(1500, 1300). Ridge (1200, 600)–(1200, 1000). Hips from the four corners; the north-east hip is kinked at (1340, 1120). |
| Snow guard | Strip x 1483…1486, y 480…760, tied to the east eave by one stub (1486, 620)–(1500, 620). |
| Grid axes | Dash-dot, written **one stroke per dash and per dot**: 20 pt dash, 3.5 gap, 5 dot, 3.5 gap (period 32). A: y = 456, x 917.25→1557.25; B: y = 800, x 908→1548; C: y = 1150, x 910.5→1550.5 (640 pt = 20 periods = 40 elements each). 1: x = 1000, y 230→1370; 2: x = 1406, y 228→1368 (1140 pt = 35 periods + a 20 pt dash = 71 elements each). Each axis is labelled in a radius-12 circle 20 pt beyond its east or north end. |
| Sedum annex | Outline (460, 300)–(880, 1300); hips (460, 300)–(880, 720) and (460, 1300)–(880, 880). |
| Sedum hatch | Glyphs of three strokes from a base point to (−2.125, +1.25), (0, +2.5), (+2.125, +1.25) — neighbouring tips 2.4654 pt apart, inside the tracer's 3 pt bridging tolerance, the outer two 4.25 pt. Triangular lattice: rows y = 305 + 5r (r = 0…197), x = 467 + 17c on even rows and 475.5 + 17c on odd rows (c = 0…23): 4 752 points. Laid **face by face**, as a CAD hatch fills region by region: a glyph is drawn only when its base and three tips lie on one side of each hip, at least 0.5 pt clear. With s = x − y − 160 and u = x + y − 1760 at the base, that leaves out −1.5 ≤ s ≤ 4 and −4 ≤ u ≤ 1.5 (exact on this half-integer lattice): **57** points, **4 695 glyphs, 14 085 strokes**. Every stroke is its own path in its own `q … Q` with `/GS0 gs`, a line width and an RGB colour. |
| Symbols "TH" | Two concentric frames as eight lines: inner 40 × 28, outer 50 × 35 (exactly 1.25 × the inner). Centres (1040, 1060), (1040, 990), and (1100, 640) turned a quarter. "TH" is text. Distractors: square-in-square (28 and 40 pt) at (1100, 710); a 44 pt square round a radius-15 circle at (1115, 990). |
| Load | A paved forecourt: 14 rows × 121 vertical 8 pt strokes, 12 pt apart, x = 90 + 12c, y = 1450 + 12r. Two boundary fences of 62 slats, x 335→450 and 1605→1675, slat k from y = 305 + 16k rising 4 pt. Sixteen facet labels, notes, a graphic scale bar of ten `re` boxes, a north arrow. |
| Rasters | 944 × 275 and 90 × 944 DeviceRGB, each with a 1-bit `/ImageMask` as `/Mask`, in the title block (the second turned a quarter into a 226.8 × 21.8 pt strip). |
| Title block | Fictional: EXEMPELPROJEKT, A-00-0-001, DEMO ROOF, EXEMPELARKITEKTER AB, A. Berg, B. Lund. Words are written as separate strings of one `TJ` array (−278 between them) so the text layer gives each word its own box. "SKALA" (6.5 pt) at (2196, 101) over "1:50" (13 pt) at (2196, 84); the area field "KV" at (2056, 434) and "1:10 EXEMPELPARK" at (2106, 434) — two runs, 32.66 pt apart: wider than the bridge's column-gutter split (3 × the median glyph width), narrower than the scale proposer's left-neighbour reach (4 heights). The only ratios on the sheet are these two. |

**Vector primitives on page 0** (one per open segment; a `re` is a rectangle primitive and
its four edges; a closed four-curve circle a closed-subpath primitive and its four curves; a
closed filled triangle a closed subpath and its three edges):

| Part | Count |
|---|---:|
| Sheet border (`re`) | 5 |
| Title-column divider, title-block rules, bottom-row dividers | 1 + 10 + 2 = 13 |
| Control ruler | 1 + 11 = 12 |
| Graphic scale bar, ten `re` | 50 |
| North arrow: filled triangle and ring | 4 + 5 = 9 |
| Sedum hatch | 4 695 × 3 = 14 085 |
| Annex outline and hips | 4 + 2 = 6 |
| House: four eaves, four hips (the kinked one two segments), ridge | 4 + 5 + 1 = 10 |
| Snow guard and stub | 4 + 1 = 5 |
| Grid axes | 3 × 40 + 2 × 71 = 262 |
| Axis label circles | 5 × 5 = 25 |
| Symbols | 3 × 8 = 24 |
| Distractors | 8 + 4 + 5 = 17 |
| Paving | 14 × 121 = 1 694 |
| Fences | 2 × 62 = 124 |
| **Total** (`manifest.vectorPrimitiveCount`) | **16 341** |

**Hand-derived values the tests assert:**

| Value | Derivation |
|---|---|
| East facet, 5 corners (1200, 600) (1500, 300) (1500, 1300) (1340, 1120) (1200, 1000) | Over x = 1200…1500, under the kinked hip 140·(1000 + 1120)/2 + 160·(1120 + 1300)/2 = 342 000, under the lower hip 300·(600 + 300)/2 = 135 000: **207 000 pt²** = 207 000 × 1.6129 / 5184 = **64.403993 m²** ("64.40 m²"). κ = 2 586 000 / 414 000. |
| South facet (900, 300) (1500, 300) (1200, 600) | 600 × 300 / 2 = **90 000 pt²** (28.0017 m²). κ = 5. |
| West facet (900, 300) (1200, 600) (1200, 1000) (900, 1300) | 300 × (1000 + 400) / 2 = **210 000 pt²**. κ = 2 220 000 / 420 000. |
| North facet (1200, 1000) (1340, 1120) (1500, 1300) (900, 1300) | 600 × 1300 − 345 000 − 342 000 = **93 000 pt²**. κ = 1 506 000 / 186 000. |
| Snow guard | 3 × 280 = **840 pt²** = **0.2613 m²** ("0.26 m²"), offered as an island, never deducted. |
| Annex middle face (460, 300) (880, 720) (880, 880) (460, 1300) | 420 × (1000 + 160) / 2 = **243 600 pt²**, traced exactly: a hatch cell that only a bridge closes against the face's boundary is part of the face, not a hole in it. |
| Annex lower and upper faces | 420² / 2 = **88 200 pt²** each, traced exactly on the same rule. |
| Symbol positions | Concentric frames: the feature-point centroid of either frame is the centre itself — (1100, 640), (1040, 990), (1040, 1060). |
| Calibration on the ruler | Δx = 1333.464566929134 − 1050 = 283.464566929134 pt; 5 m / Δx = 0.01763888888888888 m/pt = 1.27/72 to the last bit but one: the printed 1:50. |

**Why the axes start where they do.** The tracer bridges a loose end within 3 pt of a line
and fuses points within 0.75 pt. An axis element ending that close to an eave, hip or
ridge would bridge back to it and cut a sliver off a facet, so every element ends at least
4 pt from every boundary line (`SyntheticRoofPlanTests.axisEndsClearOfBoundaries`). The
tracer also reads a dash-dot line through a room as an axis only when the pattern goes on
past both walls it crosses (`DashedLineProbe`, rule 2), so A, B and C start inside the
west facet rather than one dash outside it.

**Why the hatch skips 57 lattice points.** Hatch laid face by face, as CAD fills it, never
crosses a hip, and this sheet is laid that way. With glyphs crossing a hip line the tracer
once dropped the hip and traced two faces as one: on the annex alone — outline, both hips,
and only the glyphs at (484, 1275), (526.5, 1230) and (535, 1225), all on the upper hip's
lower side or on it — a click at (800, 1178.75) traced 331 800 pt², the middle and upper
faces together. That tracer defect is fixed, and the crossing case is covered by
`HatchAcrossHipTraceTests` in `ZPDFSnapEngine`. The fixture still leaves the 57 glyphs out,
and its bytes are unchanged.

### `synthetic-roof-plan-set` — three sheets for Prepare This Set

Page 1 and page 3 reference the **same** roof-plan content stream object; page 3 appends a
second stream (a red 120 × 80 rectangle at (1560, 1420) and a line). Page 2 is
2 700 × 3 100 mm (`[0 0 7653.54… 8787.40…]`): twelve 1400 × 1900 rooms and the runs
`RITNINGSNUMMER A-00-0-200` and `SKALA 1:100` in 40 pt Helvetica. Expected scales:
1:50, 1:100, 1:50.

### `synthetic-roof-plan-layered` — the roof plan on two optional-content groups

The same drawing with the hatch inside `/OC /L0 BDC … EMC` (group "Hatch") and the axes
with their label circles inside `/OC /L1` ("Grid"), both on by default. 14 085 primitives
carry layer `L0`, 287 (262 axis elements + 25 circle primitives) carry `L1`. The underlay
compiler draws one markup per open segment and per closed shape: 16 341 − 75 shape edges
= 16 266; hiding `L0` removes 14 085, hiding `L1` 262 + 5.

### `synthetic-wall-module` — Find Walls with classes derivable by hand

A1, nominal 1:50 (56.692913… pt per metre; 1 mm of building = 72 / 25.4 / 50 pt). Outer
wall: rectangle `[300 300 1300 900]` and its inner face 1800/127 pt (250 mm) inside it, as
eight separate lines. Partition: faces x = 800 and 800 + 864/127 (120 mm), from the inner
bottom face to the inner top face, broken by a door from y = 500 to 550. Hatch: 20 lines,
x 1500…1800, at y = 300 + k · 648/127 (90 mm). 32 primitives. With the engine's options at
1:50 (thickness 50…600 mm, bins of 10 mm, a class needs 2 m of facing length): walls 120
and 250 mm, repeating nowhere; hatch classes at k × 90 mm for k = 1…6 (630 mm is out of
band), each with (20 − k) × 300 pt of facing length, repeating over all of it. Shown walls
first: **120, 250, 90, 180, 270, 360, 450, 540** — no two within the 2 × 7.5 mm a class
claims.

### Calibration of the load

The viewer's millisecond budgets (`Docs/Execution/quality-thresholds.json`, Z1–Z15) were
first measured on a real CAD-exported A1 roof plan that cannot ship with this repository.
The synthetic sheet replaces it unchanged, so its load was tuned to that sheet's measured
cost, not to the budgets.

Method: a standalone harness replaying the viewer's viewport-raster call path
(`PDFKitDocumentProvider.rasterise`: a 32-bit premultiplied context, white fill,
`.high` interpolation, `PDFPage.draw(with: .cropBox, to:)`) over the zoom ladder 0.05,
0.5939 (fit), 1, 2, 4, 8 with the benchmark's centred 1600 × 1000 pt window and 64 pt
overscan, cold (fresh document) and warm (3 blocks of 40), both sheets in the same minute.

What the measurements showed, and what the sheet does about it:

- **Per-stroke graphics-state groups.** The real sheet writes ~16 000 single-segment
  strokes, each as `q /G gs r g b RG w m l S Q`. The synthetic sheet writes its strokes
  the same way.
- **PDFKit caches a page above a complexity threshold.** Warm re-renders of the real sheet
  ran 2.5–11 ms against 17–28 ms cold; a first synthetic draft with 14 700 painted paths ran
  as slow warm as cold (16–43 ms) — below the threshold, nothing was reused. Adding the
  paving and the fences (about 1 800 more paths, ~16 300 in all, the real sheet's count)
  brought the warm figures to the real sheet's.
- **Where the load sits.** The real sheet's hatch reaches into the central viewports
  (~2 300 short strokes inside the zoom-2 window); the annex was placed so the synthetic
  hatch does too, and the fences add long lines in the zoom-1 window. A raster in the
  centre was tried and rejected: up-sampled at 400–800 % it cost 8–25 ms where the real
  sheet costs 2–3 ms.

Harness figures, same machine, same minute (worst over the ladder, milliseconds):

| | cold | warm p50 | warm p95 |
|---|---:|---:|---:|
| Real A1 | 25.9 – 28.3 | 9.9 – 11.2 | 11.9 – 14.5 |
| Synthetic Roof Plan | 25.7 – 27.7 | 8.1 – 9.6 | 8.6 – 11.2 |

The synthetic sheet is at most about 15 % cheaper in warm p50 at zoom 1 and 2, and level
cold. For reference, the real sheet's pooled Z3 warm p50 in release ran 10–12.7 ms across 48
settled runs (`Scripts/verify-viewer-budgets.sh`, header).

The viewer gates measured on the synthetic sheet when it was introduced (2026-10-27, one run
each, the same machine):

| Gate | Budget (release / debug) | Release | Debug |
|---|---:|---:|---:|
| Z1 blit p50 | 2.0 / 2.0 ms | 0.561 | 0.548 |
| Z3 warm p50 (worst zoom) | 16 / 29 ms | 8.381 | 9.223 |
| Z3 warm p95 (worst zoom) | 40 / 65 ms | 9.078 | 9.936 |
| Z4 cold p95 | 120 / 120 ms | 26.746 | 25.612 |
| Z11 frame p50 / p99 | 2.0 / 4.0 ms (release) | 0.154 / 1.478 | 0.298 / 1.947 |
| Z12 blank frames | 0 | 0 | 0 |
| Z13 settle p50 / p95 | 100 / 200 ms (release) | 33.651 / 94.420 | 57.451 / 100.695 |
| Z14 landing p99 | 2.0 ms (release) | 1.327 | 1.889 |
| Z15 select p50 / p99 | 2.5 / 4.5 ms (release) | 1.218 / 2.318 | 1.786 / 2.596 |
| Z15 loupe p50 / p99 | 3.0 / 6.5 ms (release) | 1.843 / 3.988 | 2.087 / 3.600 |

No budget was changed.

---

## Caching and determinism

**Caching is on disk, not in a process-wide table.** Alongside `rectangle.pdf` the
generator writes `rectangle.pdf.stamp` recording the generator version and the byte
count; a later `make` for the same kind in the same directory reuses the file when the
stamp matches, and regenerates when it does not. One temporary directory per test run
therefore gives exactly "cache per test run", with no shared mutable state and no
locking — which matters, because the house rules forbid `@unchecked Sendable` and this
API is synchronous by design. `FixtureHandle.wasGenerated` reports which happened.

**Every fixture except `hostile-encrypted-user-password` is byte-identical on every run
and every machine.** No `Date()`, no `UUID()`, no platform RNG, no CoreGraphics
re-encoding of coordinates. The bitmap fixtures use a fixed linear-congruential rule and
the stress lattice uses a closed-form rule rather than a seeded PRNG, so there is no seed
to record. This is asserted by `GeneratedFixtureTests.generationIsDeterministic`.

**Bump `FixtureRegistry.generatorVersion` whenever a fixture's bytes change.** Stale
files from an earlier version are then regenerated rather than reused. Per QUALITY_BAR
2.6, a commit that changes a fixture's *expected value* alongside engine source in C1, C2
or C3 needs a `FIXTURE-CHANGE:` trailer naming the ADR that justifies it.

## What the corpus does not cover

Stated plainly, so nobody assumes coverage that is not here.

- **No M-B fixtures.** Every number in this corpus is closed-form synthetic (QUALITY_BAR
  classes M-A1 and M-A3). Real traced drawings calibrated against a printed dimension are
  a separate body of work, and QUALITY_BAR 2.6 requires a second party to re-derive each
  of those values.
- **No annotations.** No markup, no widgets, no `/Annots` at all.
- **No colour spaces beyond DeviceGray and DeviceRGB** (the synthetic drawing sheets use
  RGB strokes and RGB rasters with 1-bit masks), no ICC profiles, no transparency groups,
  no blend modes, no soft masks, no shading patterns, no tiling patterns.
- **Optional content is covered by two fixtures only.** `content-three-layers` has four
  OCGs (a nested group, a radio group, a duplicate name, and "Grid", which is hidden by
  default and locked); `synthetic-roof-plan-layered` puts the roof plan on two groups, both
  on by default. There is no optional-content membership dictionary (`/OCMD`), no
  visibility expression and no layered form XObject.
- **No cross-reference streams or object streams** (PDF 1.5+ compressed xref). Every
  fixture uses a classic cross-reference table.
- **No embedded font programmes.** Text uses the base-14 fonts with WinAnsiEncoding, so
  there is no CID font, no ToUnicode CMap and no vertical writing mode.
- **No anisotropic or rotated CTMs** in the form-XObject fixtures; both levels are
  uniform scales plus translation, chosen so that length and area scale exactly. A shear
  or a rotation fixture belongs with the snap corpus.
- **Curves are circles only.** `geo-bezier-circle` is the one curve with a closed-form
  expected value; the synthetic roof-plan sheets (`synthetic-roof-plan`, its sheet set and
  its layered variant) also draw circles as four cubic Béziers — the axis-label circles,
  the north-arrow ring and the circle-in-square distractor — but assert nothing about their
  curvature. No arcs, no ellipses, no free-form curves and no cubic-cubic intersections
  yet; QUALITY_BAR S3 will need them.
