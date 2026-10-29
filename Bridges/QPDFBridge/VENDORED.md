# Vendored third-party source — qpdf

| | |
|---|---|
| Upstream | https://github.com/qpdf/qpdf.git |
| Upstream revision | `dfd251125cadb59fe04836f9197c3ef94f99cf55` |
| Upstream commit date | 2026-08-22T16:02:51-04:00 |
| Library version | development snapshot, not a tagged release: `git describe --tags` gives `v12.4.0-26-gdfd25112` (26 commits after `v12.4.0`); `include/qpdf/DLL.h` at this revision already reports `12.4.1` |
| Licence | Apache-2.0 — see `LICENSE-qpdf.txt` (`cfc7749b96f63bd3`) |
| NOTICE | `NOTICE-qpdf.md` (`b207f65a9e549119`) — reproduced **verbatim**, Apache-2.0 §4(d) |
| Secondary licence | `LICENSE-qpdf-Artistic-2.0.txt` (`fb929ac30decb4dc`) — the pre-v7 dual option the NOTICE refers to |
| Vendored on | 2026-08-23 |
| Vendored by | Zenit PDF maintainers |
| Local clone used | an upstream clone at `ExternalResearch/qpdf` (git-ignored), pinned in `Docs/Execution/RESEARCH_REPOSITORIES.lock.json` |

Apache-2.0 §4(d) makes redistribution of `NOTICE.md` **mandatory** because qpdf
ships one. `NOTICE-qpdf.md` next to this file is that file byte for byte —
`shasum -a 256` matches the value recorded in the lock file. Do not summarise,
reformat or excerpt it: the section-4(d) obligation is on the contents. That
includes the MIT notice for the embedded sphlib SHA-2 code, which qpdf carries
inside `NOTICE.md` rather than in a separate file, so it ships verbatim with it.

One compiled source carries a licence that `NOTICE.md` does not mention:
`libqpdf/MD5_native.cc` is derived from the RSA Data Security, Inc. MD5
Message-Digest Algorithm, and its header requires the RSA notice to be retained
in every copy. The file is vendored unmodified, so the source keeps the notice,
and `Scripts/regenerate-bundle-licences.sh` copies that header verbatim into the
shipped qpdf notice (`Apps/ZenitPDF/Bundle/Licenses/qpdf.txt`).

Building with SwiftPM instead of CMake removes the CMake prerequisite, and — far
more importantly — removes CMake's *dependency probing*, which is where the two
real hazards in packaging qpdf live. Both are settled statically below.

---

## 1. Crypto provider: native only, never GnuTLS

qpdf supports three crypto providers. Its CMake defaults `USE_IMPLICIT_CRYPTO=ON`
and then, in `libqpdf/CMakeLists.txt`, probes for OpenSSL and GnuTLS and prefers
**GnuTLS** when found (`if(USE_CRYPTO_GNUTLS) set(DEFAULT_CRYPTO "gnutls")`),
falling back to the native provider only when neither is installed. GnuTLS is
**LGPL-2.1-or-later**. A build machine with `gnutls` installed would therefore
have produced a Zenit PDF that links LGPL code, silently, with no diff to review.

Since there is no CMake here, the choice is made in three places at once, so that
no single mistake can undo it:

1. **Sources.** Only `QPDFCrypto_native.cc`, `AES_PDF_native.cc`, `MD5_native.cc`,
   `RC4_native.cc`, `SHA2_native.cc`, `rijndael.cc`, `sha2.c` and `sha2big.c` are
   vendored. `QPDFCrypto_gnutls.cc` and `QPDFCrypto_openssl.cc` are not copied.
2. **Headers.** `qpdf/QPDFCrypto_gnutls.hh` and `qpdf/QPDFCrypto_openssl.hh` are
   not copied either. `QPDFCryptoProvider.cc` includes them under
   `#ifdef USE_CRYPTO_GNUTLS` / `#ifdef USE_CRYPTO_OPENSSL`, so defining either
   macro by accident is a **compile error**, not a new dependency.
3. **Config.** `qpdf-config.h` defines `USE_CRYPTO_NATIVE 1` and
   `DEFAULT_CRYPTO "native"`, and defines neither of the other two.

### Proof, not assertion

Over the 89 object files the `CQPDF` target produces (57 039 symbols):

```
$ nm -o $(find .build -name "*.o" -path "*CQPDF*") | \
    grep -icE "gnutls|_EVP_|_SSL_|openssl|jpeg_|jinit_"
0
```

and the linked test binary pulls in nothing beyond libc++, zlib and libSystem:

```
$ otool -L .../QPDFBridgePackageTests
	/usr/lib/libc++.1.dylib
	/usr/lib/libz.1.dylib
	/usr/lib/libSystem.B.dylib
	(plus CoreGraphics/PDFKit/ImageIO/CryptoKit, which only the tests use)
```

`BuildFactsTests.testCryptoProviderIsNative` asserts
`QPDFCryptoProvider::getDefaultProvider() == "native"` at runtime as well, so a
regression fails the suite rather than only the licence review.

zlib is the one external library this bridge does link. It is part of the macOS
SDK (`libz.tbd`), is zlib-licensed, and `Pl_Flate.cc` cannot work without it.

---

## 2. `qpdf-config.h` is hand-written

Upstream generates `qpdf/qpdf-config.h` from `qpdf-config.h.in` with CMake's
`configure_file()` after ~10 `check_symbol_exists` / `check_c_source_compiles`
probes. There is no configure step here, so
`Sources/CQPDF/upstream/libqpdf/qpdf/qpdf-config.h` is written by hand. **Every
macro is documented in the file itself**, including the ones deliberately left
undefined, with the probe that decided it. The probes were run by compiling the
exact programs from `libqpdf/CMakeLists.txt` on macOS 26.5 with Apple clang.

Summary of the decisions:

| Macro | Value | Why |
|---|---|---|
| `USE_CRYPTO_NATIVE` | `1` | §1 above |
| `DEFAULT_CRYPTO` | `"native"` | §1 above |
| `USE_CRYPTO_GNUTLS`, `USE_CRYPTO_OPENSSL` | undefined | §1 above |
| `USE_INSECURE_RANDOM`, `SKIP_OS_SECURE_RANDOM` | undefined | keeps OS entropy for AES keys and password salts |
| `ZOPFLI` | undefined | zopfli is not vendored |
| `AVOID_WINDOWS_HANDLE` | undefined | Windows only |
| `HAVE_INTTYPES_H`, `HAVE_STDINT_H` | `1` | both exist on Darwin |
| `HAVE_FSEEKO` | `1` | Darwin `fseeko` takes a 64-bit `off_t` |
| `HAVE_FSEEKO64` | undefined | glibc extension; the probe fails to link |
| `HAVE_LOCALTIME_R` | `1` | otherwise qpdf uses the non-reentrant `localtime()` |
| `HAVE_RANDOM` | `1` | BSD `random()` exists |
| `HAVE_TM_GMTOFF` | `1` | BSD `struct tm` has it, and it is DST-correct |
| `HAVE_EXTERN_LONG_TIMEZONE` | **undefined although the probe passes** | `QUtil.cc:898` prefers `tm_gmtoff`; the global `timezone` ignores DST, so this branch would be both unreachable and wrong |
| `HAVE_MALLOC_INFO` | undefined | glibc only; `<malloc.h>` does not exist |
| `HAVE_OPEN_MEMSTREAM` | `1` | POSIX 2008, present since macOS 10.13 |
| `_FILE_OFFSET_BITS` | **undefined** | Darwin's `off_t` is already 64-bit, so upstream's `LFS_WITHOUT_MACROS` probe passes and CMake would not define it either. Defining it on Darwin is unsupported and risks ODR skew on `struct stat` |
| `SIZEOF_SIZE_T` | `8` | LP64 on both arm64 and x86_64; guarded by `#error` against `__SIZEOF_SIZE_T__` |

Three things worth recording because they are easy to get wrong:

- **`HAVE_TM_GMTOFF` is tested with `#if`, not `#ifdef`**, so it must be defined
  *to 1*.
- **Upstream's CMake has a bug here.** The probe writes its result into
  `HAVE_EXTERN_TM_GMTOFF` (`CMakeLists.txt:351`) while the template asks for
  `HAVE_TM_GMTOFF` (`qpdf-config.h.in:21`). A CMake build therefore never defines
  it and always takes the DST-blind `timezone` branch. Writing the header by hand
  lets this build take the correct branch.
- Endianness has no macro in the upstream template because qpdf serialises byte
  by byte everywhere; the hand-written header adds an `#error` guard so that the
  little-endian assumption is at least stated.

---

## 3. JPEG: built **without** DCT, and the consequence is tested

`Pl_DCT.cc` needs libjpeg, and `include/qpdf/Pl_DCT.hh` includes `<jpeglib.h>`
unconditionally. macOS ships no public libjpeg — there is no `jpeglib.h` in the
SDK — and upstream qpdf has no "build without JPEG" switch: its CMake hard-fails
with `message(SEND_ERROR "libjpeg not found")`.

### The decision

**Build without DCT.** Vendoring libjpeg-turbo (BSD-3-Clause, and licence-wise
perfectly acceptable) was rejected for two reasons:

1. There is no libjpeg-turbo source in the pinned research clones and this build
   has no network access, so it cannot be vendored from a verifiable, pinned
   revision. Copying pdfium's bundled copy out of another vendor tree would
   introduce a dependency with no entry in `RESEARCH_REPOSITORIES.lock.json`.
2. It buys nothing this product needs. Zenit PDF's qpdf role is repair,
   linearization, structural page work and decryption, all inside
   RepairService. None of those decode image data. libjpeg would only be
   exercised by `--optimize-images`-style re-encoding, which is not a feature.

### How it is done

Four upstream files are affected: three are left out, and one is modified:

- `Pl_DCT.cc`, `include/qpdf/Pl_DCT.hh` and `qpdf/SF_DCTDecode.hh` are **not
  vendored at all**, so nothing can accidentally reach for `<jpeglib.h>`.
- `libqpdf/QPDF_Stream.cc` is modified in three places, all guarded by
  `ZPDF_QPDF_NO_DCT` (defined in `Package.swift`), leaving the upstream code
  intact when the macro is absent. As Apache-2.0 §4(b) requires, the file also
  opens with a comment block stating that it was modified, by whom and when, the
  upstream revision it is otherwise identical to, and what was changed:

```c++
#ifndef ZPDF_QPDF_NO_DCT  /* Zenit PDF: built without libjpeg */
# include <qpdf/SF_DCTDecode.hh>
#endif
...
#ifndef ZPDF_QPDF_NO_DCT
    if (name == "/DCTDecode") { return SF_DCTDecode::factory; }
#endif
```

`QPDF_Stream::Members::filter_factory` already returns `nullptr` for filters it
does not know — that is how `/CCITTFaxDecode` and `/JPXDecode` are handled
upstream — so removing the `/DCTDecode` registration puts DCT on exactly the same
well-trodden path rather than on a new one.

### What actually breaks — measured, not assumed

`DCTPassthroughTests` builds a real one-page PDF whose image is a real JPEG
produced by ImageIO, and checks:

| Behaviour | Result |
|---|---|
| A DCT-bearing PDF opens (`inspect`) | ✅ yes |
| The DCT stream is classified `unfilterable`, not damage | ✅ yes; `needsRepair == false` |
| Repair produces a file CoreGraphics opens | ✅ yes, 1 page |
| The JPEG bytes survive the repair | ✅ byte-for-byte identical (`Data.range(of:)` on the 1 726-byte JPEG) |
| A DCT-bearing PDF with a **broken xref** repairs | ✅ yes, and the JPEG is still byte-identical |
| Other filters still decode | ✅ Flate content streams decode normally |

The one thing that is genuinely lost: qpdf cannot *decode* DCT data, so
`inspect` cannot verify that a JPEG's contents are well-formed, and
`--decode-level=all`-style re-encoding is unavailable. Neither is a Zenit PDF
feature. Rendering JPEGs remains CoreGraphics' job, and CoreGraphics has its own
decoder.

If DCT decoding is ever needed, the route back is small: vendor libjpeg-turbo,
restore the three files listed above, and drop the `ZPDF_QPDF_NO_DCT` define.

---

## 4. One more upstream limitation, worked around in the shim

`QPDFWriter::writeTrailer` (`QPDFWriter.cc:1484`) builds the output trailer by
walking the keys of the **input** trailer and substituting the real object count
when it reaches `/Size`. When a file is damaged badly enough that qpdf cannot
find a trailer at all — the `hostile-truncated` fixture, where qpdf warns "unable
to find trailer dictionary while recovering damaged file" — the reconstructed
trailer holds only `/Root`, the loop never visits `/Size`, and **the repaired
output is written without one**. `/Size` is required by ISO 32000-1 table 15, and
CoreGraphics rejects such a file outright, which would make "repair" produce
something no reader can open.

`ensure_trailer_has_size()` in `zpdf_qpdf_shim.cc` seeds a placeholder `/Size 0`
into the in-memory trailer before every write, so the writer visits the key and
emits the true value. This touches the in-memory document only; no input file is
ever opened for writing anywhere in this bridge.

`RepairTests.truncatedFileIsRepaired` is the regression test: without this step,
PDFKit returns `nil` for the repaired file.

---

## 5. What was deliberately **not** vendored

