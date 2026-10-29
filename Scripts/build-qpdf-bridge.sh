#!/bin/bash
#
# build-qpdf-bridge.sh — the verification command for the vendored qpdf bridge.
#
#     Bridges/QPDFBridge -> Packages/ZPDFTestingSupport (test target only)
#
# This is the only package in the repository that vendors 211 files of third-party C++ and
# links them into everything that opens a PDF. A green `swift test` proves the Swift API
# works; it proves nothing at all about the two things that can actually hurt this project,
# so both are gates here rather than prose in VENDORED.md:
#
#   1. **Licence.** qpdf's CMake prefers GnuTLS (LGPL-2.1-or-later) whenever it is installed
#      on the build machine. There is no CMake here, but "we chose the native provider" is an
#      assertion until something checks the binary. This script checks the binary: no GnuTLS,
#      no OpenSSL and no libjpeg symbol may appear in any object file, and no unexpected
#      dynamic library may appear in the linked test binary.
#   2. **Provenance.** Apache-2.0 section 4(d) makes redistributing qpdf's NOTICE mandatory,
#      so NOTICE-qpdf.md must be present and byte-identical to the hash recorded in
#      `Docs/Execution/RESEARCH_REPOSITORIES.lock.json`. And every vendored file must appear
#      in VENDORED.md section 8 with a SHA-256 that still matches: a file that is *compiled*
#      but not *listed* is a compliance hole, and a listed hash that has drifted means the
#      table no longer describes what ships.
#
# On top of that it enforces the same two properties the other build scripts do:
#
#   3. Every test that is *defined* was actually *executed*. A suite that compiles but never
#      runs has already shipped once in this repository.
#   4. No skips. A skipped test is a failed test (`QUALITY_BAR.md` section 5).
#   5. No network, no subprocesses and no dynamic loading from the Swift target or the shim.
#      A PDF is hostile data and this package is the first thing that parses it.
#
# Exits non-zero on the first failure, naming the phase.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Who holds the tree -----------------------------------------------------------------------
#
# Two builds sharing one working tree and one `.build` interfere with each other, and nothing
# else records that the other one is there. `wave-marker.sh check` prints a warning when another
# run's fresh marker is present, and **always exits 0**: a marker is a convention, never a lock,
# and a leftover one must not be able to redden or wedge a gate. Stale markers expire.
if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Bridges
fi

readonly PACKAGE="Bridges/QPDFBridge"
readonly LOCK="${ROOT}/Docs/Execution/RESEARCH_REPOSITORIES.lock.json"

# The Swift target and the hand-written shim are held to the project's rules. The vendored
# upstream tree is not scanned for these: it is third-party C++ and is governed by the
# provenance gate below instead.
readonly FORBIDDEN='URLSession|NSURLConnection|CFURLRequest|NWConnection|CFSocket|getaddrinfo|Process\(|posix_spawn|execve?\(|NSTask|NSAppleScript|dlopen|dlsym|import AppKit|import SwiftUI|fatalError\(|@unchecked Sendable|try!|as!'

# Symbols that must not exist anywhere in the compiled qpdf objects. GnuTLS and OpenSSL are
# the licence hazard; the jpeg symbols would mean Pl_DCT.cc came back in through a refresh.
readonly BANNED_SYMBOLS='gnutls|_EVP_|_SSL_|_BIO_|openssl|jpeg_|jinit_'

