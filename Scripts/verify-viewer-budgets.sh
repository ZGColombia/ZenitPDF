#!/bin/bash
#
# verify-viewer-budgets.sh — the viewer's millisecond budgets, asserted on optimised code.
#
# ## Why this gate exists
#
# `ViewerZoomGateTests` lives in the application package, and three documents said that every
# `build-app-package.sh` run therefore re-proved the viewer gates Z1-Z10. Half of that was true.
# Z5 (settled magnification), Z6 (integral destinations) and Z8 (an over-budget whole page is
# refused) are properties, they are asserted unconditionally, and they held. The four assertions
# that are *durations* — Z1's blit p50, Z3's warm p50 and p95, Z4's cold p95 — sat behind
# `if viewerIsReleaseBuild`, and `build-app-package.sh` builds debug. They had therefore never
# been evaluated by any gate in this repository, while a debug verification run on 2026-08-25
# was already measuring **12.965 ms p50 against a 12 ms budget** and no gate could see it.
#
# Deleting the guard would have been the wrong repair: a millisecond budget written for optimised
# code says nothing about a `-Onone` binary, and a red gate that means nothing is the failure mode
# this repository is most careful about. So the fix has two halves and this script is the first:
#
#   1. **This gate** builds `Apps/ZenitPDF` in **release** and runs `ViewerZoomGateTests` against
#      the optimised binary, where the release budgets of `QUALITY_BAR` section 6 apply and are
#      asserted. It runs in CI (`.github/workflows/ci.yml`, job `perf-release`), beside the
#      renderer, snap and persistence release suites that were already there.
#   2. **A debug budget**, derived from measurement the way the renderer's debug budget of
#      66.4 ms was derived, so the debug run inside `build-app-package.sh` asserts something real instead of
#      asserting nothing. That half lives in the test file and needs no script.
#
# ## Non-vacuity
#
# A performance gate that passes because it measured nothing is worse than no gate. Four things
# are therefore checked on the log, not merely on the exit status:
#
#   * the suite reported `build: release` — a debug binary sneaking into this phase fails here;
#   * the suite reported the **sample shape** Z3's budget is written for. Three blocks of forty
#     warm renders per zoom, pooled, is not decoration: the p50 of a single 40-sample block has a
#     run-to-run sd of 1.105 ms and missed the old 12 ms budget in seven of twenty-four runs of
#     one binary, while the pooled statistic's sd is 0.959 (threshold file, Z3). A run that quietly
#     went back to one block would be measuring a noisier statistic against a budget derived for
#     a quieter one, and would look green until it did not;
#   * every `Z-BUDGET … build=release` verdict line named in REQUIRED_BUDGETS was printed;
#   * every one of them says `verdict=MET` (a `NOT MET` line is also a test failure, but a
#     refactor that turned the `#expect` back into a print would be invisible without this);
#   * the xUnit XML records the suite really ran, with zero failures and zero skips, and at least
#     as many tests as the floor below.
#
# ## One thing this binary is not
#
# The application tests `@testable import ZenitPDFAppKit`, and SwiftPM passes `-enable-testing`
# only in debug, so a plain `swift build -c release --build-tests` here fails outright with
# *"module 'ZenitPDFAppKit' was not compiled for testing"*. This gate therefore adds
# `-Xswiftc -enable-testing`. That is **optimised code with testability on**, not a byte-for-byte
# shipping binary: `-enable-testing` keeps internal symbols visible, which costs some
# internal-symbol elimination and specialisation. It is stated here rather than rounded off,
# because a budget is only as honest as the binary it was measured on. It is still `-O`, and the
# gap between it and a debug `-Onone` build is the thing that made the release guard necessary in
# the first place.
#
# Usage: Scripts/verify-viewer-budgets.sh
#
#   ZENIT_VIEWER_BUDGET_TIMEOUT_SECONDS   watchdog for the test phase. Default 900.
#   ZENIT_VIEWER_BUDGET_COOLDOWN_SECONDS  how long the script will wait, after its own build,
#                                         for this machine to stop being hot. Default 120.
#                                         Set 0 to measure immediately and mean it.
#
# ## The cool-down, and why a performance gate that builds first has to have one
#
# This script compiles the application package in release and then measures milliseconds on the
# machine that just did it. That is a confounder the script creates itself, and it is the single
# largest one in the data. Two rounds of measurement found the same thing from opposite ends:
# the first miss ever recorded (13.895 ms) was in the run started seconds after
# `build-app-package.sh` finished, and the worst figure ever seen for the pooled statistic
# (15.952 ms against a budget of 16.0) came out of this script immediately after a ~90 s all-core
# release compile — while 48 runs of the same binary on a settled machine, isolated and as a whole
# suite, produced a maximum of 12.723 ms.
#
# So the script waits. Not for a fixed number that would be wrong on the next machine, but for a
# self-calibrating signal that the burst has passed: **the one-minute load average back below the
# five-minute one**, checked every three seconds, with a floor of 10 s and a ceiling of
# `ZENIT_VIEWER_BUDGET_COOLDOWN_SECONDS`. A build spikes the one-minute average well above the
# five-minute one; ordinary background work on a busy machine does not. If the ceiling is reached
# the gate measures anyway and says so, because a gate that can wait forever is a gate that hangs.