| Left out | Why |
|---|---|
| `QPDFJob*.cc`, `QPDFArgParser.cc`, `include/qpdf/QPDFJob.hh`, `libqpdf/qpdf/auto_job_*.hh` | the command-line job layer; the bridge drives `QPDF`/`QPDFWriter` directly (the nine public `include/qpdf/auto_job_c_*.hh` headers were copied; see below) |
| `qpdf-c.cc`, `qpdfjob-c.cc`, `qpdflogger-c.cc` | upstream's own C API; this bridge has its own, narrower one |
| `Pl_DCT.cc`, `Pl_DCT.hh`, `SF_DCTDecode.hh` | §3 |
| `QPDFCrypto_gnutls.{cc,hh}`, `QPDFCrypto_openssl.{cc,hh}` | §1 |
| `libtests/`, `qtest/`, `fuzz/`, `examples/`, `manual/`, all CMake files | not needed to build a library |

The vendored source set is the transitive `#include` closure of the compiled
sources, plus twelve upstream headers that nothing compiled includes: the nine
public `include/qpdf/auto_job_c_*.hh` headers (upstream includes them only from
`QPDFJob.hh`, which is not vendored), `include/qpdf/PointerHolder.hh`,
`include/qpdf/QPDFObject.hh` (an `#error` stub upstream) and the empty
`libqpdf/qpdf/QPDF_Name.hh`. They are byte-identical upstream copies that keep
their Apache-2.0 headers, and they are never compiled. Nothing needed is missing;
`swift build` with zero warnings is the check.

---

## 6. Layout, and why it is shaped this way

```
Sources/CQPDF/
  include/zpdf_qpdf.h              the ONLY public header — pure C, no C++
  src/zpdf_qpdf_shim.cc            the extern "C" implementation
  upstream/include/qpdf/*.hh|h     qpdf public headers   (header search path)
  upstream/libqpdf/*.cc|c          qpdf sources          (compiled)
  upstream/libqpdf/qpdf/*.hh|h     qpdf private headers + hand-written config
  upstream/sphinclude/sph/*        bundled sphlib SHA-2
```

Two layout details are load-bearing:

- **`sph/` sits outside the compiled directory.** `sha2.c` does
  `#include "sph/md_helper.c"` — a `.c` file used as a header. If it lived under
  `upstream/libqpdf/`, SwiftPM would compile it as its own translation unit and
  the build would fail on duplicate symbols. It is reached through
  `.headerSearchPath("upstream/sphinclude")` instead.
- **No Swift/C++ interop.** The public header exposes only C types, exactly as
  `Bridges/Clipper2Bridge` does, so no downstream Zenit PDF target has to enable
  `.interoperabilityMode(.Cxx)` and nothing has to reason about `Sendable` for a
  `std::shared_ptr<QPDF>`.

### Files written by Zenit PDF (not upstream)

| File | Role |
|---|---|
| `Sources/CQPDF/include/zpdf_qpdf.h` | the only public header — pure C |
| `Sources/CQPDF/src/zpdf_qpdf_shim.cc` | `extern "C"` implementation over qpdf |
| `Sources/CQPDF/upstream/libqpdf/qpdf/qpdf-config.h` | §2 |
| `Sources/ZPDFQPDF/*.swift` | the Swift API |
| `Package.swift`, `Tests/` | packaging and tests |

---

## 7. Refreshing the vendored copy

1. `git -C ExternalResearch/qpdf pull` and update
   `Docs/Execution/RESEARCH_REPOSITORIES.lock.json`.
2. Re-copy the files listed in §8 (upstream paths are unchanged).
3. Re-apply the `ZPDF_QPDF_NO_DCT` guards **and** the Apache-2.0 §4(b)
   modification notice at the top of `QPDF_Stream.cc` (§3), updating the upstream
   revision named in the notice to the new pin. This is the only modified upstream
   file, and the only step that is not a plain copy.
4. Re-check `qpdf-config.h.in` for new `#cmakedefine` lines and add them to
   `qpdf-config.h` with a documented decision.
5. Re-check whether `QPDFWriter::writeTrailer` still needs the `/Size` workaround
   (§4); if upstream fixes it, delete `ensure_trailer_has_size` and confirm
   `RepairTests.truncatedFileIsRepaired` still passes.
6. `swift build && swift test` in `Bridges/QPDFBridge`, then re-run the `nm`
   check from §1.
7. Update the hashes in §8.

---

## 8. Exactly what was copied

Copied byte-for-byte except where the table says otherwise. SHA-256 prefixes are
of the **vendored** copy, and the "verbatim" column is the result of comparing it
against the pinned clone, so drift in either direction is detectable. Four files
(`QPDFNameTreeObjectHelper.cc`, `QPDFNumberTreeObjectHelper.cc`, `QPDF_Name.hh` and
`auto_job_c_limits.hh`) are empty at the pinned revision upstream as well; their prefix
`e3b0c44298fc1c14` is the SHA-256 of an empty file, and they are copied as they are.

#### Public headers -> `Sources/CQPDF/upstream/include/qpdf/`

