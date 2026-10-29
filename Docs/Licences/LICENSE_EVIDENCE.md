# License Evidence

Reproducible record of the licence actually present in each ExternalResearch clone, read from the licence file rather than from README claims.

Maintained by: the Zenit PDF maintainers
Status: verified-against-code (licence files and git metadata read directly on 2026-08-23; no running application was inspected)
Context: when this evidence was collected no application target existed and no component listed below was resolved into any build, so every "production-dependency" role in the evidence table is taken from the project's initial dependency inventory, not from a resolved manifest. What actually ships is recorded in "What actually ships" below, and where the two disagree, the binary wins. The vendored third-party trees inside pdfium (~19+ components) and opencv are not enumerated here; neither library is in the build.

Machine-readable companion: [`Docs/Execution/RESEARCH_REPOSITORIES.lock.json`](../Execution/RESEARCH_REPOSITORIES.lock.json)

## Method

For every directory in `ExternalResearch`:

1. `git -C <dir> rev-parse HEAD`, `git -C <dir> remote get-url origin`, `git -C <dir> log -1 --format=%cI HEAD`
2. `ls <dir> | grep -iE 'licen[cs]e|copying|notice'`, then `find <dir> -maxdepth 3 -iregex '.*\(licen[cs]e\|copying\|notice\).*' -not -path '*/.git/*'` where the root listing was empty
3. Read the head of each licence file and identify the licence from its own text
4. `shasum -a 256 <licence file>` so any reviewer can reproduce the evidence

Generated at 2026-08-23T10:11:16Z (`date -u +%Y-%m-%dT%H:%M:%SZ`). Commit dates are the upstream committer dates in each clone, not clone dates.

## Evidence table