set -u
set -o pipefail

# This gate measures; it never runs in the advisory mode a hosted CI runner uses.
unset ZENIT_TIMING_ADVISORY

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PACKAGE_DIR="${ROOT}/Apps/ZenitPDF"
readonly SUITE_FILTER='ViewerZoomGateTests|ViewerGestureReplayTests'

# The budget lines this gate exists to see evaluated. Named, so that deleting one is a failure
# rather than a quieter green.
readonly REQUIRED_BUDGETS=(
    'z1_blit_p50'
    'z3_warm_p50'
    'z3_warm_p95'
    'z4_cold_p95'
    'z11_frame_p50'
    'z11_frame_p99'
    'z12_blank_frames'
    'z13_settle_p50'
    'z13_settle_p95'
    'z14_landing_p99'
    # 2026-09-27 (U-005): the pointer replay, `ViewerGestureReplayTests.z15_pointerReplay`, one
    # pair per replay. The first version pooled Select and Length-with-the-loupe into one p50 and
    # one p99, which put the p50 in the gap between two populations (1.07 to 2.29 ms between
    # release runs of one binary) and let a loupe regression hide behind the Select frames.
    'z15_select_frame_p50'
    'z15_select_frame_p99'
    'z15_loupe_frame_p50'
    'z15_loupe_frame_p99'
)

# The suite's size when this gate was written (2026-08-25): 13 tests in `ViewerZoomGateTests`,
# plus the two that guard the budget table itself. A run that executes fewer has lost tests.
readonly MINIMUM_TESTS=15
# 2026-09-23 (NL-PERF-01): plus the two tests of `ViewerGestureReplayTests` — the gesture replay
# (Z11-Z14) and the check of its budget table against quality-thresholds.json.
# 2026-09-27 (U-005): plus the two Z15 tests in the same suite — the pointer replay and the check
# of its budget table (`ViewerPointerReplayTests.swift`).
readonly MINIMUM_TESTS_WITH_REPLAY=$((MINIMUM_TESTS + 4))

readonly TEST_TIMEOUT_SECONDS="${ZENIT_VIEWER_BUDGET_TIMEOUT_SECONDS:-900}"
# A run that must not share `.build` with other builds passes its own scratch path
# (see `Scripts/wave-marker.sh`, who holds the tree). Empty means SwiftPM's default.
readonly SCRATCH_PATH="${ZENIT_VIEWER_BUDGET_SCRATCH_PATH:-}"
SCRATCH_FLAGS=()
if [ -n "${SCRATCH_PATH}" ]; then SCRATCH_FLAGS=(--scratch-path "${SCRATCH_PATH}"); fi
readonly COOLDOWN_MAX_SECONDS="${ZENIT_VIEWER_BUDGET_COOLDOWN_SECONDS:-120}"

# --- Who holds the tree -----------------------------------------------------------------------
if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF
fi

fail() {
    printf '\nFAILED: viewer budget gate during %s\n' "$1" >&2
    exit 1
}

