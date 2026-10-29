# Vendored third-party source — libxlsxwriter

| | |
|---|---|
| Upstream | https://github.com/jmcnamara/libxlsxwriter |
| Upstream revision | `3227eb0c1556ba41d94605a7abee0e097782d10a` (2026-07-07) |
| Licence | BSD-2-Clause (FreeBSD) — see `LICENSE-libxlsxwriter.txt` |
| Vendored on | 2026-08-23 |
| Vendored by | Zenit PDF maintainers |
| Local clone used | an upstream clone at `ExternalResearch/libxlsxwriter` (git-ignored) |

`LICENSE-libxlsxwriter.txt` is the upstream `License.txt` verbatim
(`be1d70d4ec6e0388`). It is the combined licence page and carries the
bundled-component notices as well as libxlsxwriter's own BSD-2-Clause text. The library is also
listed in the repository's [`THIRD-PARTY-NOTICES.md`](../../THIRD-PARTY-NOTICES.md#libxlsxwriter).

The upstream `rich_value*` file headers (`src/rich_value*.c` and
`include/xlsxwriter/rich_value*.h`) end with "See LICENSE.txt". No file of that name ships in
this bridge: the licence they refer to is upstream's `License.txt`, which is
`LICENSE-libxlsxwriter.txt` here. The headers are left as upstream wrote them.

Vendoring the C sources as a SwiftPM target removes any need for CMake or `make`: the package
builds with plain `swift build` under Command Line Tools, and — more importantly — the build
flags below are frozen in `Package.swift` rather than in a build system nobody re-runs.

## Build flags, and what each one excludes

This bridge decides three libxlsxwriter flags, each of which keeps a bundled component out of the
binary, and keeps upstream's default for a fourth. The decision record is conflict 3 in
`Docs/Licences/LICENSE_EVIDENCE.md`.

| Flag | Setting | Consequence |
|---|---|---|
| `USE_STANDARD_TMPFILE` | **defined** | `third_party/tmpfileplus` (MPL-2.0) is not copied, not compiled and not linked. libxlsxwriter calls the C standard `tmpfile()`. |
| `USE_NO_MD5` | **defined** | `third_party/md5` (Openwall) is not copied. The MD5 is used only to de-duplicate *images* embedded in a worksheet; this bridge writes no images. |
| `USE_DTOA_LIBRARY` | **not defined** | `third_party/dtoa` (`emyg_dtoa`) is not copied. `lxw_sprintf_dbl` is then a macro over a plain `snprintf` with `%.16G`, which is *not* locale-guarded; the Swift wrapper pins the thread's numeric locale to "C" for the whole workbook write (`withCNumericLocale`). |
| `USE_SYSTEM_MINIZIP` | **not defined** | minizip (zlib licence) is vendored and statically linked; only zlib itself comes from the system (`-lz`). macOS ships no system minizip. |

### Why `USE_STANDARD_TMPFILE`

`tmpfileplus` is Mozilla Public License 2.0 — the only copyleft licence anywhere in this
dependency set. MPL-2.0 §3.3 permits shipping it inside an MIT-licensed larger work, but §3.2
then obliges Zenit PDF to make the source of those two files available to every recipient of the
binary, under MPL-2.0, and to say how to get it — forever, on every release. Excluding the
component removes the obligation instead of managing it. The reasoning, licence evidence and
digests are conflict 3 in `Docs/Licences/LICENSE_EVIDENCE.md`.

**Verification (must be re-run after any refresh).** Build the bridge (`swift build` in
`Bridges/LibXlsxWriterBridge`) and scan every object file. The only `tmpfile` symbols present are libxlsxwriter's own
`_lxw_tmpfile` and the undefined libc `_tmpfile`:

```
$ nm -a $(find .build -name '*.o') | grep -i tmpfile | sort -u
                 U _lxw_tmpfile
                 U _tmpfile
0000000000001584 T _lxw_tmpfile
```

No `tmpfileplus` symbol exists, and no MPL-2.0 file exists anywhere under this directory.