| Repo | Revision | License found | Evidence quote | Role | Commercial use | Attribution obligation |
|---|---|---|---|---|---|---|
| GRDB.swift | `0d8cf958` (`v7.11.1-2-g0d8cf958`, development snapshot past the tag) | MIT, with embedded Rails Active Support MIT and Swift.org Apache-2.0 (Runtime Library Exception) notices | "Permission is hereby granted, free of charge, to any person obtaining a copy" | production-dependency | Yes | Copyright + permission notice in About panel, plus the four embedded notices and the Apache-2.0 text (item 1 below) |
| qpdf | `dfd25112` (`v12.4.0-26-gdfd25112`; `DLL.h` declares 12.4.1, an untagged development snapshot) | Apache-2.0 | "Licensed under the Apache License, Version 2.0" (NOTICE.md) | production-dependency | Yes | Licence text **and** NOTICE.md verbatim (Apache 4(d)) |
| pdfium | `e2fba6a9` | BSD-3-Clause | "Neither the name of Google Inc. nor the names of its contributors" | reference-only (not in the build; was production-dependency in the initial inventory) | Yes | None while not in the build |
| pdfium-xcframework | `e3b3cbd2` | MIT (table says BSD-style) | "The MIT License (MIT)" / "Copyright (c) 2025 @espresso3389 (Takashi Kawasaki)" | reference-only (nothing consumes what it builds; was build-dependency) | **Unverified** | See conflicts |
| Clipper2 | `f9c5eb6e` (`Clipper2_2.0.1-16-gf9c5eb6`, development snapshot past the tag) | BSL-1.0; Copyright Angus Johnson 2010-2026 per the source headers (LICENSE names no holder) | "Boost Software License - Version 1.0 - August 17th, 2003" | production-dependency | Yes | Notice required in source form; waived for object code |
| Sparkle | `14d644c7` | MIT (+ bundled) | "Permission is hereby granted, free of charge, to any person obtaining a copy" | **removed 2026-10-27** (was production-dependency) | Yes | None: no longer in the build — see "What actually ships" |
| libxlsxwriter | `3227eb0c` (`v1.2.4-8-g3227eb0`) | BSD-2-Clause (shipped: BSD-2-Clause AND BSD-3-Clause AND Zlib; no MPL-2.0) | "Libxlsxwriter is released under a FreeBSD license" | production-dependency | Yes | Copyright, conditions, disclaimer + bundled component notices |
| tmpfileplus (bundled inside libxlsxwriter) | `3227eb0c` (libxlsxwriter) | **MPL-2.0** | "This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0" | **not vendored, not compiled, not linked** — excluded by `USE_STANDARD_TMPFILE`; see conflict 3 | n/a | None, because the component is absent from the source tree and from the built objects |
| opencv | `c36dd6a3` | Apache-2.0 | "Apache License Version 2.0, January 2004" | reference-only (not in the build; was production-dependency, optional module) | Yes | None while not in the build |
| XcodeGen | `8445e778` | MIT | "MIT License" / "Copyright (c) 2018 Yonas Kolb" | unused (no build script, manifest or project file uses it) | Yes | None: nothing from it is used or distributed |
| swift-snapshot-testing | `59a99c45` | MIT | "MIT License" / "Copyright (c) 2019 Point-Free, Inc." | unused (no manifest names it; no test imports SnapshotTesting) | Yes | None: nothing from it is used or distributed |
| skim-pdf | `6cdd41f6` | BSD-3-Clause | "Neither the name of Michael O. McCracken nor the names of any other contributors" | reference-only | Yes | None while no code is copied |
| PageFlow | `aa81842d` | Apache-2.0 | "Apache License Version 2.0, January 2004" | reference-only | Yes | None while no code is copied |
| Galley | `d5b812ef` | BSD-3-Clause | "This program is licensed under the terms of BSD 3-Clause." | reference-only | Yes | None while no code is copied |
| Qedit | `ecc97fc9` | MIT | "MIT License" / "Copyright (c) 2026 Ariorad Moniri" | reference-only | Yes | None while no code is copied |
| SnapShotKit | `d13699b1` | MIT | "MIT License" / "Copyright (c) 2026 Bheema Rajulu" | reference-only | Yes | None while no code is copied |
| Contributor Covenant | version 2.1 (not cloned) | CC-BY-4.0 (licensor's declared licence) | Not read locally | repository-only: adapted in CODE_OF_CONDUCT.md; not shipped in the app | Yes | Credit, link, licence name and URI, modification statement and the Mozilla credit, in the CODE_OF_CONDUCT.md Attribution section |
| acroromi | `2a4e46b4` | **None present** (README claims MIT) | "This project is licensed under the **MIT License**" (README.md:301, file absent) | reference-only | **Unverified** | See conflicts |
| Drawbridge | `9694d905` | **None present** | No licence file at any depth; no licence statement in any Markdown file | blocked | No | Zero code copied; visual product reference only |
| pdfClaw | not cloned | GPL-3.0-only (declared) | Not read — repository not cloned | blocked | No | Do not clone or reuse |
| MuPDF | not cloned | AGPL-3.0-only (declared) | Not read — repository not cloned | blocked | No | Do not clone or reuse |
| PyMuPDF | not cloned | AGPL-3.0-only (declared) | Not read — repository not cloned | blocked | No | Do not clone or reuse |

SHA-256 digests for every licence file are in the lock JSON. Note that `qpdf/LICENSE.txt` and `opencv/LICENSE` are byte-identical (`cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`): both are the unmodified Apache-2.0 text.

## What actually ships, and where the text lives — added 2026-08-26

The evidence table above records what licence was present in each **clone** on 2026-08-23,
when no application target existed. It is not a statement about the binary, and it was read as
one: `THIRD-PARTY-NOTICES.md` named **PDFium** as shipped and **OpenCV** as conditional, and
neither is in the build. Both are corrected in that file against measurement — zero `FPDF_`,
`pdfium`, `cv::` or `opencv` symbols across all eight Mach-O binaries in the assembled bundle,
no SwiftPM manifest naming either, and no `Bridges/` target vendoring either. The roles in the
table above are therefore the **initial dependency inventory as of 2026-08-23**, not the resolved
graph; where the two disagree, the binary wins.

Until 2026-08-26 the assembled bundle carried **no licence text at all**: `Contents/Resources`
held `AppIcon.icns`, `ProjectDocument.icns`, `GRDB_GRDB.bundle` and `en.lproj`, and About was
`orderFrontStandardAboutPanel(_:)`. qpdf's Apache-2.0 §4(d) makes its NOTICE non-optional for a
redistributor, so that was a compliance failure rather than a missing nicety. It is closed:

* the notice texts live at `Apps/ZenitPDF/Bundle/Licenses/*.txt`, committed (the upstream clones
  are `.gitignore`d, so a build on a machine without them could not otherwise produce them),
  regenerated by `Scripts/regenerate-bundle-licences.sh`, each carrying its component name,
  pinned revision, upstream file and that file's SHA-256;
* `Scripts/build-app.sh` copies the directory to `Contents/Resources/Licenses/`;
* `ZenitAboutWindowController` — Zenit PDF ▸ About — shows the full text of each, offline,
  selectable, with no hyperlink standing in for a licence;
* `Scripts/verify-licence-notices.sh` runs inside `build-app.sh` and fails the build when a
  component listed below has no text in `Contents/Resources`, when a text does not match its
  recorded digest, when a text is present that no row accounts for, or when the About surface
  stops reading the directory.

### Machine-readable shipped set

This fenced block is the authority the gate reads for *which* components must have text. Its
rows must match `Docs/Licences/SHIPPED_NOTICES.tsv` exactly; the gate fails if they diverge, so
adding a dependency here without regenerating the notices cannot pass, and neither can the
reverse. One row per component whose code is inside the binary and whose licence requires a
notice there.

```zenit-shipped-components
Zenit PDF
GRDB.swift
qpdf
Clipper2
libxlsxwriter
```

Not in this list, and each for a stated reason: **Sparkle** was removed on 2026-10-27 together
with the whole auto-update feature — the application has no updater, embeds no framework and
makes no network connection, so neither its code nor its notice ships; **PDFium** and **OpenCV**
are not in the build at all (measured above); **pdfium-xcframework** builds a framework nothing consumes;
**tmpfileplus** is excluded by `USE_STANDARD_TMPFILE` and proven absent by
`Scripts/verify-export.sh`; **XcodeGen** and **swift-snapshot-testing** are not used by any
build or test (corrected 2026-10-29; they were recorded as build- and test-only); every
reference-only clone has had no code copied from it.

---

## Attribution and NOTICE obligations reaching the shipped product

Two destinations must be kept in sync: the in-app About panel (acknowledgements surface) and `Docs/Licences/`. The About panel is the redistribution-facing copy and is the one with legal weight.

**Must appear in the About panel** (linked into the shipped binary, per the initial dependency inventory; the shipped set above is the authority for what is actually linked):

1. **GRDB.swift** — MIT copyright line and full permission notice. GRDB also compiles four files that carry notices of their own, which GRDB's LICENSE does not reproduce; each was verified in the clone at `0d8cf958` and in the SwiftPM checkout the app builds (identical files, all four compiled into the `GRDB` product), and `Scripts/regenerate-bundle-licences.sh` reproduces each comment verbatim in the GRDB notice:
   - `GRDB/Utils/Inflections+English.swift` (sha256 `80b42f1c…`) — the Ruby on Rails Active Support English inflection rules, MIT, "Copyright (c) 2005-2019 David Heinemeier Hansson".
   - `GRDB/Core/Cursor.swift` (sha256 `87679f62…`) — "Parts of this file are derived from the Swift.org open source project", Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors, Apache License v2.0 with Runtime Library Exception.
   - `GRDB/Record/EncodableRecord.swift` (sha256 `b2329647…`) and `GRDB/Record/FetchableRecord.swift` (sha256 `faa0d2bb…`) — `_convertToSnakeCase` and `_convertFromSnakeCase`, copied from swift-corelibs-foundation (`JSONEncoder.swift` / `JSONDecoder.swift` at `8d6398d76eaf`), Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors, same licence; the notice is an indented comment inside each function.

   Because Apache-2.0 §4(a) asks for a copy of the licence, the GRDB notice is self-contained: it ends with the full Apache License 2.0 text (copied from the qpdf clone's `LICENSE.txt`, the unmodified Apache-2.0 text, sha256 `cfc7749b…`) and states that the Swift project's licence adds the Runtime Library Exception published at https://swift.org/LICENSE.txt.
2. **qpdf** — full Apache-2.0 text plus `NOTICE.md` reproduced verbatim. Apache-2.0 section 4(d) makes the NOTICE non-optional. Its content is substantive: qpdf offers a pre-v7 Artistic-2.0 alternative, bundles `qtest` under Artistic-2.0, credits the Rijndael implementation underlying its AES support, and reproduces the full MIT licence of the embedded sphlib 3.0 SHA-2 code ("Copyright (c) 2007-2011  Projet RNRT SAPHIR"). The compiled sphlib files (`libqpdf/sha2.c`, `sha2big.c`, `sphinclude/sph/sph_sha2.h`, `sph_types.h`, `md_helper.c`) state 2007-2010 in their own headers; the qpdf notice's Zenit PDF section records both. That section also states that Zenit PDF vendors a subset of qpdf, that `libqpdf/QPDF_Stream.cc` is modified (DCT support compiled out via `ZPDF_QPDF_NO_DCT`) and that `libqpdf/qpdf/qpdf-config.h` is written for Zenit PDF. Dropping it is the single most likely compliance failure in this dependency set. The native crypto provider also compiles `libqpdf/MD5_native.cc` (sha256 `0534460b…`), which is derived from the RSA Data Security, Inc. MD5 Message-Digest Algorithm and carries the RSA MD5 licence; `NOTICE.md` does not mention it, so `Scripts/regenerate-bundle-licences.sh` reproduces that file's licence header verbatim in the qpdf notice.
3. **pdfium** — not in the build (reference-only since 2026-10-29); nothing is owed today. Should it ever be added: BSD-3-Clause copyright, the two redistribution conditions, the disclaimer, and the Google no-endorsement clause. pdfium additionally vendors a large `third_party/` tree (freetype, harfbuzz, lcms, libopenjpeg, libtiff, agg23, highway, dragonbox, fast_float, fp16, cpu_features, bigint, llvm-libc, Noto font subsets and others). Whichever of these end up inside a shipped xcframework carry their own notices. pdfium is not in the build today; should it ever be added, this enumeration must be completed once its build configuration is frozen — it cannot be settled from the source tree alone because the GN build selects components conditionally.
4. **Clipper2** — Boost 1.0. The upstream LICENSE names no holder; the source headers state Angus Johnson (2010-2023 to 2010-2026), and the Clipper2 notice's Zenit PDF section names him. The notice may be omitted only if Clipper2 reaches the product purely as machine-executable object code; if any Clipper2 source is vendored into `Packages/`, the notice is mandatory. Include it unconditionally rather than tracking the distinction.
5. **Sparkle** — no longer shipped (removed 2026-10-27 with the auto-update feature), so no notice is owed. Should it ever return, its MIT notice **and** its EXTERNAL LICENSES section (bsdiff/bspatch, sais-lite, a portable Ed25519) sit in one `LICENSE` file and must be copied whole.
6. **libxlsxwriter** — the FreeBSD/BSD-2-Clause notice plus the bundled-component notices in the same file: `queue.h` (FreeBSD; Copyright (c) 1991, 1993 The Regents of the University of California; BSD with clauses 1, 2 and 4, i.e. BSD-3-Clause), `tree.h` (FreeBSD; Copyright 2002 Niels Provos; BSD-2-Clause), minizip (zlib licence; Gilles Vollant; Mathias Svensson; altered source versions, see `Bridges/LibXlsxWriterBridge/VENDORED.md`), md5 (Alexander Peslyak; a public-domain dedication with a permissive fallback grant; not vendored), and emyg_dtoa (Doug Currie; Milo Yip; not vendored). The build flags are decided (conflict 3 below): minizip, `queue.h` and `tree.h` are compiled in; md5 and emyg_dtoa are neither vendored nor compiled. What ships is therefore BSD-2-Clause AND BSD-3-Clause AND Zlib, with no MPL-2.0. The notice is still reproduced whole, because it is upstream's licence file, and its Zenit PDF section says what this build contains.

   **tmpfileplus is the exception and is not BSD.** It carries an MPL-2.0 header in
   `third_party/tmpfileplus/tmpfileplus.c` and `.h`, with no standalone licence file — see conflict 3 below.
   MPL-2.0 is file-level weak copyleft: section 3.3 expressly permits distributing the MPL files inside a
   larger work under other terms, so our MIT licence is unaffected, but section 3.2 obliges us to make the
   source of *those files* available to recipients and to say how to obtain it. Two ways to satisfy this:
   ship the MPL notice and a source pointer, or build with `USE_STANDARD_TMPFILE` so the component never
   enters the binary and the obligation never arises. The second is preferred but requires testing that the
   C standard `tmpfile()` behaves under the App Sandbox first. The second was chosen, and the decision is
   recorded in conflict 3 below.
7. **opencv** — not in the build (reference-only since 2026-10-29; the optional alignment path uses Apple Vision in `Packages/ZPDFCompare`). No notice ships for absent code.

**Unused, no notice owed**: XcodeGen and swift-snapshot-testing. No build script, manifest, project file or test uses either (checked 2026-10-29), so nothing from them is distributed.

**No obligation at present**: skim-pdf, PageFlow, Galley, Qedit, SnapShotKit. These are reference-only and no code has been copied. The moment any line is copied, the obligation attaches immediately and this file must be updated in the same change.

**Design and algorithm sources outside ExternalResearch** (not cloned; no notice owed; acknowledged in `THIRD-PARTY-NOTICES.md`):

- **hilbert_curves** (github.com/rawrunprotected/hilbert_curves). Its README states "The code in this repository is released into the public domain." `hilbertXYToIndex` is ported, fixed at 16 bits per axis with the bit interleave written inline, into `Packages/ZPDFGeometry/Sources/ZPDFGeometry/Index/HilbertCurve.swift` (`HilbertCurve.distance(x:y:)`) and ships in the app binary. Public-domain code carries no notice obligation.
- **flatbush** (github.com/mourner/flatbush, ISC) is the design reference for `Packages/ZPDFGeometry/Sources/ZPDFGeometry/Index/PackedRTree.swift`: Hilbert-packed flat-array R-tree, level-by-level packing, default node size 16. PackedRTree.swift is an independent Swift implementation and copies no flatbush code, so the ISC notice condition does not attach. If flatbush code is ever copied, its ISC notice must be added to the shipped notices in the same change.

**Repository-only adaptation**: `CODE_OF_CONDUCT.md` is adapted, with modifications, from the Contributor Covenant 2.1 (CC BY 4.0). The attribution required by CC BY 4.0 §3(a)(1) is in that file; nothing from it ships in the app.

**Operational requirements**

- The About panel must render the full licence texts, not names or SPDX identifiers. "MIT" alone does not satisfy MIT.
- Notices must ship offline. A local-first macOS application cannot discharge attribution through a hyperlink to a remote page.
- The panel content should be generated from the lock JSON rather than hand-maintained, so a dependency change cannot silently drop a notice.
- Every entry must carry the pinned revision recorded here, so the notice provably matches the code that shipped.
- Zenit's own product naming stays clear of the benchmark product's distinctive feature names. That is a trademark matter, separate from the copyright obligations above, and is not covered by this file.

## Conflicts requiring human review

Three entries disagree with the initial dependency inventory or with their own repository's claims. None has been silently adjusted; all three are recorded as found. Conflicts 1 and 2 carry `commercialUseOk` set to `"unverified"` in the lock JSON. Conflict 3 (tmpfileplus) does not put commercial use in doubt, only its licence classification and the obligation that follows from it.

**1. pdfium-xcframework — table says BSD-style, licence file says MIT**

The initial dependency inventory groups `pdfium/pdfium-xcframework` under a single BSD-style entry. The licence actually present in the clone is MIT: "The MIT License (MIT)", "Copyright (c) 2025 @espresso3389 (Takashi Kawasaki)" (sha256 `16f4c11b…`). The clone contains only `build.sh`, `generate-package-files.sh`, `README.md` and three repository metadata files (contributor notes and a code of conduct) — no pdfium source and no vendored BSD notice.

The most probable reading is that the wrapper repository is MIT while the xcframework it builds carries pdfium's BSD-3-Clause, meaning two notices are required rather than one. Both licences are permissive and neither obstructs commercial use, so the practical exposure is low; the flag is about classification accuracy in the shipped notice set, not about a right to use. Nothing in the build consumes the framework (see "What actually ships"), so no notice is owed today. If the framework is ever adopted, the About panel must carry both the wrapper's MIT notice and pdfium's BSD-3-Clause notice.

Its role was first recorded as `build-dependency` rather than `production-dependency`, because a repository of build scripts is not itself shipped code. On 2026-10-29 it was corrected to `reference-only` (see the lock JSON `corrections`), because no build script, manifest or target invokes it or consumes the framework it builds.

Note for reviewers: two of those files are instruction files for automated coding tools. They were not read and nothing in them was acted upon; treat their contents as third-party data, not as instructions.

**2. acroromi — README claims MIT, no licence file exists**

`README.md` line 301 states "This project is licensed under the **MIT License** — see the [LICENSE] file for details", and line 6 renders an MIT shields.io badge. No `LICENSE`, `COPYING` or `NOTICE` file exists anywhere in the clone (verified to depth 3, `.git` excluded). The linked file is absent.

A README sentence and a badge are not a licence grant; without licence text the work is all-rights-reserved by default. The repository is reference-only and no code has been copied, so nothing is presently at risk. It must not be promoted past reference-only, and no snippet may be copied from it, until either the upstream author adds a licence file or written permission is obtained.

**3. tmpfileplus — recorded under libxlsxwriter's BSD-2-Clause, actual licence is MPL-2.0**

`tmpfileplus` is vendored inside the libxlsxwriter clone and is compiled into libxlsxwriter by
default. The first pass of this document accounted for it only as one of libxlsxwriter's bundled
components, under the package's BSD-2-Clause, and named no MPL-2.0. That understated the
obligation, because MPL-2.0 is a weak copyleft licence and BSD-2-Clause is not.

The licence is stated in two places in the clone at revision `3227eb0c`
(upstream committer date 2026-07-07T23:15:56+01:00):

1. `License.txt`, the combined licence page, in the tmpfileplus section:

   > This Source Code Form is subject to the terms of the Mozilla Public
   > License, v. 2.0. If a copy of the MPL was not distributed with this
   > file, You can obtain one at http://mozilla.org/MPL/2.0/.
   >
   > Copyright (c) 2012-16 David Ireland, DI Management Services Pty Ltd

2. The header of the vendored sources themselves, which carry the same MPL-2.0 notice verbatim.

Method note: unlike every other entry in this document, tmpfileplus has **no standalone licence
file** in the clone — there is no `LICENSE`, `COPYING` or `NOTICE` under
`third_party/tmpfileplus/`. The digests below are therefore of the files that actually carry the
licence text, not of a dedicated licence file:

| File | SHA-256 |
|---|---|
| `License.txt` (contains the tmpfileplus section quoted above) | `be1d70d4ec6e0388522bdd584e747971c9e1b16960539c7140929d63dd2130bc` |
| `third_party/tmpfileplus/tmpfileplus.c` (MPL-2.0 header) | `bad61b21f48ef26fa82ad95cd01431334774ed528342d9a559de014f14ad7eb7` |
| `third_party/tmpfileplus/tmpfileplus.h` (MPL-2.0 header) | `eb4bc0ebc4332b6be6f5a0d42451c685047b5de9f3aba68dc3d63f8a5d19af8d` |
| `include/xlsxwriter/third_party/tmpfileplus.h` (identical copy of the header) | `eb4bc0ebc4332b6be6f5a0d42451c685047b5de9f3aba68dc3d63f8a5d19af8d` |

Reproduce with `shasum -a 256 <file>` from the libxlsxwriter clone root.

What the difference means in practice. MPL-2.0 is file-level copyleft. The MPL-covered files stay
under MPL-2.0 even inside a differently-licensed product; §3.3 expressly permits distributing them
as part of a Larger Work under terms of the distributor's choice, and §3.2(a) requires that the
source of those files be made available to recipients of the executable, with recipients told how
to obtain it. That is a genuine ongoing obligation, not an attribution line, and it does not exist
for any other component in this dependency set.

It is also avoidable. libxlsxwriter builds against the C standard library `tmpfile()` instead when
built with `USE_STANDARD_TMPFILE=1` (make) or `-DUSE_STANDARD_TMPFILE=ON` (CMake), verified in
`Makefile` lines 43-44, `CMakeLists.txt` lines 78-89 and 367-369, and
`docs/src/getting_started.dox` line 551 of the pinned clone. With that flag the tmpfileplus
sources are not compiled and the MPL-2.0 obligation does not arise at all.

**Decided 2026-08-23: build with `USE_STANDARD_TMPFILE` and drop the component.**

`Bridges/LibXlsxWriterBridge` vendors libxlsxwriter for the XLSX export path, and it does not copy
`third_party/tmpfileplus/` at all — neither the sources nor the header. The flag is set in the
package's `Package.swift` (`cSettings: [.define("USE_STANDARD_TMPFILE"), ...]`), which is the build
system, so it cannot drift the way a `make` invocation in a README can. One upstream line had to be
patched to make the exclusion possible: `src/utility.c` includes the tmpfileplus header
unconditionally even though its only call site is guarded, so the include was wrapped in the same
`#ifndef USE_STANDARD_TMPFILE`. That patch is recorded in
`Bridges/LibXlsxWriterBridge/VENDORED.md`.

Evidence, re-runnable as `Scripts/verify-export.sh`:

- no file under `Bridges/LibXlsxWriterBridge/Sources` is named `*tmpfileplus*`;
- no file under that tree contains the string `Mozilla Public License`;
- `nm -a` over every object file of the `CXlsxWriter` target reports only `_lxw_tmpfile`
  (libxlsxwriter's own wrapper) and the undefined libc `_tmpfile`. There is no `tmpfileplus`
  symbol.

The MPL-2.0 §3.2(a) obligation therefore does not arise for any Zenit PDF binary built from this
tree. The dependency on the platform `tmpfile()` that this creates is exercised deliberately by
`ZPDFXlsxWriterTests` — a 20 000-row constant-memory export, which is the path that spills to
temporary files — and `XlsxError.temporaryFileUnavailable` names the decision in its message so a
sandbox regression is loud rather than silent.

Two related flags were decided in the same change, on the same "vendor only what is used"
principle: `USE_NO_MD5` is defined (the Openwall MD5 is only used to de-duplicate embedded
worksheet images, which this bridge never writes) and `USE_DTOA_LIBRARY` is not defined, so
`emyg_dtoa` is not vendored either. minizip remains, statically linked, under the zlib licence,
together with the FreeBSD `queue.h` and `tree.h` macro headers. The full file list and digests are
in `Bridges/LibXlsxWriterBridge/VENDORED.md`.

**Confirmed, not a conflict:** Drawbridge has no licence file at any depth and no licence statement in `README.md`, `DEVELOPMENT.md` or `USER_MANUAL.md`. This independently confirms the BLOCKED classification of the initial inventory. It remains a visual product reference only, with zero code copied.

## Status of this document

This file is **evidence** collected for the project's source and licence audit. It is not itself a legal approval.

It records what licence text was present in each clone at the pinned revisions on 2026-08-23, and nothing more. It does not constitute legal advice, does not clear any dependency for shipment, and does not authorise use of any component in a commercial product. The `commercialUseOk` field in the lock JSON reflects the plain reading of the licence text, not counsel's opinion.

Approval for ZENIT GROUP S.A.S. to ship these components must come from the company's own review, and from qualified legal review where the company judges it warranted — in particular for conflicts 1 and 2 above, for the unenumerated pdfium and opencv third-party trees, and for any decision to promote a reference-only repository to a production dependency.
