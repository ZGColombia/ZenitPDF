#!/bin/bash
#
# verify-snap-search-compare.sh — one gate over three packages held to the same strict
# rules: the snap engine (critical area C2), unified search, and Revision Compare.
#
#     Packages/ZPDFSnapEngine  -> ZPDFContracts, ZPDFGeometry, ZPDFVectorExtraction
#     Packages/ZPDFSearch      -> ZPDFPersistence, ZPDFPDFKitBridge, Vision
#     Packages/ZPDFCompare     -> ZPDFPDFKitBridge, ZPDFVectorExtraction, Vision
#
# Why a fourth script rather than another entry in `build-io-packages.sh`: the three are held
# to the *same* gates, and those gates are stricter than the IO script's. `build-io-packages.sh`
# forbids network, subprocess and dynamic loading; this one adds the four rules that a snap
# defect and a compare defect fail in the same way — no `fatalError`, no `@unchecked Sendable`,
# no `try!`/`as!`, and no AppKit or SwiftUI in a headless engine. All three pass the strict set
# today, so there is no reason to hold any of them to less. `ZPDFSearch` and `ZPDFCompare`
# remain in `build-io-packages.sh` as well; running both scripts is not wasted work, because
# that one checks them in the dependency order their *builds* need and this one checks them
# against the bar their *content* needs.
#
# Gates, applied identically to all three:
#
#   1. Forbidden-API scan over `Sources/` only. A library target may not reach a network, spawn
#      a subprocess, load a dylib, trap, or import a UI framework. Test targets may: the snap
#      determinism suite has to spawn its decision-log executable twenty times, and the search
#      network-absence suite has to run `nm`.
#   2. No skips. A skipped test is a failed test (`QUALITY_BAR.md` section 5).
#   3. Declared equals executed. The count of `@Test` declarations is compared against the
#      count swift-testing reports as passed. A suite that compiles but never runs has already
#      shipped once in this repository.
#   4. Per-package proof obligations that a green run does not by itself establish:
#      snap's 20-process determinism run really ran with `SWIFT_DETERMINISTIC_HASHING` unset;
#      search's fuzz audit really executed its 500 hostile queries and its symbol scan found
#      no networking symbol in the compiled library; compare's self-comparison audit really
#      ran at its fractional render scales.
#   5. Snap additionally builds and tests in **release**, and prints the S12/S13 benchmark from
#      the optimised build, because `QUALITY_BAR.md` 3.5's budgets are budgets on optimised
#      code. That half is `Scripts/build-snap-package.sh`, called, with its accounting and its
#      SNAP-BENCH verdict (T-086). Debug figures are printed too but are not the headline.
#
# Exits non-zero on the first failure, naming the package and the phase: 1 for a failure, 75 when
# the snap release benchmark could not be attributed to the engine (not green; re-run).

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
    "${ROOT}/Scripts/wave-marker.sh" check Packages
fi


readonly PACKAGES=(
    "Packages/ZPDFSnapEngine"
    "Packages/ZPDFSearch"
    "Packages/ZPDFCompare"
)

# The union of the IO script's list and the snap script's list. `Process(` and friends are
# scanned in `Sources/` only, which is what lets a test target spawn one.
readonly FORBIDDEN='URLSession|NSURLConnection|CFURLRequest|NWConnection|CFSocket|getaddrinfo|Process\(|posix_spawn|execve?\(|NSTask|NSAppleScript|dlopen|dlsym|PDFView|JSContext|WKWebView|import AppKit|import SwiftUI|fatalError\(|@unchecked Sendable|try!|as!'

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "$1" "$2"
    printf '=======================================================================\n'
    exit 1
}

# A line of `swift test` output that must be present. Proves a specific test actually executed,
# not merely that the run was green — a renamed or deleted test is otherwise invisible here.
require_line() {
    local log="$1" package="$2" needle="$3" what="$4"
    if ! grep -qF "${needle}" "${log}"; then
        rm -f "${log}"
        fail "${package}" "${what} (no line matching '${needle}' in the test output)"
    fi
}

if [ -n "${SWIFT_DETERMINISTIC_HASHING:-}" ]; then
    printf 'SWIFT_DETERMINISTIC_HASHING is set. QUALITY_BAR 3.4 rule 4 forbids running the\n'
    printf 'snap determinism suite with it on: it would pass without proving anything. Unset it.\n'
    exit 1
fi

started_at=$(date +%s)
total_tests=0

