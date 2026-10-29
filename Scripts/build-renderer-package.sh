#!/bin/bash
#
# build-renderer-package.sh — the verification command for the markup renderer.
#
#     Packages/ZPDFRenderer -> ZPDFContracts, ZPDFGeometry, Bridges/Clipper2Bridge
#
# Beyond build and test, it enforces what a green run does not by itself prove:
#
#   1. Every test that is *defined* was actually *executed*. A suite that compiles but never
#      runs has already shipped once in this repository.
#   2. No skips. A skipped test is a failed test (`QUALITY_BAR.md` section 5).
#   3. No network, no subprocesses, no dynamic loading and no AppKit or SwiftUI in the library
#      target. The renderer consumes geometry extracted from hostile PDFs.
#   4. The golden images really were compared, and the coverage oracle really did run: the
#      suite must report both, by name.
#   5. The benchmark numbers are printed from a **release** build, isolated, so a p99 is a
#      measurement of the renderer and not of the test runner.
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
    "${ROOT}/Scripts/wave-marker.sh" check Packages/ZPDFRenderer
fi

readonly PACKAGE="Packages/ZPDFRenderer"

readonly FORBIDDEN='URLSession|NSURLConnection|CFURLRequest|NWConnection|CFSocket|getaddrinfo|Process\(|posix_spawn|execve?\(|NSTask|NSAppleScript|dlopen|dlsym|import AppKit|import SwiftUI|fatalError\(|@unchecked Sendable|try!|as!'

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

printf '\n=== %s : forbidden-API scan ===\n' "${PACKAGE}"
if grep -rnE "${FORBIDDEN}" Sources/ZPDFRenderer/ 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(//|///)'; then
    fail "forbidden API or construct in the library target (see the matches above)"
fi
printf 'no network, subprocess, dynamic loading, AppKit, SwiftUI, fatalError, force try/cast or unchecked Sendable.\n'

printf '\n=== %s : skip scan ===\n' "${PACKAGE}"
if grep -rnE 'XCTSkip|\.disabled\(|#if false' Tests/ 2>/dev/null; then
    fail "a skipped test is a failed test (QUALITY_BAR section 5)"
fi
printf 'no skipped, disabled or compiled-out tests.\n'

printf '\n=== %s : golden inventory ===\n' "${PACKAGE}"
goldens="$(ls Tests/ZPDFRendererGoldenTests/Goldens/*.png 2>/dev/null | wc -l | tr -d ' ')"
# 24 before stamps were rendered; 31 since ADR-0011 added imported artwork — vector and
# raster at three zooms each, plus count marks drawn from imported artwork.
[ "${goldens}" -eq 31 ] || fail "expected 31 stored goldens, found ${goldens}"
printf '%s stored golden PNGs.\n' "${goldens}"

printf '\n=== %s : swift build (debug) ===\n' "${PACKAGE}"
swift build || fail "swift build"

# Compiling the test targets is a separate step, and not for speed. `swift test` writes SwiftPM's
# compile progress to stdout while swift-testing writes its results to stderr; merging two live
# writers into one pipe interleaves them mid-line and the accounting below miscounts.
printf '\n=== %s : swift build --build-tests (debug) ===\n' "${PACKAGE}"
swift build --build-tests || fail "swift build --build-tests"

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

for marker in \
    'The Metal renderer reproduces every stored golden' \
    'The two backends agree with each other on every scene' \
    'Every stroke-and-fill scene agrees with the independent coverage oracle' \
    'No Metal device falls back to Core Graphics with a reason'
do
    if ! grep -qF "${marker}" "${log}"; then
        rm -f "${log}"
        fail "the test named '${marker}' did not run"
    fi
done
rm -f "${log}"

printf '\n--- ZPDFRenderer : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
    "${declared}" "${executed}" "${xml_failed}" "${xml_skipped}"
[ "${xml_failed}" -eq 0 ] || fail "test accounting: the xUnit XML records ${xml_failed} failures"
[ "${xml_skipped}" -eq 0 ] || fail "test accounting: the xUnit XML records ${xml_skipped} skipped tests"
[ "${declared}" -eq "${executed}" ] || fail "test accounting: ${declared} declared but ${executed} executed"
[ "${executed}" -gt 0 ] || fail "test accounting: the suite is empty"

printf '\n=== %s : swift build (release) ===\n' "${PACKAGE}"
swift build -c release || fail "swift build -c release"

printf '\n=== %s : swift test (release) ===\n' "${PACKAGE}"
swift test -c release || fail "swift test -c release"

# The benchmark numbers that count. Run alone so no other suite competes for a core.
#
# The 16.6 ms `#expect`s inside the suite are guarded by `if isReleaseBuild`. Both of them are now
# assertions: the CPU frame always was, and **GPU execution at 100 000 markups became one on
# 2026-08-26**, when splitting the render pass took the worst cell from 72 ms to 7.3 ms. For as
# long as the renderer missed that budget the GPU figure was deliberately *reported and not
# asserted* — lowering a bar to make a suite green is the wrong repair — and the printed verdict
# was the only record of the shortfall. It is still required to be printed, for two reasons that
# outlast the shortfall: a refactor that drops the block, or a debug binary sneaking into this
# phase, fails the script rather than quietly deleting the news; and if a future corpus misses
# again, the block is where it will say so.
printf '\n=== %s : benchmark-viewer (release, isolated) ===\n' "${PACKAGE}"
bench="$(mktemp)" || fail "mktemp"
swift test -c release --filter ZPDFRendererPerformanceTests 2>&1 | tee "${bench}"
status="${PIPESTATUS[0]}"
[ "${status}" -eq 0 ] || { rm -f "${bench}"; fail "benchmark-viewer (exit ${status})"; }

grep -qF 'build: release' "${bench}" \
    || { rm -f "${bench}"; fail "benchmark-viewer: the suite reported a debug build, so no budget was asserted"; }
grep -qF -- '--- 60 fps at 100 000 markups, stated plainly ---' "${bench}" \
    || { rm -f "${bench}"; fail "benchmark-viewer: the 60 fps verdict block was not printed"; }
grep -qE '^(CPU, frame build \+ encode:|GPU, execution:)' "${bench}" \
    || { rm -f "${bench}"; fail "benchmark-viewer: neither the CPU nor the GPU verdict line was printed"; }
printf '\n--- 60 fps verdict as measured in this run ---\n'
grep -E '^(CPU, frame build \+ encode:|GPU, execution:)' "${bench}"
rm -f "${bench}"

printf '\n=======================================================================\n'
printf 'ZPDFRenderer built and tested in debug and release. %s tests declared and executed. (%ds)\n' \
    "${executed}" "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