if [ ! -f "${PACKAGE_DIR}/Package.swift" ]; then
    printf 'FAIL: no Package.swift at %s\n' "${PACKAGE_DIR}" >&2
    exit 1
fi

# --- The fixture ------------------------------------------------------------------------------
#
# Every viewer budget is measured on the Synthetic Roof Plan of ZPDFTestingSupport
# (`Packages/ZPDFTestingSupport/FIXTURES.md`, "Calibration"): a heavy A1 sheet generated by the
# suite itself, byte for byte the same on every machine. Its load — about 16 000 painted paths,
# each in its own graphics-state group, a dense hatch reaching into the central viewports, two
# masked rasters — was tuned to the per-zoom cost profile of the CAD-exported A1 sheet the
# budgets were first measured on, so the budgets stand unchanged.
#
# The gate has no skip: nothing it needs is missing from a clone, so every clone, CI's
# `perf-release` job included, measures.

DEVELOPER_DIR_CANDIDATES=(
    "$(xcode-select -p 2>/dev/null || true)"
    "/Library/Developer/CommandLineTools"
)
TESTING_FRAMEWORKS=""
TESTING_LIBS=""
for candidate in "${DEVELOPER_DIR_CANDIDATES[@]}"; do
    [ -n "${candidate}" ] || continue
    # Full Xcode keeps the framework in its macOS platform; the Command Line Tools keep it at
    # the top level. Each entry is "<frameworks dir>:<lib dir>" relative to the candidate.
    for layout in \
        "Platforms/MacOSX.platform/Developer/Library/Frameworks:Platforms/MacOSX.platform/Developer/usr/lib" \
        "Library/Developer/Frameworks:Library/Developer/usr/lib"; do
        if [ -d "${candidate}/${layout%%:*}/Testing.framework" ]; then
            TESTING_FRAMEWORKS="${candidate}/${layout%%:*}"
            TESTING_LIBS="${candidate}/${layout##*:}"
            break 2
        fi
    done
done
readonly TESTING_FRAMEWORKS
readonly TESTING_LIBS
if [ -z "${TESTING_FRAMEWORKS}" ]; then
    printf 'FAIL: no Testing.framework in any of:\n' >&2
    printf '        %s/Platforms/MacOSX.platform/Developer/Library/Frameworks\n' "${DEVELOPER_DIR_CANDIDATES[@]}" >&2
    printf '        %s/Library/Developer/Frameworks\n' "${DEVELOPER_DIR_CANDIDATES[@]}" >&2
    exit 1
fi
printf 'Testing.framework: %s\n' "${TESTING_FRAMEWORKS}"

# `-enable-testing` is required, not optional: see the header note. Without it the release build
# of the test target does not compile at all. `-DZPDF_MOCKS` is required for the same reason: the
# mock presenters and the sample project (ZPDFUIPresentation/Mocks, ProjectShellEnvironment.mock)
# compile only under `DEBUG || ZPDF_MOCKS`, so a shipping release build carries none of them
# (R-142), and five application test files use them. It adds code to the test build and removes
# nothing from the paths the budgets measure.
readonly TEST_FLAGS=(
    -Xswiftc -enable-testing
    -Xswiftc -DZPDF_MOCKS
    -Xswiftc -F -Xswiftc "${TESTING_FRAMEWORKS}"
    -Xlinker -F -Xlinker "${TESTING_FRAMEWORKS}"
    -Xlinker -rpath -Xlinker "${TESTING_FRAMEWORKS}"
    -Xlinker -rpath -Xlinker "${TESTING_LIBS}"
)

cd "${PACKAGE_DIR}" || fail "cd"

started_at="$(date +%s)"

printf '\n=== viewer budgets : swift package resolve ===\n'
swift package resolve ${SCRATCH_FLAGS[@]+"${SCRATCH_FLAGS[@]}"} || fail "swift package resolve"

printf '\n=== viewer budgets : swift build -c release --build-tests ===\n'
swift build -c release ${SCRATCH_FLAGS[@]+"${SCRATCH_FLAGS[@]}"} --build-tests "${TEST_FLAGS[@]}" \
    || fail "swift build -c release --build-tests"