for package in "${PACKAGES[@]}"; do
    dir="${ROOT}/${package}"
    name="$(basename "${package}")"
    [ -f "${dir}/Package.swift" ] || fail "${package}" "layout (no Package.swift)"
    cd "${dir}" || fail "${package}" "cd"

    printf '\n=== %s : forbidden-API scan ===\n' "${package}"
    if grep -rnE "${FORBIDDEN}" Sources/ 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(//|///)'; then
        fail "${package}" "forbidden API or construct in a library target (see the matches above)"
    fi
    printf 'no network, subprocess, dynamic loading, AppKit, SwiftUI, fatalError, force cast or unchecked Sendable.\n'

    printf '\n=== %s : skip scan ===\n' "${package}"
    if grep -rnE 'XCTSkip|\.disabled\(|#if false' Tests/ 2>/dev/null | grep -v 'backgroundFilter'; then
        fail "${package}" "a skipped test is a failed test (QUALITY_BAR section 5)"
    fi
    printf 'no skipped, disabled or compiled-out tests.\n'

    # `--build-tests` matters, and not for speed. `swift test` writes SwiftPM's compile
    # progress to stdout while swift-testing writes its results to stderr; merging two live
    # writers into one pipe with `2>&1 |` interleaves them mid-line, and a result line with a
    # build line glued to its front no longer starts with the marker the accounting below
    # counts. That was observed here: a run of 69 tests was counted as 18. Compiling the test
    # targets in a separate step leaves nothing writing to stdout during the measured run.
    printf '\n=== %s : swift build --build-tests ===\n' "${package}"
    swift build --build-tests || fail "${package}" "swift build --build-tests"

    printf '\n=== %s : swift test ===\n' "${package}"
    log="$(mktemp)" || fail "${package}" "mktemp"
    xml_dir="$(mktemp -d)" || fail "${package}" "mktemp -d"
    swift test --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${log}"
    status="${PIPESTATUS[0]}"
    [ "${status}" -eq 0 ] || { rm -f "${log}"; rm -rf "${xml_dir}"; fail "${package}" "swift test (exit ${status})"; }

    # Per-package proof obligations.
    case "${name}" in
        ZPDFSnapEngine)
            require_line "${log}" "${package}" \
                "Twenty freshly spawned processes produce byte-identical logs" \
                "the 20-process determinism test did not run (QUALITY_BAR 3.4 rule 4)"
            require_line "${log}" "${package}" \
                "Query latency at the minimum supported zoom still meets S12" \
                "the minimum-zoom S12 case did not run"
            ;;
        ZPDFSearch)
            require_line "${log}" "${package}" \
                "500 hostile queries executed" \
                "the 500-string query fuzz audit did not run"
            require_line "${log}" "${package}" \
                "symbol scan:" \
                "the compiled-symbol network scan did not run"
            ;;
        ZPDFCompare)
            require_line "${log}" "${package}" \
                "A page compared with itself is exactly zero at eight scales" \
                "the multi-scale self-comparison audit did not run"
            require_line "${log}" "${package}" \
                "A whole antialiasing fringe shifted by a gray level or two is not a change" \
                "the antialiasing-tolerance audit did not run"
            ;;
    esac

    declared="$(grep -rEc '^[[:space:]]*@Test' Tests/ 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"

    # Counts come from the xUnit XML the runner itself writes (a console parse rests on the
    # toolchain writing results to stdout). Scripts/xunit-summary.sh
    # cross-checks the summary attributes against the counted <testcase> elements — the same
    # two-independent-counts rule that used to catch a truncated log — and refuses a missing,
    # inconsistent or empty document, so a gate that parsed zero tests still fails.
    rm -f "${log}"
    counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
        || { rm -rf "${xml_dir}"; fail "${package}" "xunit accounting (see above)"; }
    rm -rf "${xml_dir}"
    executed="$(printf '%s' "${counts}" | awk '{print $1}')"
    xml_failed="$(printf '%s' "${counts}" | awk '{print $2}')"
    xml_skipped="$(printf '%s' "${counts}" | awk '{print $3}')"

    printf '\n--- %s : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
        "${name}" "${declared}" "${executed}" "${xml_failed}" "${xml_skipped}"
    if [ "${xml_failed}" -ne 0 ]; then
        fail "${package}" "test accounting: the xUnit XML records ${xml_failed} failures"
    fi
    if [ "${xml_skipped}" -ne 0 ]; then
        fail "${package}" "test accounting: the xUnit XML records ${xml_skipped} skipped tests"
    fi
    if [ "${declared}" -ne "${executed}" ]; then
        fail "${package}" "test accounting: ${declared} declared but ${executed} executed"
    fi
    if [ "${executed}" -eq 0 ]; then
        fail "${package}" "test accounting: the suite is empty"
    fi
    total_tests=$(( total_tests + executed ))
done

# Snap is the critical area, and its budgets are release budgets. The release run, its accounting
# and its verdict are Scripts/build-snap-package.sh's, called here rather than copied (T-086):
# this script used to run `swift test -c release` with no accounting — a filter that matched
# nothing exited 0 (R-204) — and never looked for a SNAP-BENCH line, so an inconclusive benchmark,
# or none at all, ended green here while the snap gate itself would have refused it. The snap gate
# runs the benchmark alone in both configurations, accounts the release run declared == executed,
# fails on a missing SNAP-BENCH line and exits 75 when the machine was too busy to attribute a
# wall-clock percentile. Its exit code is this script's: 0, 1, or 75.
printf '\n=== Packages/ZPDFSnapEngine : Scripts/build-snap-package.sh (release accounting and SNAP-BENCH verdict) ===\n'
"${ROOT}/Scripts/build-snap-package.sh"
snap_status=$?
case "${snap_status}" in
    0) ;;
    75)
        printf '\n=======================================================================\n'
        printf 'INCONCLUSIVE: Search and Compare are green and %d tests were declared and executed,\n' "${total_tests}"
        printf 'but the snap release benchmark could not be attributed (Scripts/build-snap-package.sh\n'
        printf 'exited 75). Not green: re-run on a quiet machine.\n'
        printf '=======================================================================\n'
        exit 75
        ;;
    *) fail "Packages/ZPDFSnapEngine" "Scripts/build-snap-package.sh (exit ${snap_status})" ;;
esac

printf '\n=======================================================================\n'
printf 'Snap, Search and Compare built and tested. %d tests declared and executed, and the snap\n' "${total_tests}"
printf 'release benchmark accounted with every budget attributable and met. (%ds)\n' \
    "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
