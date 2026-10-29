#!/bin/bash
#
# build-snap-package.sh — the verification command for the snap engine, critical area C2.
#
#     Packages/ZPDFSnapEngine  -> ZPDFContracts, ZPDFGeometry, ZPDFVectorExtraction
#                                 (+ ZPDFTestingSupport in the test targets only)
#
# This is the gate that Scripts/build-core-packages.sh defers to. The snap engine sits across
# the two scopes those scripts are defined by: it is headless calculation, like the core
# packages, but it consumes `ZPDFVectorExtraction`, which is document IO. Run
# Scripts/build-io-packages.sh first; this script assumes the IO layer is already green.
#
# Beyond build and test, it enforces what a green run does not by itself prove:
#
#   1. Every test that is *defined* was actually *executed*. A suite that compiles but never
#      runs has already shipped once in this repository.
#   2. No skips. A skipped test is a failed test (`QUALITY_BAR.md` section 5).
#   3. No network and no dynamic loading from the library target. A PDF is hostile data and
#      the snap engine indexes geometry extracted from one.
#   4. The 20-process determinism run of `QUALITY_BAR.md` 3.4 really ran, with
#      `SWIFT_DETERMINISTIC_HASHING` unset. Forcing deterministic hashing on defeats S15 and
#      is forbidden, so this script refuses to run with it set.
#   5. The S12/S13 benchmark numbers are printed from a **release** build. Debug figures are
#      recorded too, but `QUALITY_BAR.md` 3.5's budgets are budgets on optimised code.
#
# ---------------------------------------------------------------------------------------------
# The benchmark and the machine
# ---------------------------------------------------------------------------------------------
# This gate was measured four times on 2026-08-25: three red, one green, the reds all with other
# suites or another workflow on the cores. Its own comment already said why — *"a p95 measured
# while eight other test suites run in parallel is a measurement of the test runner"* — but the
# isolation that comment describes was applied to the release benchmark only, while the debug
# `swift test` ran the performance suite in parallel with the determinism suite, which spends
# 47 s across every core, **and asserted**.
#
# Two changes, and neither of them is a raised number:
#
#   a. The performance suite is now run **alone in both configurations**. `swift test --skip
#      ZPDFSnapPerformanceTests` runs everything else; a second invocation runs the benchmark by
#      itself. Test accounting sums the two xUnit documents, so `declared == executed` still holds
#      across the split and a suite that vanished from one half is still caught.
#
#   b. The suite decides for itself whether its wall-clock figures mean anything, and says so.
#      Thread CPU time carries every assertion; a wall-clock percentile is asserted only when the
#      run proves it was not descheduled and not throttled. Where it cannot, the suite prints
#      `SNAP-BENCH inconclusive` instead of failing. See the long note in
#      `Tests/ZPDFSnapPerformanceTests/SnapPerformanceTests.swift`.
#
# This script turns (b) into a verdict of its own. An inconclusive benchmark is **not** green: it
# exits **75** (`EX_TEMPFAIL`, "try again"), separate from the 1 that means the snap engine missed
# a budget. The distinction is the whole point — 15.12 spent four gate runs reporting a machine
# problem as an engine problem, and the number it protects is a dropped frame the user sees, so
# it may not be relaxed to make the report quieter.
#
# Exits: 0 green · 1 a real failure, named by phase · 75 the benchmark could not be attributed.

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
    "${ROOT}/Scripts/wave-marker.sh" check Packages/ZPDFSnapEngine
fi

readonly PACKAGE="Packages/ZPDFSnapEngine"
readonly PERF_TARGET="ZPDFSnapPerformanceTests"

# `Process(` is deliberately absent from this list: the determinism test target must spawn the
# decision-log executable twenty times, which is the whole point of S15. The scan is restricted
# to Sources/ for exactly that reason — a library target may not do it, a test target must.
readonly FORBIDDEN='URLSession|NSURLConnection|CFURLRequest|NWConnection|CFSocket|getaddrinfo|Process\(|posix_spawn|execve?\(|NSTask|NSAppleScript|dlopen|dlsym|import AppKit|import SwiftUI|fatalError\(|@unchecked Sendable'

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "${PACKAGE}" "$1"
    printf '=======================================================================\n'
    exit 1
}

started_at=$(date +%s)

if [ -n "${SWIFT_DETERMINISTIC_HASHING:-}" ]; then
    printf 'SWIFT_DETERMINISTIC_HASHING is set. QUALITY_BAR 3.4 rule 4 forbids running the\n'
    printf 'determinism suite with it on: it would pass without proving anything. Unset it.\n'
    exit 1