# --- The run --------------------------------------------------------------------------------
#
# Isolated (`--filter`) and optimised, so the numbers belong to the renderer rather than to
# whichever other suite happened to be holding the main actor. The app tier is serialised by
# `AppTierSerialisation`, so a filtered run is also the quietest one available.
printf '\n=== viewer budgets : letting the machine settle after the build ===\n'
cooldown_waited=0
if [ "${COOLDOWN_MAX_SECONDS}" -gt 0 ]; then
    while [ "${cooldown_waited}" -lt "${COOLDOWN_MAX_SECONDS}" ]; do
        read -r _ one five _ <<< "$(sysctl -n vm.loadavg)"
        settled="$(awk -v a="${one}" -v b="${five}" 'BEGIN { print (a <= b) ? 1 : 0 }')"
        if [ "${settled}" = "1" ] && [ "${cooldown_waited}" -ge 10 ]; then
            printf 'settled after %ss: load1 %s is back under load5 %s.\n' \
                "${cooldown_waited}" "${one}" "${five}"
            break
        fi
        printf '  waiting %3ss  load1 %s  load5 %s\n' "${cooldown_waited}" "${one}" "${five}"
        sleep 3
        cooldown_waited=$((cooldown_waited + 3))
    done
    if [ "${cooldown_waited}" -ge "${COOLDOWN_MAX_SECONDS}" ]; then
        printf 'NOTE: this machine did not settle within %ss. Measuring anyway, and saying so:\n' \
            "${COOLDOWN_MAX_SECONDS}" >&2
        printf '      a budget missed on a machine that never went quiet is a fact about the\n' >&2
        printf '      afternoon, not about the renderer. Re-run it alone before concluding.\n' >&2
    fi
else
    printf 'cool-down disabled by ZENIT_VIEWER_BUDGET_COOLDOWN_SECONDS=0.\n'
fi

printf '\n=== viewer budgets : swift test -c release --filter %s (watchdog: %ss) ===\n' \
    "${SUITE_FILTER}" "${TEST_TIMEOUT_SECONDS}"

# The machine's state, recorded before and after. This is evidence for whoever reads a red run —
# it decides nothing. A contended machine does not excuse a missed budget here, and this gate has
# no exit 75: unlike `build-snap-package.sh`, the work being timed is a PDFKit raster on another
# thread, so there is no thread-CPU figure to attribute it with. Worth knowing
# when reading it: across the 24 runs that settled Z3's budget the load average stayed between
# 4.8 and 5.7 and its correlation with the measurement was -0.04, so on this machine a load
# average in that band explains none of the spread. A much larger one is a different question.
load_before="$(uptime | sed -n 's/.*load averages*: *//p')"
printf 'load average before: %s\n' "${load_before}"

log="$(mktemp)" || fail "mktemp"
xml_dir="$(mktemp -d)" || fail "mktemp -d"
status_file="$(mktemp)" || fail "mktemp"

# Job control puts the run in its own process group so the watchdog can kill the whole tree.
set -m
(
    swift test -c release ${SCRATCH_FLAGS[@]+"${SCRATCH_FLAGS[@]}"} --skip-build "${TEST_FLAGS[@]}" \
        --filter "${SUITE_FILTER}" \
        --xunit-output "${xml_dir}/results.xml" > "${log}" 2>&1
    printf '%s' "$?" > "${status_file}"
) &
test_pid=$!
set +m

tail -f "${log}" 2>/dev/null &
tail_pid=$!

watchdog_tripped=0
elapsed=0
while kill -0 "${test_pid}" 2>/dev/null; do
    if [ "${elapsed}" -ge "${TEST_TIMEOUT_SECONDS}" ]; then
        watchdog_tripped=1
        printf '\nWATCHDOG: the viewer budget run did not finish within %ss; stacks follow.\n' \
            "${TEST_TIMEOUT_SECONDS}" >&2
        for hung in $(pgrep -g "${test_pid}" 2>/dev/null); do
            sample "${hung}" 1 2>/dev/null | sed -n '1,120p' >&2 || true
        done
        kill -TERM -- "-${test_pid}" 2>/dev/null || kill -TERM "${test_pid}" 2>/dev/null
        sleep 5
        kill -KILL -- "-${test_pid}" 2>/dev/null || kill -KILL "${test_pid}" 2>/dev/null
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done
wait "${test_pid}" 2>/dev/null
kill "${tail_pid}" 2>/dev/null
wait "${tail_pid}" 2>/dev/null || true

