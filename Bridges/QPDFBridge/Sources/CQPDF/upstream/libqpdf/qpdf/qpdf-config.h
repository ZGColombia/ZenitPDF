/*
 * qpdf-config.h — hand-written for Zenit PDF.
 *
 * NOT an upstream file. Upstream generates this from
 * `libqpdf/qpdf/qpdf-config.h.in` with CMake's `configure_file()` after running
 * a set of `check_symbol_exists` / `check_c_source_compiles` probes. Zenit PDF
 * builds qpdf with SwiftPM and never runs CMake, so the probe results are
 * written out here by hand. Every macro below corresponds to one `#cmakedefine`
 * line in the upstream template, in the template's own order, and every
 * decision is justified.
 *
 * Target: macOS 14+ (arm64 and x86_64), Apple clang, libc++, Darwin libc.
 * Probed on macOS 26.5 / Apple clang (Xcode 26.6) on 2026-08-23 by compiling
 * the exact probe programs from `libqpdf/CMakeLists.txt` lines 328-400.
 *
 * A macro that upstream would leave undefined is left undefined here and the
 * reason is written next to it, because "absent" is a decision too.
 */

#ifndef QPDF_CONFIG_H
#define QPDF_CONFIG_H

/* ---- options ----------------------------------------------------------- */

/* AVOID_WINDOWS_HANDLE: Windows-only. Not defined. */

/*
 * DEFAULT_CRYPTO / USE_CRYPTO_NATIVE.
 *
 * This is the single most important line in this file. Upstream's CMake
 * defaults `USE_IMPLICIT_CRYPTO=ON`, which probes for OpenSSL and then GnuTLS
 * and silently prefers GnuTLS (LGPL-2.1-or-later) when it is present, only
 * falling back to the native provider when neither is found. Zenit PDF ships
 * under MIT and must not acquire an LGPL link-time dependency by accident, so
 * the choice is made statically here instead of by probing the build machine:
 *
 *   - `QPDFCrypto_gnutls.cc` and `QPDFCrypto_openssl.cc` are NOT vendored,
 *   - `qpdf/QPDFCrypto_gnutls.hh` and `qpdf/QPDFCrypto_openssl.hh` are NOT
 *     vendored either, so an accidental `#define USE_CRYPTO_GNUTLS` fails to
 *     compile rather than linking GnuTLS,
 *   - only the native provider is compiled: `QPDFCrypto_native.cc`,
 *     `AES_PDF_native.cc`, `MD5_native.cc`, `RC4_native.cc`, `SHA2_native.cc`,
 *     `rijndael.cc`, `sha2.c`, `sha2big.c`.
 *
 * `DEFAULT_CRYPTO` is the provider name `QPDFCryptoProvider` selects when the
 * caller does not name one, and is also what `getDefaultProvider()` reports.
 */
#define DEFAULT_CRYPTO "native"
#define USE_CRYPTO_NATIVE 1

/* USE_CRYPTO_GNUTLS: deliberately NOT defined — LGPL-2.1+, see above. */
/* USE_CRYPTO_OPENSSL: deliberately NOT defined — not vendored, see above. */

/*
 * USE_INSECURE_RANDOM: not defined. When defined, qpdf's
 * `SecureRandomDataProvider` is replaced with `random()`-based output, which
 * would weaken AES-256 file-encryption keys and /U /O validation salts.
 * SKIP_OS_SECURE_RANDOM: not defined. Leaving it undefined lets
 * `SecureRandomDataProvider.cc` use the OS entropy source; on Darwin that is
 * `/dev/urandom` via `std::random_device`'s fallback path in qpdf's own code.
 */

/* ZOPFLI: not defined. Zopfli is an optional extra deflate encoder and is not
 * vendored; `Pl_Flate.cc` compiles its zlib path instead. */

/* ---- large file support ------------------------------------------------ */

/*
 * _FILE_OFFSET_BITS: deliberately NOT defined.
 *
 * Upstream defines it to 64 only when `sizeof(off_t) >= 8` fails WITHOUT the
 * macro and succeeds WITH it (`LFS_WITH_MACROS AND NOT LFS_WITHOUT_MACROS`).
 * On Darwin `off_t` is `int64_t` unconditionally, so the without-macros probe
 * already passes and upstream leaves it undefined. Probe result: compiling
 * `int a[sizeof(off_t) >= 8 ? 1 : -1];` with no macros succeeds.
 *
 * Defining it anyway would be actively harmful: on Darwin `_FILE_OFFSET_BITS`
 * is not a supported feature-test macro, and defining it in only some
 * translation units is how ODR violations on `struct stat` are born.
 */