| File | SHA-256 (first 16) | verbatim |
|---|---|---|
| `Buffer.hh` | `ec2a9ee18aa352ae` | yes |
| `BufferInputSource.hh` | `42e52c9831441422` | yes |
| `ClosedFileInputSource.hh` | `9cd69d69765dbd3d` | yes |
| `Constants.h` | `04b3907ac1abd016` | yes |
| `DLL.h` | `00293c15624187d0` | yes |
| `FileInputSource.hh` | `2ad4ce78f9787360` | yes |
| `InputSource.hh` | `235596a597b5d56f` | yes |
| `JSON.hh` | `75f4f3c8ec9b9391` | yes |
| `ObjectHandle.hh` | `5659a3f483e0b4df` | yes |
| `PDFVersion.hh` | `d413f4a9a2e5b28d` | yes |
| `Pipeline.hh` | `72162887d2c339e3` | yes |
| `Pl_Buffer.hh` | `50abbae1e7bd3117` | yes |
| `Pl_Concatenate.hh` | `e15a5886ad8534f0` | yes |
| `Pl_Count.hh` | `8fe22c357420a834` | yes |
| `Pl_Discard.hh` | `bc48d0223cd0b03a` | yes |
| `Pl_Flate.hh` | `c765e118f67dd06a` | yes |
| `Pl_Function.hh` | `d66601d7441b0332` | yes |
| `Pl_OStream.hh` | `ef3d42a32df30b76` | yes |
| `Pl_QPDFTokenizer.hh` | `07d80d6bdfd886dc` | yes |
| `Pl_RunLength.hh` | `4e0b2037b64b69ef` | yes |
| `Pl_StdioFile.hh` | `86ae4ec57868dbab` | yes |
| `Pl_String.hh` | `2479e920d448ed8c` | yes |
| `PointerHolder.hh` | `7638df03176cda3a` | yes |
| `QIntC.hh` | `2f4f8a160203b0ab` | yes |
| `QPDF.hh` | `91823bbfed23e610` | yes |
| `QPDFAcroFormDocumentHelper.hh` | `5fdf36ac5b4fbc71` | yes |
| `QPDFAnnotationObjectHelper.hh` | `52aa6d5a1370d9fe` | yes |
| `QPDFCryptoImpl.hh` | `0a950ff01edddddd` | yes |
| `QPDFCryptoProvider.hh` | `fc63b344658703b1` | yes |
| `QPDFDocumentHelper.hh` | `ba9e6c5b93fda9d2` | yes |
| `QPDFEFStreamObjectHelper.hh` | `a9bc391294b61ad4` | yes |
| `QPDFEmbeddedFileDocumentHelper.hh` | `878098d1b6bd6169` | yes |
| `QPDFExc.hh` | `7a9b5b43ac4d0524` | yes |
| `QPDFFileSpecObjectHelper.hh` | `5376e700dd2574bf` | yes |
| `QPDFFormFieldObjectHelper.hh` | `fb9d1f12c4c74b0f` | yes |
| `QPDFLogger.hh` | `d10266ffdf970fa1` | yes |
| `QPDFMatrix.hh` | `e5427ef340c57940` | yes |
| `QPDFNameTreeObjectHelper.hh` | `954ee4c1a024f59a` | yes |
| `QPDFNumberTreeObjectHelper.hh` | `2ffbad677b89582c` | yes |
| `QPDFObjGen.hh` | `796fef284b3ddb93` | yes |
| `QPDFObject.hh` | `5a243a70a88f0cb0` | yes |
| `QPDFObjectHandle.hh` | `49be64aa5dc4da94` | yes |
| `QPDFObjectHelper.hh` | `f2dba00d2a792459` | yes |
| `QPDFOutlineDocumentHelper.hh` | `2bf70658b6fbfb95` | yes |
| `QPDFOutlineObjectHelper.hh` | `51b93e351b6cb338` | yes |
| `QPDFPageDocumentHelper.hh` | `24b4e82f2d44194c` | yes |
| `QPDFPageLabelDocumentHelper.hh` | `cc8bfe710ef54daf` | yes |
| `QPDFPageObjectHelper.hh` | `2f0df4b47a37be93` | yes |
| `QPDFStreamFilter.hh` | `d7ba1fdfdfa1e1a8` | yes |
| `QPDFSystemError.hh` | `a9562e21bacc5a09` | yes |
| `QPDFTokenizer.hh` | `1382ad74e399f2ff` | yes |
| `QPDFUsage.hh` | `ec6414cb4cfb22f6` | yes |
| `QPDFWriter.hh` | `ce8a048777936419` | yes |
| `QPDFXRefEntry.hh` | `fc89c061f0832fa1` | yes |
| `QTC.hh` | `f3920033e23bbd8e` | yes |
| `QUtil.hh` | `e831197756fcce4a` | yes |
| `RandomDataProvider.hh` | `0b6f8f9231688913` | yes |
| `Types.h` | `7dcecc58966e093c` | yes |
| `auto_job_c_att.hh` | `4c2b171ea00531db` | yes |
| `auto_job_c_copy_att.hh` | `50609012bff14fd8` | yes |
| `auto_job_c_enc.hh` | `28446f3c32153a52` | yes |
| `auto_job_c_global.hh` | `7df0ff87d18d7fa6` | yes |
| `auto_job_c_limits.hh` | `e3b0c44298fc1c14` | yes |
| `auto_job_c_main.hh` | `7a50de4a051fe68b` | yes |
| `auto_job_c_pages.hh` | `9f628e24f11c7877` | yes |
| `auto_job_c_set_page_labels.hh` | `b3cc0f21029f6d89` | yes |
| `auto_job_c_uo.hh` | `3084b3e2e2d62941` | yes |
| `global.hh` | `ab11aed1b58a8ab3` | yes |
| `qpdf-c.h` | `b6e4ffb5f81e471e` | yes |
| `qpdflogger-c.h` | `f98a8982e3e6ebc3` | yes |