cleanup() { rm -f "${log}" "${status_file}"; rm -rf "${xml_dir}"; }

if [ "${watchdog_tripped}" -eq 1 ]; then
    cleanup
    fail "swift test -c release (watchdog)"
fi

test_status="$(cat "${status_file}" 2>/dev/null || printf '1')"
if [ "${test_status}" != "0" ]; then
    printf '\n--- the budget verdicts this run printed before it failed ---\n' >&2
    grep -E '^Z-BUDGET ' "${log}" >&2 || printf '(none)\n' >&2
    cleanup
    fail "swift test -c release (exit ${test_status})"
fi

# --- Non-vacuity ------------------------------------------------------------------------------

printf '\n=== viewer budgets : the run must have measured an optimised binary ===\n'
if ! grep -qF 'build: release' "${log}"; then
    printf 'FAIL: the suite did not report "build: release".\n' >&2
    printf '      A debug binary measures the compiler, and its budgets are the debug ones.\n' >&2
    cleanup
    fail "a debug binary reached the release budget gate"
fi
printf 'the suite reported an optimised build.\n'

printf '\n=== viewer budgets : Z3 measured the sample shape its budget is written for ===\n'
readonly REQUIRED_SAMPLE_SHAPE='warm samples per zoom: 3 blocks of 40 = 120'
if ! grep -qF "${REQUIRED_SAMPLE_SHAPE}" "${log}"; then
    printf 'FAIL: the suite did not report the pooled sample shape:\n' >&2
    printf '        %s\n' "${REQUIRED_SAMPLE_SHAPE}" >&2
    printf '      Z3 budget of 16.0 ms is derived from the pooled statistic over three\n' >&2
    printf '      blocks of forty (threshold file, Z3). A single 40-sample block is a noisier\n' >&2
    printf '      statistic - sd 1.105 against 0.959, and 24 of 120 single blocks over 12 ms\n' >&2
    printf '      where 4 of 40 pooled observations were - so asserting it against this\n' >&2
    printf '      budget would be measuring one thing and claiming another.\n' >&2
    cleanup
    fail "the Z3 sample shape changed under the budget derived for it"
fi
printf 'the suite pooled three blocks of forty warm renders per zoom.\n'

printf '\n=== viewer budgets : Z11-Z14 replayed the gesture their budgets are written for ===\n'
readonly REQUIRED_REPLAY_SHAPE='replay shape: 72 steps fit to 800 % and back, then 6 gestures of 12'
if ! grep -qF "${REQUIRED_REPLAY_SHAPE}" "${log}"; then
    printf 'FAIL: the gesture replay did not report its shape:\n        %s\n' "${REQUIRED_REPLAY_SHAPE}" >&2
    printf '      A shorter or gentler pinch measures an easier gesture than the budgets name.\n' >&2
    cleanup
    fail "the Z11-Z14 replay shape changed under its budgets"
fi
printf 'the replay ran the 72-step pinch and six short gestures on pages 1 and 2 and with 500 areas.\n'

printf '\n=== viewer budgets : Z15 replayed the pointer path its budgets are written for ===\n'
readonly REQUIRED_POINTER_SHAPE='Z15 replay shape: 240 moves at 120 Hz over 400 markups, Select with a text box selected, then Length with the loupe'
if ! grep -qF "${REQUIRED_POINTER_SHAPE}" "${log}"; then
    printf 'FAIL: the pointer replay did not report its shape:\n        %s\n' "${REQUIRED_POINTER_SHAPE}" >&2
    printf '      Fewer moves, fewer markups or no loupe measures an easier path than the budgets name.\n' >&2
    cleanup
    fail "the Z15 replay shape changed under its budgets"
fi
printf 'the replay ran 240 pointer moves over 400 markups, once with Select and once with the loupe.\n'