# Everything the linked test binary is allowed to pull in. zlib is the one real external
# library (SDK, zlib licence, needed by Pl_Flate.cc); the frameworks below are used by the
# Swift test target, not by qpdf.
#
# `libsqlite3` joined the list on 2026-08-24 and is **not** a qpdf dependency: it arrives
# through `ZPDFTestingSupport`, whose `HostileProjectPackage` fixture opens a real SQLite
# database with the SDK's C API to build corrupt-project corpora. It is the platform's own
# dylib, carries no licence hazard, and `nm -u` above still proves no qpdf object imports
# it. If a future refresh makes *qpdf* want SQLite, the symbol gate is what will say so.
readonly ALLOWED_DYLIBS='^/usr/lib/(libc\+\+\.1|libz\.1|libSystem\.B|libobjc\.A|libsqlite3)\.dylib|^/usr/lib/swift/|^/System/Library/Frameworks/(CoreFoundation|CoreGraphics|CryptoKit|Foundation|ImageIO|PDFKit)\.framework/|Testing\.framework|XCTest\.framework|libXCTestSwiftSupport\.dylib'

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "${PACKAGE}" "$1"
    printf '=======================================================================\n'
    exit 1
}

started_at=$(date +%s)

dir="${ROOT}/${PACKAGE}"
[ -f "${dir}/Package.swift" ] || fail "layout (no Package.swift)"
cd "${dir}" || fail "cd"

# --------------------------------------------------------------------------- 1. forbidden API
printf '\n=== %s : forbidden-API scan ===\n' "${PACKAGE}"
if grep -rnE "${FORBIDDEN}" Sources/ZPDFQPDF/ Sources/CQPDF/src/ Sources/CQPDF/include/ 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(//|///|\*|/\*)'; then
    fail "forbidden API or construct in the Swift target or the shim (see the matches above)"
fi
printf 'no network, subprocess, dynamic loading, AppKit, SwiftUI, fatalError, force try/cast or unchecked Sendable.\n'

# --------------------------------------------------------------------------- 2. skips
printf '\n=== %s : skip scan ===\n' "${PACKAGE}"
if grep -rnE 'XCTSkip|\.disabled\(|#if false' Tests/ 2>/dev/null; then
    fail "a skipped test is a failed test (QUALITY_BAR section 5)"
fi
printf 'no skipped, disabled or compiled-out tests.\n'

# --------------------------------------------------------------------------- 3. licence files
printf '\n=== %s : licence and NOTICE ===\n' "${PACKAGE}"
for file in NOTICE-qpdf.md LICENSE-qpdf.txt LICENSE-qpdf-Artistic-2.0.txt VENDORED.md; do
    [ -s "${file}" ] || fail "licence gate: ${file} is missing or empty"
done
[ -f "${LOCK}" ] || fail "licence gate: ${LOCK} is missing"

notice_actual="$(shasum -a 256 NOTICE-qpdf.md | awk '{print $1}')"
notice_expected="$(/usr/bin/python3 - "${LOCK}" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1]))
for repo in doc.get("repositories", []):
    if repo.get("name") == "qpdf":
        match = re.search(r"sha256 ([0-9a-f]{64})", repo.get("notes", ""))
        print(match.group(1) if match else "")
        break
PY
)"
[ -n "${notice_expected}" ] || fail "licence gate: the lock file records no NOTICE hash for qpdf"
[ "${notice_actual}" = "${notice_expected}" ] \
    || fail "licence gate: NOTICE-qpdf.md is ${notice_actual}, the lock file says ${notice_expected}"
printf 'NOTICE-qpdf.md matches the lock file byte for byte (%s...).\n' "${notice_expected:0:16}"

# --------------------------------------------------------------------------- 4. provenance
# Every file on disk must be listed in VENDORED.md section 8, every listed file must exist,
# and every recorded SHA-256 prefix must still match. Unlisted-but-present is the compliance
# hole this gate exists to catch.
printf '\n=== %s : VENDORED.md provenance ===\n' "${PACKAGE}"
vendored_count="$(sed -n 's/^Total vendored files: \([0-9]*\)$/\1/p' VENDORED.md | tail -1)"
[ -n "${vendored_count}" ] || fail "provenance gate: VENDORED.md states no file total"
/usr/bin/python3 - <<'PY' || fail "provenance gate (see the report above)"
import hashlib, os, re, sys