#### Private headers -> `Sources/CQPDF/upstream/libqpdf/qpdf/`

| File | SHA-256 (first 16) | verbatim |
|---|---|---|
| `AES_PDF_native.hh` | `714c18fecc1b55cd` | yes |
| `AcroForm.hh` | `6537112d460d03fd` | yes |
| `BitStream.hh` | `e0b7dd6ed0ae2030` | yes |
| `BitWriter.hh` | `434ac6291f07b097` | yes |
| `ContentNormalizer.hh` | `3ffaaa22b6c22c28` | yes |
| `CryptoRandomDataProvider.hh` | `5b663fe5a739781d` | yes |
| `InputSource_private.hh` | `158e6ba4e1da1a8f` | yes |
| `InsecureRandomDataProvider.hh` | `40343ee8fdc09071` | yes |
| `JSONHandler.hh` | `a47162332c024be2` | yes |
| `JSON_writer.hh` | `16585fa555380c84` | yes |
| `MD5.hh` | `23c40f549719ac70` | yes |
| `MD5_native.hh` | `16c949971b51fc55` | yes |
| `NNTree.hh` | `33e354703f318edb` | yes |
| `ObjTable.hh` | `373b0e00e9eceb78` | yes |
| `OffsetInputSource.hh` | `199d4ab6f5285790` | yes |
| `Pipeline_private.hh` | `da72609e315c3de8` | yes |
| `Pl_AES_PDF.hh` | `485fb68cda973716` | yes |
| `Pl_ASCII85Decoder.hh` | `e148e601628458f0` | yes |
| `Pl_ASCIIHexDecoder.hh` | `d0a801230160f392` | yes |
| `Pl_Base64.hh` | `9c042a9018a5047a` | yes |
| `Pl_LZWDecoder.hh` | `688c8f5ba5cb3d01` | yes |
| `Pl_MD5.hh` | `e540c1c7d510d1bf` | yes |
| `Pl_PNGFilter.hh` | `ab65082ae18fc370` | yes |
| `Pl_RC4.hh` | `d76ebd8ce1a33871` | yes |
| `Pl_SHA2.hh` | `07781c0f78c11e7e` | yes |
| `Pl_TIFFPredictor.hh` | `58779e45d5a0782b` | yes |
| `QPDFCrypto_native.hh` | `cda3fa370c3656b0` | yes |
| `QPDFObjectHandle_private.hh` | `327f8e378f7a00ce` | yes |
| `QPDFObject_private.hh` | `bcea790b3f23e022` | yes |
| `QPDFParser.hh` | `ff19e360f1f992ad` | yes |
| `QPDFTokenizer_private.hh` | `231c0fdb90cad0d1` | yes |
| `QPDFWriter_private.hh` | `fddceb9024971a3e` | yes |
| `QPDF_Name.hh` | `e3b0c44298fc1c14` | yes |
| `QPDF_private.hh` | `6e6b7875eb7d44f6` | yes |
| `RC4.hh` | `3f8d2501ed9c057f` | yes |
| `RC4_native.hh` | `f56776cd9c860873` | yes |
| `ResourceFinder.hh` | `b4d1a0a48d90165b` | yes |
| `SF_ASCII85Decode.hh` | `9d633ce7e325e4a7` | yes |
| `SF_ASCIIHexDecode.hh` | `69b08ea121cc1031` | yes |
| `SF_FlateLzwDecode.hh` | `6b2c84a264acea09` | yes |
| `SF_RunLengthDecode.hh` | `3748de557a3154e3` | yes |
| `SHA2_native.hh` | `e24acb90bb124d17` | yes |
| `SecureRandomDataProvider.hh` | `2bdea1beadb088eb` | yes |
| `Util.hh` | `90c2715ba54a662c` | yes |
| `assert_debug.h` | `ff376f5622864edd` | yes |
| `assert_test.h` | `f934776eaf1cf841` | yes |
| `bits_functions.hh` | `ee2cd3b61863c2df` | yes |
| `global_private.hh` | `24ec7530669f772c` | yes |
| `qpdf-config.h` | `f841b166091c9980` | **written by Zenit PDF** |
| `rijndael.h` | `d0b3961f1ad7b9c9` | yes |