printf '\n=== viewer budgets : every named budget was evaluated, and met ===\n'
for budget in "${REQUIRED_BUDGETS[@]}"; do
    line="$(grep -E "^Z-BUDGET ${budget} " "${log}" | tail -1 || true)"
    if [ -z "${line}" ]; then
        printf 'FAIL: no verdict line for %s. The budget was not evaluated in this run.\n' \
            "${budget}" >&2
        cleanup
        fail "missing budget verdict: ${budget}"
    fi
    case "${line}" in
        *' build=release '*) : ;;
        *)
            printf 'FAIL: %s reported a non-release build: %s\n' "${budget}" "${line}" >&2
            cleanup
            fail "budget ${budget} was not measured on optimised code"
            ;;
    esac
    case "${line}" in
        *' verdict=MET') printf '  %s\n' "${line}" ;;
        *)
            printf 'FAIL: %s\n' "${line}" >&2
            printf '      load average before this run: %s\n' "${load_before}" >&2
            printf '      load average now:             %s\n' \
                "$(uptime | sed -n 's/.*load averages*: *//p')" >&2
            printf '      Two readings are possible: the render got slower, or this machine was\n' >&2
            printf '      busy. The load averages above are the evidence that separates them.\n' >&2
            printf '      Re-run this gate alone before concluding either.\n' >&2
            case "${budget}" in
                z15_loupe_*)
                    printf '      Z15 loupe: its lens commit waits on SwiftUI and Core Animation work that\n' >&2
                    printf '      a busy machine starves. Measured with 16 CPU-bound processes running (load\n' >&2
                    printf '      6.6-10.8): p50 3.41-3.79 ms, p99 5.35-10.01 ms, against a settled worst of\n' >&2
                    printf '      1.954 and 4.071 (Docs/Execution/quality-thresholds.json, viewer.Z15).\n' >&2
                    ;;
            esac
            printf '\n' >&2
            printf '      Do not move the budget to make this pass. Z3 p50 was moved once,\n' >&2
            printf '      on 2026-08-25, and only after 24 runs of one binary had shown the\n' >&2
            printf '      old 12.0 ms sitting inside the measurement spread: 7 of 24 red, sd\n' >&2
            printf '      0.886, load uncorrelated at -0.04. The 16.0 ms that replaced it is\n' >&2
            printf '      one standard deviation above the worst pooled value ever measured\n' >&2
            printf '      on this machine and still inside one 60 Hz frame, so there is no\n' >&2
            printf '      room to widen it without giving up the sentence Z3 exists for.\n' >&2
            printf '      A run over it on a quiet machine is a regression: the per-zoom\n' >&2
            printf '      lines above carry min, p50, p95, max and three block medians, and\n' >&2
            printf '      a regression moves the whole shape, not one number in it.\n' >&2
            cleanup
            fail "budget ${budget} was missed"
            ;;
    esac
done

printf '\n=== viewer budgets : test accounting ===\n'
counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
    || { cleanup; fail "xunit accounting (see above)"; }
executed="$(printf '%s' "${counts}" | awk '{print $1}')"
failed="$(printf '%s' "${counts}" | awk '{print $2}')"
skipped="$(printf '%s' "${counts}" | awk '{print $3}')"
cleanup

printf -- '--- viewer budgets : %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
    "${executed}" "${failed}" "${skipped}"
[ "${failed}" = "0" ] || fail "the xUnit XML records ${failed} failures"
[ "${skipped}" = "0" ] || fail "the xUnit XML records ${skipped} skipped tests (a skipped test is a failed test)"
[ "${executed}" -ge "${MINIMUM_TESTS_WITH_REPLAY}" ] \
    || fail "only ${executed} viewer tests executed; the floor is ${MINIMUM_TESTS_WITH_REPLAY}"

printf '\n=======================================================================\n'
printf 'Viewer budgets asserted on an optimised build: Z1, Z3 (p50 and p95), Z4, the gesture\n'
printf 'replay Z11 (p50, p99), Z12, Z13 (p50, p95) and Z14, and the pointer replay Z15 (p50 and\n'
printf 'p99 of Select with a text box selected, and of Length with the loupe).\n'
printf '%s tests executed, 0 failed, 0 skipped (floor %s). (%ds)\n' \
    "${executed}" "${MINIMUM_TESTS_WITH_REPLAY}" "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