ROOT = "Sources/CQPDF"
SECTIONS = {
    "#### Public headers": "upstream/include/qpdf",
    "#### Private headers": "upstream/libqpdf/qpdf",
    "#### sphlib":          "upstream/sphinclude/sph",
    "#### Sources":         "upstream/libqpdf",
}
text = open("VENDORED.md").read()
end = text.find("### The one modified upstream file")
if end < 0:
    print("  VENDORED.md has no section 8 terminator"); sys.exit(1)
marks = sorted((text.find(k), k) for k in SECTIONS)
if marks[0][0] < 0:
    print("  VENDORED.md is missing a section-8 subheading"); sys.exit(1)

problems, checked = [], 0
for i, (start, key) in enumerate(marks):
    stop = marks[i + 1][0] if i + 1 < len(marks) else end
    rel = SECTIONS[key]
    listed = dict(re.findall(r"^\| `([^`]+)` \| `([0-9a-f]{16})` \|", text[start:stop], re.M))
    here = os.path.join(ROOT, rel)
    on_disk = {f for f in os.listdir(here) if os.path.isfile(os.path.join(here, f))}
    for name in sorted(on_disk - set(listed)):
        problems.append(f"COMPILED BUT NOT LISTED: {rel}/{name}")
    for name in sorted(set(listed) - on_disk):
        problems.append(f"LISTED BUT ABSENT:      {rel}/{name}")
    for name in sorted(set(listed) & on_disk):
        digest = hashlib.sha256(open(os.path.join(here, name), "rb").read()).hexdigest()[:16]
        checked += 1
        if digest != listed[name]:
            problems.append(f"HASH DRIFT:             {rel}/{name} is {digest}, table says {listed[name]}")

total = int(re.search(r"Total vendored files: (\d+)", text).group(1))
if checked != total:
    problems.append(f"COUNT: verified {checked} files, VENDORED.md claims {total}")

for line in problems:
    print("  " + line)
print(f"  {checked} vendored files listed, present and hash-matched.")
sys.exit(1 if problems else 0)
PY

# --------------------------------------------------------------------------- 5. build
printf '\n=== %s : swift build (debug) ===\n' "${PACKAGE}"
swift build || fail "swift build"

# Compiling the test targets is a separate step, and not for speed. `swift test` writes
# SwiftPM's compile progress on one stream while swift-testing writes its results on another;
# merging two live writers into one pipe interleaves them mid-line and the accounting below
# miscounts.
printf '\n=== %s : swift build --build-tests (debug) ===\n' "${PACKAGE}"
swift build --build-tests || fail "swift build --build-tests"

# --------------------------------------------------------------------------- 6. compiled set
# Every vendored translation unit must have produced an object, and no object may exist that
# has no vendored source. This is the other half of the provenance gate: VENDORED.md lists
# what is on disk, and this proves the build compiled exactly that.
printf '\n=== %s : compiled-set gate ===\n' "${PACKAGE}"
# Scoped to the debug bin path on purpose. `find .build` also walks the release tree, which
# holds a second object for every translation unit once `swift build -c release` has run
# here, and the one-to-one count below would then be a one-to-two.
debug_bin="$(swift build --show-bin-path 2>/dev/null)"
# Two build-system layouts. The native build system puts one object per translation unit
# under `<bin>/CQPDF.build/**`. Swift Build (the default since Xcode 26) puts the bin path at
# `.build/out/Products/Debug` and the per-TU objects under
# `.build/out/Intermediates.noindex/<pkg>.build/Debug/CQPDF-t.build/Objects-normal/<arch>`;
# the single `Products/Debug/CQPDF.o` there is the merged target object and is NOT counted.
if [ -d "${debug_bin}/CQPDF.build" ]; then
    cqpdf_objects="${debug_bin}/CQPDF.build"
