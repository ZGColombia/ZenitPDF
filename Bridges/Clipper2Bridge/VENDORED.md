# Vendored third-party source — Clipper2

| | |
|---|---|
| Upstream | https://github.com/AngusJohnson/Clipper2 |
| Upstream revision | `f9c5eb6e14a59f6f5d65fbfb3564519a561cf4fd` |
| Library version | development snapshot 16 commits after the `Clipper2_2.0.1` tag (`git describe --tags`: `Clipper2_2.0.1-16-gf9c5eb6`; tag `21ebba0`, 2025-12-20; pinned commit 2026-04-20), not the 2.0.1 release. `clipper.version.h` still reads `2.0.1`. |
| Licence | Boost Software License 1.0 — see `LICENSE-Clipper2.txt`. The upstream licence file names no holder; the vendored source headers state "Copyright : Angus Johnson", with year ranges from 2010-2023 (`clipper.minkowski.h`) to 2010-2026 (`clipper.engine.cpp`, `clipper.triangulation.cpp`). |
| Vendored on | 2026-08-23 |
| Vendored by | Zenit PDF maintainers |
| Local clone used | an upstream clone at `ExternalResearch/clipper2` (git-ignored) |

The Boost Software License 1.0 is permissive and does **not** require source
disclosure or attribution in the shipped binary, but it does require the licence
notice to accompany redistributed source. `LICENSE-Clipper2.txt` next to this
file is that notice, verbatim from the upstream clone, and the library is also
listed in the repository's [`THIRD-PARTY-NOTICES.md`](../../THIRD-PARTY-NOTICES.md#clipper2).

Vendoring the C++ sources as a SwiftPM target removes any need for CMake: the
package builds with plain `swift build` under Command Line Tools.

## Exactly what was copied

Nothing was modified. Files were copied byte-for-byte; SHA-256 prefixes are
given so drift is detectable.

### Headers → `Sources/CClipper2/clipper2/`

Copied from `CPP/Clipper2Lib/include/clipper2/`.

| File | SHA-256 (first 16) |
|---|---|
| `clipper.core.h` | `b667c2fe96834425` |
| `clipper.engine.h` | `e77185eb535cdae2` |
| `clipper.h` | `145efd001ef2f45a` |
| `clipper.minkowski.h` | `6ea4f08d3e2561bd` |
| `clipper.offset.h` | `147e5f4694327d62` |
| `clipper.rectclip.h` | `2970dbe3f91d32e9` |
| `clipper.triangulation.h` | `a82d32e65583cce5` |
| `clipper.version.h` | `0d636f1599b09743` |

### Sources → `Sources/CClipper2/src/`

Copied from `CPP/Clipper2Lib/src/`.

| File | SHA-256 (first 16) |
|---|---|
| `clipper.engine.cpp` | `7b2cc17d4debd3b5` |
| `clipper.offset.cpp` | `ebc01258953212d2` |
| `clipper.rectclip.cpp` | `79c7d8d90dd3b577` |
| `clipper.triangulation.cpp` | `94e7449b9f278b71` |

### Copied but not compiled

`clipper.offset.cpp`, `clipper.rectclip.cpp` and `clipper.triangulation.cpp` stay in
`src/` byte for byte, so the copy above is still the whole upstream source set and a refresh
stays a plain re-copy. `Package.swift` excludes them from the `CClipper2` target (W-092,
2026-10-03): the shim reaches only the boolean engine and the point-in-polygon test, and the
offset, XOR and offset-type Swift API they served had no caller outside the bridge's own tests,
so it was removed with `zpclipper2_inflate`. `clipper.h` still includes their headers; its
inline wrappers (`InflatePaths`, `RectClip`, …) are only emitted where called, so the target
links without the three units. Re-adding offsetting means dropping the matching `exclude` entry
and restoring an `extern "C"` entry point for it.

### Licence

`CPP/../LICENSE` → `LICENSE-Clipper2.txt` (`c9bff75738922193`).

## Deliberately **not** copied

- `CPP/Clipper2Lib/include/clipper2/clipper.export.h` — the DLL export surface;
  this bridge has its own `extern "C"` shim instead.
- `CPP/Tests`, `CPP/BenchMark`, `CPP/Examples`, `CPP/Utils`, all CMake files.
- `CSharp/`, `Delphi/`, `DLL/`, `Tests/` (the repo-level test data).

## Files written by Zenit PDF (not upstream)

| File | Role |
|---|---|
| `Sources/CClipper2/include/zpdf_clipper2.h` | the only public header — pure C, no C++ |
| `Sources/CClipper2/src/zpdf_clipper2_shim.cpp` | `extern "C"` implementation over Clipper2 |
| `Sources/ZPDFClipper2/*.swift` | the Swift API |
| `Package.swift`, `Tests/` | packaging and tests |

## Why a C shim rather than Swift/C++ interop

Direct Swift/C++ interop (`.interoperabilityMode(.Cxx)`) would drag
`std::vector<Clipper2Lib::Point64>` and the `Paths64`/`PathsD` template
instantiations across the module boundary, force every downstream Swift target
in Zenit PDF to enable C++ interop as well, and make `Sendable` conformance
awkward. A hand-written `extern "C"` layer costs one flat-array copy in each
direction and gives a boundary that is trivially `Sendable`, exception-free, and
buildable with Command Line Tools only. That is the option taken here — it
compiled clean on the first attempt.

## Coordinate scaling and precision

Clipper2 is robust because it is an **exact integer** clipper: it never sees a
floating-point coordinate. The shim therefore quantises:

```
inbound:  int64 = llround(value * scale)
outbound: value = int64 / scale
```

The default `ClipperScale.pagePoints` is `1e6`, i.e. a 1e-6 PDF-point lattice.

Consequences, all real and all documented in `ClipperScale`:

- A vertex may move by up to `0.5e-6` pt per round trip.
- Vertices closer together than `1e-6` pt collapse onto one another.
- Measured areas shift accordingly. The test
  `testDifferenceCarvesAHoleOutOfTheMiddle` sees a 256-gon's area move by about
  `2e-6` pt² out of `50.26` pt² — a relative error near `4e-8`.
- Usable coordinate range is `±(INT64_MAX >> 2) / scale ≈ ±2.3e12` pt. The shim
  rejects anything beyond that with `ClipperError.coordinateOverflow` rather
  than letting Clipper2 throw.

At 1:100 drawing scale, 1e-6 pt is about 3.5 µm on site — several orders of
magnitude below anything a construction takeoff resolves. Another lattice is
`ClipperScale(value)`: a coarser one buys range, a finer one resolution.

## Behavioural deviation from upstream defaults

`PreserveCollinear` defaults to `true` in Clipper2. The Swift API defaults
`preservingCollinearVertices` to `false`, so results are minimal-vertex:
unioning a 40×40 grid of abutting unit squares gives a 4-vertex rectangle
instead of a 160-vertex one. Pass `true` for upstream behaviour.

## Refreshing the vendored copy

1. `git -C ExternalResearch/clipper2 pull`
2. Re-copy the twelve files listed above (paths are unchanged upstream).
3. Update the revision, version and hashes in this file.
4. `swift build && swift test` in `Bridges/Clipper2Bridge`.
5. If `clipper.h` gained a new `#include`, add that header to the copy list.