**The trade-off, stated plainly.** `tmpfileplus` exists because the C standard `tmpfile()` is
unreliable on some platforms (on Windows it can try to create the file in the root of the system
drive). Zenit PDF is macOS-only, where `tmpfile()` resolves through the process temporary
directory, which the App Sandbox redirects into the container.
`ZPDFXlsxWriterTests` covers a 20 000-row constant-memory export — the path that actually spills
to temporary files — and `XlsxWriter.temporaryFileSupportIsAvailable()` is asserted by its own
test. `XlsxError` has a dedicated `temporaryFileUnavailable` case whose message names this
decision, so a sandbox regression surfaces as a loud, specific error rather than as a mystery.
**If that error is ever seen in the field, the correct response is to reinstate `tmpfileplus` and
satisfy MPL-2.0 §3.2 — not to paper over it here.** Nothing in this package retries, falls back
to a hand-rolled temporary file, or swallows the condition.

## Exactly what was copied

Copied byte-for-byte except for the changes recorded under
[What Zenit PDF changed](#what-zenit-pdf-changed). SHA-256 prefixes are of the
**upstream** files, so drift against the clone is detectable; for the six files Zenit PDF
changed, the local file's prefix is given as well.

### Library sources → `Sources/CXlsxWriter/src/`

From `src/` (26 files; `src/Makefile` was not copied).

| File | SHA-256 (first 16) |
|---|---|
| `src/app.c` | `11c8003305c724f7` |
| `src/chart.c` | `5fdb4083e3b3580f` |
| `src/chartsheet.c` | `ce2acf02aa202eb4` |
| `src/comment.c` | `3ac63e7e7e194d21` |
| `src/content_types.c` | `6b8212d5eed1729a` |
| `src/core.c` | `cd423087de9ec858` |
| `src/custom.c` | `864ff9f23ea25d41` |
| `src/drawing.c` | `8dba99f9ac54efca` |
| `src/format.c` | `7b93518ad03af144` |
| `src/hash_table.c` | `227018c09414a02b` |
| `src/metadata.c` | `4cee2f9330fe9a44` |
| `src/packager.c` | `f40abd62dbe3fbde` |
| `src/relationships.c` | `3f5b06fec09e39de` |
| `src/rich_value.c` | `7806c63a644667fd` |
| `src/rich_value_rel.c` | `808bfd27dac9b7b1` |
| `src/rich_value_structure.c` | `9c781281074b0d97` |
| `src/rich_value_types.c` | `8828eb2b2e145178` |
| `src/shared_strings.c` | `5d83f8166dabb3ad` |
| `src/styles.c` | `459f15405f7c600e` |
| `src/table.c` | `f21ff78e1424aed0` |
| `src/theme.c` | `0a9a0a5e3cabf34c` |
| `src/utility.c` | upstream `12a88550b20bcd6e`; local `fa203322b1f07dff` |
| `src/vml.c` | `9da6d8b8ff390969` |
| `src/workbook.c` | `9e90ae7318c3c836` |
| `src/worksheet.c` | `3b72e6cf93637736` |
| `src/xmlwriter.c` | `9d6e371dc87f8f0d` |

### Headers → `Sources/CXlsxWriter/include/`

`include/xlsxwriter.h` and `include/xlsxwriter/*.h`. This directory is the target's
`publicHeadersPath`, so it is also the generated module's umbrella.

| File | SHA-256 (first 16) |
|---|---|
| `include/xlsxwriter.h` | `888ce083835ec3da` |
| `include/xlsxwriter/app.h` | `d28c119bbe48a324` |
| `include/xlsxwriter/chart.h` | `1c6c2291d9c1988b` |
| `include/xlsxwriter/chartsheet.h` | `41763a53be10e45f` |
| `include/xlsxwriter/comment.h` | `ea3a8324988b71fa` |
| `include/xlsxwriter/common.h` | `7f798b42c7f3f463` |
| `include/xlsxwriter/content_types.h` | `9a80be9db4db8bf6` |
| `include/xlsxwriter/core.h` | `e83bbe9c8b5238cd` |
| `include/xlsxwriter/custom.h` | `cc3d361bfba227ef` |
| `include/xlsxwriter/drawing.h` | `1dded18e5568754e` |
| `include/xlsxwriter/format.h` | `6f792b3e99222a28` |
| `include/xlsxwriter/hash_table.h` | `21ada21e1203867d` |
| `include/xlsxwriter/metadata.h` | `92517adf70747bbd` |
| `include/xlsxwriter/packager.h` | `cfe3fee1c674e9ec` |
| `include/xlsxwriter/relationships.h` | `1d1d96071ed0fd5f` |
| `include/xlsxwriter/rich_value.h` | `b0a35fa49ec0ca5e` |
| `include/xlsxwriter/rich_value_rel.h` | `be38c955dd0388d1` |
| `include/xlsxwriter/rich_value_structure.h` | `f5e6a7d917134a78` |
| `include/xlsxwriter/rich_value_types.h` | `d64ae5d89a123bb4` |
| `include/xlsxwriter/shared_strings.h` | `b88a85ac66f727b8` |
| `include/xlsxwriter/styles.h` | `5f94183cc1ce694f` |
| `include/xlsxwriter/table.h` | `be15babf067c3807` |
| `include/xlsxwriter/theme.h` | `d31b90e004467aa5` |
| `include/xlsxwriter/utility.h` | `b2f00839ec7041af` |
| `include/xlsxwriter/vml.h` | `8c4b6ca7b04b9db7` |
| `include/xlsxwriter/workbook.h` | `01867be59b2b8dba` |
| `include/xlsxwriter/worksheet.h` | `c7c94c1bb4408dd6` |
| `include/xlsxwriter/xmlwriter.h` | `c497593c1f479181` |

### Bundled-component headers → `Sources/CXlsxWriter/include/xlsxwriter/third_party/`

| File | SHA-256 (first 16) |
|---|---|
| `include/xlsxwriter/third_party/ioapi.h` | upstream `d3a4312d90ce71a4`; local `728fadb0d387fcc6` |
| `include/xlsxwriter/third_party/queue.h` | `efa41a6aa35bfb45` |
| `include/xlsxwriter/third_party/tree.h` | `6dc495ea46ebd94f` |
| `include/xlsxwriter/third_party/zip.h` | upstream `62622026a0eba833`; local `3fadc8d62aac21be` |

`ioapi.h` and `zip.h` here are the same files as the minizip copies below and carry the same
altered-source marking. `queue.h` and `tree.h` carry different notices, as their own headers
state: `queue.h` is "Copyright (c) 1991, 1993 The Regents of the University of California",
under a BSD licence with three conditions (numbered 1, 2 and 4); `tree.h` is
"Copyright 2002 Niels Provos", under a two-condition (BSD-2-Clause style) licence. Both notices
are reproduced in `LICENSE-libxlsxwriter.txt`.

### minizip → `Sources/CXlsxWriter/minizip/`

From `third_party/minizip/`. Only the writer half: the archive reader (`unzip.c`), the CLI tools,
the Windows IO layer and `crypt.h` were not copied. `crypt.h` holds the traditional PKWARE
encryption, which its header describes as a modified version of Info-ZIP code. `zip.h` always
defines `NOCRYPT`, so `zip.c` never includes it; it was removed from the vendored set on
2026-10-29 so that no Info-ZIP-derived code is redistributed.

| File | SHA-256 (first 16) |
|---|---|
| `third_party/minizip/ioapi.c` | `6dff11ded396f5e3` |
| `third_party/minizip/ioapi.h` | upstream `d3a4312d90ce71a4`; local `728fadb0d387fcc6` |
| `third_party/minizip/zip.c` | upstream `d29e6618ff46608e`; local `7018d3f0a73b2279` |
| `third_party/minizip/zip.h` | upstream `62622026a0eba833`; local `3fadc8d62aac21be` |

#### Altered source versions (zlib licence, condition 2)

The zlib licence requires that "altered source versions must be plainly marked as such, and
must not be misrepresented as being the original software". These files are MiniZip as
distributed in zlib 1.3.1 `contrib/minizip`, altered by the libxlsxwriter project before Zenit
PDF copied them. Upstream's history at the pinned revision shows the alterations: a raw copy of
the zlib 1.3 files (`957ed5c`), then the zlib 1.3 to 1.3.1 changes (`786a68a`, plus the
zlib-originated overflow check `1dfd55b`), and libxlsxwriter's own changes in `7e8e9c0`,
`db5c0a6` and `4acea2f`:

| File | libxlsxwriter's alterations |
|---|---|
| `ioapi.h` (both copies) | adds `#pragma GCC system_header` (outside `_WIN32`); rewrites the C++ `//` comments as C comments |
| `zip.h` (both copies) | adds `#pragma GCC system_header` (outside `_WIN32`); defines `NOCRYPT` and `NOUNCRYPT` when not already defined, which disables encryption; rewrites the `//#define HAVE_BZIP2` comment as a C comment |
| `zip.c` | in `zipOpenNewFileInZip4_64`, changes `(crcForCrypting);` to `(void) (crcForCrypting);` |

`ioapi.c` is not altered: no libxlsxwriter commit touches it after the raw zlib copy, and it
carries no marking.

Zenit PDF's only change to these files is a C comment added as the first lines of each altered
file (the two minizip headers, `zip.c`, and the two `include/xlsxwriter/third_party/` copies)
that marks it as an altered source version, names the alterations above and points to this
file. It precedes everything else, including `#pragma GCC system_header`, which a comment does
not affect. Removing that comment from a local file gives back the upstream file byte for byte.

## What Zenit PDF changed

### The one code modification

`src/utility.c` line 22 upstream is an **unconditional**
`#include "xlsxwriter/third_party/tmpfileplus.h"`, even though the function that uses it is
guarded by `#ifndef USE_STANDARD_TMPFILE`. Upstream can afford that because its CMake build keeps
the header on disk regardless of the flag. This bridge does not ship the header at all, so the
include is wrapped in the same guard as its only call site:

```c
#ifndef USE_STANDARD_TMPFILE
#include "xlsxwriter/third_party/tmpfileplus.h"
#endif
```

The patch also adds a three-line C comment above the guard that says why it exists and points
to this file (`See ../../../VENDORED.md.`, the path from `Sources/CXlsxWriter/src/`). The
patched local `src/utility.c` hashes to `fa203322b1f07dff`; the upstream original hashes to
`12a88550b20bcd6e`.

### Everything Zenit PDF changed

Nothing else in any vendored file was changed. The complete list of Zenit PDF's changes is: the
`src/utility.c` guard and its explanatory comment above, and the altered-source marking comment
at the top of the five altered minizip files (`minizip/ioapi.h`, `minizip/zip.h`,
`minizip/zip.c`, `include/xlsxwriter/third_party/ioapi.h`,
`include/xlsxwriter/third_party/zip.h`) described in the minizip section. Every other vendored
file matches its upstream hash in the tables above.

## Deliberately **not** copied

- `third_party/tmpfileplus/` — **MPL-2.0**, excluded by `USE_STANDARD_TMPFILE`. This is the point
  of the whole flag decision above.
- `third_party/md5/` — excluded by `USE_NO_MD5`.
- `third_party/dtoa/` — not reachable without `USE_DTOA_LIBRARY`.
- minizip's `unzip.c`, `unzip.h`, `miniunz.c`, `minizip.c`, `mztools.*`, `iowin32.*` and the
  autotools/VMS files.
- `include/xlsxwriter/third_party/tmpfileplus.h`, `md5.h`, `emyg_dtoa.h` — the headers of the
  three excluded components.
- `test/`, `examples/`, `docs/`, `dev/`, `cocoapods/`, `lib/`, upstream `Package.swift`,
  `CMakeLists.txt`, `Makefile`, `build.zig`.

## Files written by Zenit PDF (not upstream)

| File | Role |
|---|---|
| `Package.swift` | the SwiftPM package, and the frozen build flags |
| `Sources/ZPDFXlsxWriter/XlsxWriter.swift` | scoped workbook/worksheet API |
| `Sources/ZPDFXlsxWriter/XlsxFormat.swift` | declarative, cached cell formats |
| `Sources/ZPDFXlsxWriter/XlsxError.swift` | `lxw_error` to typed Swift error |
| `Tests/ZPDFXlsxWriterTests/` | the tests, including the tmpfile and constant-memory ones |
| `VENDORED.md` | this file |

## Why a scoped `write(to:_:)` rather than a `Workbook` object

`workbook_close()` frees the workbook, every worksheet it created and every format it allocated,
in one call. A Swift `class Workbook` with `deinit` would put that free at the mercy of ARC
ordering, and a `Worksheet` that outlived its workbook would be a use-after-free reachable from
pure Swift. The scoped `XlsxWriter.write(to:options:properties:)` closes exactly once at a point
the compiler can see, and every method checks a closed flag, so the worst a caller can do by
stashing a handle is get `XlsxError.workbookAlreadyClosed`.

## Refreshing the vendored copy

1. `git -C ExternalResearch/libxlsxwriter pull`
2. Re-copy the file lists above (paths are unchanged upstream).
3. Re-apply the `src/utility.c` guard patch.
4. Re-check upstream's minizip history for alterations, update the alteration table, and
   re-add the altered-source marking comment to every altered minizip file (zlib licence,
   condition 2).
5. Update the revision and the digests in this file.
6. `swift build && swift test` in `Bridges/LibXlsxWriterBridge`.
7. Re-run the object-file symbol scan above and paste its output.
8. If a new `third_party` component appears, decide its licence before compiling it in.