else
    cqpdf_objects="$(find "${debug_bin}/../../Intermediates.noindex" -type d -path '*/Debug/CQPDF*.build/Objects-normal' 2>/dev/null | head -1)"
fi
[ -n "${cqpdf_objects}" ] && [ -d "${cqpdf_objects}" ] \
    || fail "compiled-set gate: no CQPDF object directory under ${debug_bin}"
objects="$(find "${cqpdf_objects}" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')"
sources="$(ls Sources/CQPDF/upstream/libqpdf/*.cc Sources/CQPDF/upstream/libqpdf/*.c \
             Sources/CQPDF/src/*.cc 2>/dev/null | wc -l | tr -d ' ')"
[ "${objects}" -gt 0 ] || fail "compiled-set gate: no CQPDF object files found"
[ "${objects}" -eq "${sources}" ] \
    || fail "compiled-set gate: ${sources} vendored translation units, ${objects} object files"
printf '%s translation units, %s object files, one to one.\n' "${sources}" "${objects}"

# --------------------------------------------------------------------------- 7. symbol gate
printf '\n=== %s : symbol gate (no GnuTLS, no OpenSSL, no libjpeg) ===\n' "${PACKAGE}"
# -print0/-0 is load-bearing: the repository path contains spaces, and a plain `xargs` splits
# on them, hands nm a nonexistent file for every object, and reports zero symbols and zero
# hits — a gate that passes because it scanned nothing. The floor below makes that
# unrepresentable: this target really does emit tens of thousands of symbols.
symlist="$(mktemp)" || fail "mktemp"
find "${cqpdf_objects}" -name '*.o' -print0 | xargs -0 -n1 nm -o 2>/dev/null > "${symlist}"
symbol_total="$(wc -l < "${symlist}" | tr -d ' ')"
symbol_hits="$(grep -icE "${BANNED_SYMBOLS}" "${symlist}")"
rm -f "${symlist}"
[ "${symbol_total}" -gt 10000 ] \
    || fail "symbol gate: only ${symbol_total} symbols read from ${objects} objects — the scan did not run"
[ "${symbol_hits}" -eq 0 ] \
    || fail "symbol gate: ${symbol_hits} GnuTLS/OpenSSL/libjpeg symbols in the qpdf objects"
printf '%s symbols across %s objects, %s matching /%s/.\n' \
    "${symbol_total}" "${objects}" "${symbol_hits}" "${BANNED_SYMBOLS}"

# --------------------------------------------------------------------------- 8. linkage gate
printf '\n=== %s : linkage gate ===\n' "${PACKAGE}"
binary="${debug_bin}/QPDFBridgePackageTests.xctest/Contents/MacOS/QPDFBridgePackageTests"
[ -f "${binary}" ] || binary="$(find "${debug_bin}" -type f -name 'QPDFBridgePackageTests' 2>/dev/null | head -1)"
# Swift Build names the bundle after the test target rather than the package.
[ -n "${binary}" ] || binary="$(find "${debug_bin}" -type f -path '*Tests.xctest/Contents/MacOS/*' 2>/dev/null | head -1)"
[ -n "${binary}" ] || fail "linkage gate: the test binary was not found"

if nm -u "${binary}" 2>/dev/null | grep -qiE "${BANNED_SYMBOLS}"; then
    nm -u "${binary}" | grep -iE "${BANNED_SYMBOLS}"
    fail "linkage gate: the test binary imports a GnuTLS/OpenSSL/libjpeg symbol"
fi

unexpected="$(otool -L "${binary}" | tail -n +2 | awk '{print $1}' | grep -vE "${ALLOWED_DYLIBS}")"
if [ -n "${unexpected}" ]; then
    printf 'unexpected dynamic dependencies:\n%s\n' "${unexpected}"
    fail "linkage gate: the test binary links something that is not on the allowlist"
fi
printf 'otool -L: %s dynamic dependencies, all on the allowlist, none of them GnuTLS or OpenSSL.\n' \
    "$(otool -L "${binary}" | tail -n +2 | wc -l | tr -d ' ')"