/* ---- header files ------------------------------------------------------ */

/*
 * Both headers exist on Darwin. No translation unit in the vendored source set
 * currently reads either macro (the `sph` SHA-2 sources do their own detection
 * through `sph_types.h`), but they are part of the template's contract and are
 * set truthfully so that a future qpdf revision that starts reading them gets
 * the right answer rather than a silent "no".
 */
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1

/* ---- OS functions and symbols ------------------------------------------ */

/*
 * HAVE_EXTERN_LONG_TIMEZONE: deliberately NOT defined, even though the probe
 * passes.
 *
 * `<time.h>` on Darwin does declare `extern long timezone`, so upstream's
 * probe would set this. It is left undefined on purpose because
 * `QUtil.cc:898` prefers `HAVE_TM_GMTOFF` when both are set, and the global
 * `timezone` is the *standard-time* offset — it does not account for daylight
 * saving. Defining it here would create a branch that is unreachable in this
 * build and wrong if it ever were reached. `tm_gmtoff` is the correct source
 * and is used instead.
 */

/*
 * HAVE_FSEEKO: `fseeko`/`ftello` are declared by `<stdio.h>` on Darwin and take
 * a 64-bit `off_t`. Used by `QUtil::fseek_off_t` (QUtil.cc:549,565).
 * HAVE_FSEEKO64: NOT defined — `fseeko64` is a glibc extension and does not
 * exist on Darwin. Probe: linking `(void)fseeko64;` fails.
 */
#define HAVE_FSEEKO 1

/* HAVE_LOCALTIME_R: POSIX, present on Darwin. Used by QUtil.cc:894. Without it
 * qpdf falls back to the non-reentrant `localtime()`, which would be a data
 * race in a multi-threaded host such as ours. */
#define HAVE_LOCALTIME_R 1

/* HAVE_RANDOM: BSD `random()`, present on Darwin. Used only by
 * `InsecureRandomDataProvider.cc`, which is never selected in this build, but
 * the file is compiled and the alternative branch uses `rand()`. */
#define HAVE_RANDOM 1

/* HAVE_TM_GMTOFF: `struct tm` on Darwin (BSD) has `tm_gmtoff`, seconds east of
 * UTC, DST-adjusted. Probe: `tm.tm_gmtoff = 1;` compiles. Note that QUtil tests
 * this with `#if`, not `#ifdef`, so it must be defined to 1, not just defined.
 *
 * Upstream's own CMake has a bug here: the probe stores its result in
 * `HAVE_EXTERN_TM_GMTOFF` (CMakeLists.txt:351) while the template asks for
 * `HAVE_TM_GMTOFF` (qpdf-config.h.in:21), so a CMake build never defines it and
 * silently takes the `timezone` branch on every platform. Writing the config by
 * hand lets us take the correct branch. */
#define HAVE_TM_GMTOFF 1

/* HAVE_MALLOC_INFO: NOT defined. `malloc_info()` is glibc-only; `<malloc.h>`
 * does not exist on Darwin. Probe fails. Only affects qpdf's memory-usage
 * reporting, which reports 0 without it. */

/* HAVE_OPEN_MEMSTREAM: POSIX 2008, present on Darwin since 10.13. Probe
 * compiles and links. */
#define HAVE_OPEN_MEMSTREAM 1

/* ---- sizes ------------------------------------------------------------- */

/*
 * SIZEOF_SIZE_T: 8 on both arm64 and x86_64 macOS (LP64). Verified by running
 * `printf("%zu", sizeof(size_t))`, which prints 8. This value is correct for
 * every platform Zenit PDF supports; if a 32-bit target is ever added this file
 * must become target-conditional. Guard so that a wrong value cannot pass
 * silently:
 */
#define SIZEOF_SIZE_T 8

#if defined(__SIZEOF_SIZE_T__) && (__SIZEOF_SIZE_T__ != SIZEOF_SIZE_T)
# error "qpdf-config.h: SIZEOF_SIZE_T does not match this target's size_t."
#endif

/*
 * Byte order. The upstream template has no endianness macro because qpdf does
 * not need one: every byte-order-sensitive path (`QUtil::toUTF16`, the AES and
 * SHA-2 implementations in `rijndael.cc` and `sph/`, the xref stream writer)
 * serialises byte by byte or uses `sph_types.h`'s own detection. Both Apple
 * targets are little-endian; the assertion below exists so that this stops
 * being an unexamined assumption.
 */
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
# if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#  error "qpdf-config.h was written for little-endian Apple targets."
# endif
#endif

#endif /* QPDF_CONFIG_H */