fi

dir="${ROOT}/${PACKAGE}"
[ -f "${dir}/Package.swift" ] || fail "layout (no Package.swift)"
cd "${dir}" || fail "cd"

printf '\n=== %s : forbidden-API scan ===\n' "${PACKAGE}"
if grep -rnE "${FORBIDDEN}" Sources/ 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(//|///)'; then
    fail "forbidden API or construct in a library target (see the matches above)"
fi
printf 'no network, subprocess, dynamic loading, AppKit, SwiftUI, fatalError or unchecked Sendable.\n'

printf '\n=== %s : skip scan ===\n' "${PACKAGE}"
if grep -rnE 'XCTSkip|\.disabled\(|#if false' Tests/ 2>/dev/null; then
    fail "a skipped test is a failed test (QUALITY_BAR section 5)"
fi
printf 'no skipped, disabled or compiled-out tests.\n'

printf '\n=== %s : swift build (debug) ===\n' "${PACKAGE}"
swift build || fail "swift build"

# The build of the test targets is a separate step, and not for speed. `swift test`
# writes SwiftPM's compile progress to stdout while swift-testing writes its results to
# stderr; merging two live writers into one pipe with `2>&1 |` interleaves them mid-line,
# and a result line with a build line glued to its front no longer begins with the marker
# the accounting counts. That was observed in this repository: a run of 69 tests counted
# as 18. Compiling first leaves nothing else writing to stdout during the measured run.
printf '\n=== %s : swift build --build-tests (debug) ===\n' "${PACKAGE}"
swift build --build-tests || fail "swift build --build-tests"

printf '\n=== %s : swift test (debug, everything except the benchmark) ===\n' "${PACKAGE}"
log="$(mktemp)" || fail "mktemp"
perf_debug_log="$(mktemp)" || fail "mktemp"
xml_dir="$(mktemp -d)" || fail "mktemp -d"
cleanup_temps() { rm -f "${log}" "${perf_debug_log}" "${perf_release_log:-}"; rm -rf "${xml_dir}" "${perf_release_xml:-}"; }
trap cleanup_temps EXIT

swift test --skip "${PERF_TARGET}" --xunit-output "${xml_dir}/main.xml" 2>&1 | tee "${log}"
status="${PIPESTATUS[0]}"
[ "${status}" -eq 0 ] || fail "swift test --skip ${PERF_TARGET} (exit ${status})"

# The benchmark, alone. Not for tidiness: the determinism suite it used to run beside spends 47 s
# across every core, and a latency percentile measured next to that is a measurement of the
# scheduler.
printf '\n=== %s : swift test (debug, benchmark isolated) ===\n' "${PACKAGE}"
swift test --filter "${PERF_TARGET}" --xunit-output "${xml_dir}/perf.xml" 2>&1 | tee "${perf_debug_log}"
status="${PIPESTATUS[0]}"
[ "${status}" -eq 0 ] || fail "swift test --filter ${PERF_TARGET} (debug) (exit ${status})"

declared="$(grep -rEc '^[[:space:]]*@Test' Tests/ 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"

# Counts come from the xUnit XML the runner writes, not from the console stream (a console
# parse rests on the toolchain writing results to stdout). The helper
# refuses a missing, inconsistent or empty document, so a gate that parsed zero tests fails.
# Two documents now, because the run is split; they are summed, so `declared == executed` still
# has to hold over the whole suite and a half that silently stopped running is still caught.
executed=0
xml_failed=0
xml_skipped=0
for half in main perf; do
    counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/${half}-swift-testing.xml")" \
        || fail "xunit accounting for the ${half} half (see above)"
    executed=$((  executed  + $(printf '%s' "${counts}" | awk '{print $1}') ))
    xml_failed=$((  xml_failed  + $(printf '%s' "${counts}" | awk '{print $2}') ))
    xml_skipped=$(( xml_skipped + $(printf '%s' "${counts}" | awk '{print $3}') ))
done

# S15's out-of-process run must actually have happened, not merely have been declared.
if ! grep -q 'Twenty freshly spawned processes produce byte-identical logs' "${log}"; then
    fail "the 20-process determinism test did not run (QUALITY_BAR 3.4 rule 4)"
fi

printf '\n--- ZPDFSnapEngine : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
    "${declared}" "${executed}" "${xml_failed}" "${xml_skipped}"
if [ "${xml_failed}" -ne 0 ]; then
    fail "test accounting: the xUnit XML records ${xml_failed} failures"
fi
if [ "${xml_skipped}" -ne 0 ]; then
    fail "test accounting: the xUnit XML records ${xml_skipped} skipped tests"
fi
if [ "${declared}" -ne "${executed}" ]; then
    fail "test accounting: ${declared} declared but ${executed} executed"
fi
if [ "${executed}" -eq 0 ]; then
    fail "test accounting: the suite is empty"
fi

printf '\n=== %s : swift build (release) ===\n' "${PACKAGE}"
swift build -c release || fail "swift build -c release"

printf '\n=== %s : swift test (release, everything except the benchmark) ===\n' "${PACKAGE}"
swift test -c release --skip "${PERF_TARGET}" || fail "swift test -c release --skip ${PERF_TARGET}"

# The benchmark numbers that count. Run alone so no other suite is competing for a core:
# a p95 measured while eight other test suites run in parallel is a measurement of the test
# runner, not of the snap engine.
printf '\n=== %s : benchmark-snap (release, isolated) ===\n' "${PACKAGE}"
perf_release_log="$(mktemp)" || fail "mktemp"
perf_release_xml="$(mktemp -d)" || fail "mktemp -d"
swift test -c release --filter "${PERF_TARGET}" --xunit-output "${perf_release_xml}/perf.xml" 2>&1 | tee "${perf_release_log}"
status="${PIPESTATUS[0]}"
[ "${status}" -eq 0 ] || fail "benchmark-snap (exit ${status})"

# Accounted like the debug half (R-196). The release run had no xUnit accounting, so a filter
# that matched nothing exited 0 and the verdict below still said every budget was met.
release_counts="$("${ROOT}/Scripts/xunit-summary.sh" "${perf_release_xml}/perf-swift-testing.xml")" \
    || fail "xunit accounting for the release benchmark (see above)"
release_executed="$(printf '%s' "${release_counts}" | awk '{print $1}')"
release_failed="$(printf '%s' "${release_counts}" | awk '{print $2}')"
release_declared="$(grep -rEc '^[[:space:]]*@Test' "Tests/${PERF_TARGET}" 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"
printf -- '--- %s release benchmark: %s declared, %s executed, %s failed (per xUnit XML) ---\n' \
    "${PACKAGE}" "${release_declared}" "${release_executed}" "${release_failed}"
[ "${release_failed}" -eq 0 ] || fail "the release benchmark records ${release_failed} failures"
[ "${release_executed}" -gt 0 ] || fail "the release benchmark ran nothing"
[ "${release_executed}" -eq "${release_declared}" ] \
    || fail "release benchmark accounting: ${release_declared} declared but ${release_executed} executed"

# ---------------------------------------------------------------------------------------------
# The attribution verdict
# ---------------------------------------------------------------------------------------------

printf '\n=== %s : benchmark attribution ===\n' "${PACKAGE}"
grep -h '^SNAP-BENCH ' "${perf_debug_log}" "${perf_release_log}" 2>/dev/null | grep -v inconclusive \
    || printf 'no SNAP-BENCH summary line was printed — the benchmark did not report\n'
# A release run that printed no SNAP-BENCH line at all — neither a verdict nor an inconclusive
# one — did not report, and a benchmark that did not report has not met a budget (R-196).
if ! grep -q 'SNAP-BENCH ' "${perf_release_log}" 2>/dev/null; then
    fail "the release benchmark printed no SNAP-BENCH line: no budget was measured"
fi

inconclusive="$(grep -hc 'SNAP-BENCH inconclusive' "${perf_debug_log}" "${perf_release_log}" 2>/dev/null \
    | awk '{ sum += $1 } END { print sum + 0 }')"
if [ "${inconclusive}" -ne 0 ]; then
    printf '\n'
    grep -h 'SNAP-BENCH inconclusive' "${perf_debug_log}" "${perf_release_log}" 2>/dev/null
    printf '\n=======================================================================\n'
    printf 'INCONCLUSIVE: %s wall-clock percentile(s) could not be attributed to the snap\n' "${inconclusive}"
    printf 'engine, because this machine was not quiet enough for the measurement to mean\n'
    printf 'anything. Every thread-CPU budget was asserted and met, and %s tests ran; what is\n' "${executed}"
    printf 'missing is the wall-clock verdict, not a passing one. Re-run on a quiet machine.\n'
    printf 'This is exit 75, not 1: the snap engine did not miss a budget.\n'
    printf '=======================================================================\n'
    exit 75
fi

printf '\n=======================================================================\n'
printf 'ZPDFSnapEngine built and tested in debug and release. %s tests declared and executed,\n' \
    "${executed}"
printf 'benchmark run alone in both configurations, every budget attributable and met. (%ds)\n' \
    "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