#### sphlib SHA-2 -> `Sources/CQPDF/upstream/sphinclude/sph/`

| File | SHA-256 (first 16) | verbatim |
|---|---|---|
| `md_helper.c` | `9dd8ffa596b1a322` | yes |
| `sph_sha2.h` | `84a9eacd97037138` | yes |
| `sph_types.h` | `46f31eaa07047bc2` | yes |

#### Sources -> `Sources/CQPDF/upstream/libqpdf/`

| File | SHA-256 (first 16) | verbatim |
|---|---|---|
| `AES_PDF_native.cc` | `f45d0bb7608c6f65` | yes |
| `BitStream.cc` | `b7387b51a4f0a06d` | yes |
| `BitWriter.cc` | `1d3fda0f67282e61` | yes |
| `Buffer.cc` | `a975c23d0da4a4f8` | yes |
| `BufferInputSource.cc` | `ff722896eab1944d` | yes |
| `ClosedFileInputSource.cc` | `f929e1c40c5d6527` | yes |
| `ContentNormalizer.cc` | `5ee2c032a6b7a94a` | yes |
| `CryptoRandomDataProvider.cc` | `d1ab2753f228fa99` | yes |
| `FileInputSource.cc` | `ad87ba5daa9315d7` | yes |
| `InputSource.cc` | `6e128e5f92885618` | yes |
| `InsecureRandomDataProvider.cc` | `7d51d15e51961c8a` | yes |
| `JSON.cc` | `1a42aafbf1458c46` | yes |
| `JSONHandler.cc` | `e8b870351e47394d` | yes |
| `MD5.cc` | `bf86e627520f21a0` | yes |
| `MD5_native.cc` | `0534460b7414e3a2` | yes |
| `NNTree.cc` | `2aa2ffb9e5e30004` | yes |
| `OffsetInputSource.cc` | `809446bbb6bdb427` | yes |
| `PDFVersion.cc` | `71ae267e17d3155d` | yes |
| `Pipeline.cc` | `81cd4bbd49d9426d` | yes |
| `Pl_AES_PDF.cc` | `26cba123909946ed` | yes |
| `Pl_ASCII85Decoder.cc` | `a74a0ffb6e956735` | yes |
| `Pl_ASCIIHexDecoder.cc` | `ac407b0f2ca60154` | yes |
| `Pl_Base64.cc` | `081cf6ed2ddf0425` | yes |
| `Pl_Buffer.cc` | `80646526215391a6` | yes |
| `Pl_Concatenate.cc` | `f23c5c644771eedb` | yes |
| `Pl_Count.cc` | `21b9f015d5ce7f36` | yes |
| `Pl_Discard.cc` | `2fa1457c90230460` | yes |
| `Pl_Flate.cc` | `f21c7af0cd841147` | yes |
| `Pl_Function.cc` | `277cd94c02fd1499` | yes |
| `Pl_LZWDecoder.cc` | `ccd57ee12c31efc3` | yes |
| `Pl_OStream.cc` | `236b80bdaf6e6b57` | yes |
| `Pl_PNGFilter.cc` | `aaed42ca0ba0775d` | yes |
| `Pl_QPDFTokenizer.cc` | `bad88e3ecccc2a14` | yes |
| `Pl_RC4.cc` | `3405d5a5eb3d6eec` | yes |
| `Pl_RunLength.cc` | `5259b36f48d8cc2f` | yes |
| `Pl_SHA2.cc` | `842d04e9df86ae1d` | yes |
| `Pl_StdioFile.cc` | `a6478c5ade2d8f8a` | yes |
| `Pl_String.cc` | `adebe2111cb9f4e6` | yes |
| `Pl_TIFFPredictor.cc` | `cff2d51fc5a83f15` | yes |
| `QPDF.cc` | `4ff62d8ff0951dde` | yes |
| `QPDFAcroFormDocumentHelper.cc` | `845ce9f3085750c6` | yes |
| `QPDFAnnotationObjectHelper.cc` | `9153efcb822fd36e` | yes |
| `QPDFCryptoProvider.cc` | `75e6aa168ea7b426` | yes |
| `QPDFCrypto_native.cc` | `bec91f3d1db85955` | yes |
| `QPDFDocumentHelper.cc` | `4c5acfacfb3f8a34` | yes |
| `QPDFEFStreamObjectHelper.cc` | `76154166b3abde61` | yes |
| `QPDFEmbeddedFileDocumentHelper.cc` | `5ced4c949286c3da` | yes |
| `QPDFExc.cc` | `c7a11afc5077d3bc` | yes |
| `QPDFFileSpecObjectHelper.cc` | `ccb8f1c7cfabb5e0` | yes |
| `QPDFFormFieldObjectHelper.cc` | `dc0858ab9cbc5451` | yes |
| `QPDFLogger.cc` | `f0b20c8c38500401` | yes |
| `QPDFMatrix.cc` | `4460755f285f0d6a` | yes |
| `QPDFNameTreeObjectHelper.cc` | `e3b0c44298fc1c14` | yes |
| `QPDFNumberTreeObjectHelper.cc` | `e3b0c44298fc1c14` | yes |
| `QPDFObject.cc` | `7815bc6d3f88a600` | yes |
| `QPDFObjectHandle.cc` | `c19ecec9ab751e9a` | yes |
| `QPDFObjectHelper.cc` | `713ec2949496fc14` | yes |
| `QPDFOutlineDocumentHelper.cc` | `faf2e5a4a8de474d` | yes |
| `QPDFOutlineObjectHelper.cc` | `3994943fc2ff43e7` | yes |
| `QPDFPageLabelDocumentHelper.cc` | `4c8aa9421dad45cd` | yes |
| `QPDFPageObjectHelper.cc` | `a3fbdf06c7ef0d73` | yes |
| `QPDFParser.cc` | `5e5af30087972054` | yes |
| `QPDFStreamFilter.cc` | `1b5548ec1d40cb25` | yes |
| `QPDFSystemError.cc` | `bab37300aac70ee1` | yes |
| `QPDFTokenizer.cc` | `9247da378bae782b` | yes |
| `QPDFUsage.cc` | `8991f1e90ed133e0` | yes |
| `QPDFWriter.cc` | `fb3d684ef095212c` | yes |
| `QPDF_Array.cc` | `5f1b2bbab07c0472` | yes |
| `QPDF_Dictionary.cc` | `863e582bc4d237fb` | yes |
| `QPDF_Stream.cc` | `133fc31f849673be` | **MODIFIED — see below** |
| `QPDF_String.cc` | `c0d5562786c7f216` | yes |
| `QPDF_encryption.cc` | `8b4a371e58a346d3` | yes |
| `QPDF_json.cc` | `657c88df21d4b7b4` | yes |
| `QPDF_linearization.cc` | `cad31775faa298cb` | yes |
| `QPDF_objects.cc` | `af850c896d4e6483` | yes |
| `QPDF_pages.cc` | `dd91e097a67c5a8d` | yes |
| `QTC.cc` | `71714c1e0ae97fb8` | yes |
| `QUtil.cc` | `ee4924770f421844` | yes |
| `RC4.cc` | `47a0dd9ca5b66e26` | yes |
| `RC4_native.cc` | `6c6e8867db3c6d62` | yes |
| `ResourceFinder.cc` | `9c565b1c44218cde` | yes |
| `SF_FlateLzwDecode.cc` | `2ebee9c833ee0456` | yes |
| `SHA2_native.cc` | `461673bf5a042e64` | yes |
| `SecureRandomDataProvider.cc` | `d971e0e1c69f748e` | yes |
| `global.cc` | `ece2398da3e337c5` | yes |
| `rijndael.cc` | `980aed046aba66fd` | yes |
| `sha2.c` | `61a935ae0cb89fa8` | yes |
| `sha2big.c` | `724c67f04aa130b7` | yes |

Total vendored files: 211

### The one modified upstream file

`libqpdf/QPDF_Stream.cc` differs from the pinned clone in four hunks: the
Apache-2.0 §4(b) modification notice added at the top of the file, and the three
`#ifndef ZPDF_QPDF_NO_DCT` guards described in §3. Nothing else in the vendored
tree differs from upstream. To see the diff:

```
diff -u ExternalResearch/qpdf/libqpdf/QPDF_Stream.cc \
        Bridges/QPDFBridge/Sources/CQPDF/upstream/libqpdf/QPDF_Stream.cc
```