# --------------------------------------------------------------------------- 9. test
printf '\n=== %s : swift test (debug) ===\n' "${PACKAGE}"
log="$(mktemp)" || fail "mktemp"
xml_dir="$(mktemp -d)" || fail "mktemp -d"
swift test --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${log}"
status="${PIPESTATUS[0]}"
[ "${status}" -eq 0 ] || { rm -f "${log}"; rm -rf "${xml_dir}"; fail "swift test (exit ${status})"; }

declared="$(grep -rEc '^[[:space:]]*@Test' Tests/ 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"

# Counts come from the xUnit XML the runner writes, not from the console stream. The console
# log is still tee'd for humans and still greps the named markers below.
counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
    || { rm -f "${log}"; rm -rf "${xml_dir}"; fail "xunit accounting (see above)"; }
rm -rf "${xml_dir}"
executed="$(printf '%s' "${counts}" | awk '{print $1}')"
xml_failed="$(printf '%s' "${counts}" | awk '{print $2}')"
xml_skipped="$(printf '%s' "${counts}" | awk '{print $3}')"

# The gates above check the binary. These check that the *runtime* assertions of the same
# facts really ran, so a deleted test cannot quietly widen the licence surface.
for marker in \
    'the crypto provider is native, never GnuTLS or OpenSSL' \
    'the build has no DCT (JPEG) filter' \
    'every operation leaves the input'"'"'s bytes and timestamps untouched' \
    'mutated inputs produce typed errors, never a crash, hang or runaway allocation'
do
    if ! grep -qF "${marker}" "${log}"; then
        rm -f "${log}"
        fail "the test named '${marker}' did not run"
    fi
done
rm -f "${log}"

printf '\n--- ZPDFQPDF : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
    "${declared}" "${executed}" "${xml_failed}" "${xml_skipped}"
[ "${xml_failed}" -eq 0 ] || fail "test accounting: the xUnit XML records ${xml_failed} failures"
[ "${xml_skipped}" -eq 0 ] || fail "test accounting: the xUnit XML records ${xml_skipped} skipped tests"
[ "${declared}" -eq "${executed}" ] || fail "test accounting: ${declared} declared but ${executed} executed"
[ "${executed}" -gt 0 ] || fail "test accounting: the suite is empty"

# --------------------------------------------------------------------- 9b. out-of-process fuzz
# The in-process `FuzzTests` suite measures elapsed time and resident growth
# after each call returns, so an input that never returns wedges the runner instead of failing
# it. The same 400-iteration sweep runs again here as a child process of
# Scripts/fuzz-harness.sh, which SIGKILLs the whole tree on a wall-clock or RSS breach. A PDF
# is hostile data; the first parser to touch it gets a watchdog that needs no cooperation.
printf '\n=== %s : fuzz sweep under the out-of-process watchdog ===\n' "${PACKAGE}"
"${ROOT}/Scripts/fuzz-harness.sh" "${dir}" "FuzzTests" 900 2048 \
    || fail "fuzz-harness (FuzzTests)"

# --------------------------------------------------------------------------- 10. release
printf '\n=== %s : swift build (release) ===\n' "${PACKAGE}"
swift build -c release || fail "swift build -c release"

printf '\n=== %s : swift test (release) ===\n' "${PACKAGE}"
swift test -c release || fail "swift test -c release"

printf '\n=======================================================================\n'
printf 'QPDFBridge built and tested in debug and release. %s tests declared and executed.\n' "${executed}"
printf 'Licence: NOTICE verbatim, %s vendored files hash-matched, %s translation units compiled,\n' \
    "${vendored_count}" "${sources}"
printf '         %s symbols scanned, 0 GnuTLS/OpenSSL/libjpeg. (%ds)\n' \
    "${symbol_total}" "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
