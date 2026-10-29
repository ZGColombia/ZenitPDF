#!/bin/bash
#
# build-app-package.sh — the verification command for Apps/ZenitPDF (the application tier).
#
# This gate exists because of a live finding: twelve package gates were
# green while ⌘Z was dead in the assembled app — the application package's own 50+ tests
# (document lifecycle, tabbed windows, menu routing, canvas drawing, quit review) were the
# only ones that could have caught it, and no gate ran them. This one does, with the same
# xunit accounting the other gates use, plus a hard floor: the suite shrinking below the
# count it had when this gate was written is a failure, not a quieter green.
#
# What it runs, from Apps/ZenitPDF:
#   0. needs build/Zenit PDF.app from Scripts/build-app.sh, with the current licence notices
#   1. swift package resolve      — fail early on a cold checkout, with a clear message
#   2. swift build --build-tests  — build separated from the run so the summary stays readable
#   3. swift test --xunit-output  — declared == executed, zero-test runs fail, skipped = failed
#
# The Testing.framework note and search are the same as every other
# gate script; see Scripts/build-ui-packages.sh for the reasoning.

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
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF
fi

readonly PACKAGE_DIR="${ROOT}/Apps/ZenitPDF"

# The floor: a run that executes fewer tests than this has lost tests — parameterised cases can
# only raise the executed count, never lower it. It was last raised to 1179, the suite's declared
# count when it was measured (every test swift-testing, no platform `#if` around a test); an
# earlier floor 750 below the truth would have let most of the suite stop executing under a green
# gate. Declared == executed is a failure check of its own, so this floor only has to catch the
# declaration scan itself losing tests. Raise it when the suite legitimately grows, to a count
# this script measured green on a tree nobody else was writing; never lower it to make a red gate
# green.
readonly MINIMUM_TESTS=1179

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
    printf '      swift-testing is required to verify this package.\n' >&2
    exit 1
fi
printf 'Testing.framework: %s\n' "${TESTING_FRAMEWORKS}"

readonly TEST_FLAGS=(
    -Xswiftc -F -Xswiftc "${TESTING_FRAMEWORKS}"
    -Xlinker -F -Xlinker "${TESTING_FRAMEWORKS}"
    -Xlinker -rpath -Xlinker "${TESTING_FRAMEWORKS}"
    -Xlinker -rpath -Xlinker "${TESTING_LIBS}"
)

fail() {
    printf '\nFAILED: ZenitPDF app package during %s\n' "$1" >&2
    exit 1
}

if [ ! -f "${PACKAGE_DIR}/Package.swift" ]; then
    printf 'FAIL: no Package.swift at %s\n' "${PACKAGE_DIR}" >&2
    exit 1
fi

cd "${PACKAGE_DIR}" || fail "cd"

# --- No test may present a modal alert ---------------------------------------------------
#
# `sample(1)` on two hung runs of this gate gave the same stack both times: an NSDocument
# autosave failure escalated to `-[NSDocument presentError:]`, which ran `-[NSAlert runModal]`
# inside a headless test process. A modal loop with no user never ends, so the gate hung
# rather than failed — and a gate that can hang is worse than one that fails.
#
# Two defences. This one is structural: `ZenitErrorPresenter` is the single door errors go
# through, and it refuses to run a modal unless the process really is the assembled bundle.
# A new direct `presentError` call anywhere else reopens the hang, so it fails the gate here
# instead of at 03:00 on somebody's machine.
#
# Two things are not offenders. Declarations (`override func presentError`) are not calls.
# And `super.presentError(...)` inside those overrides *is* the AppKit implementation being
# overridden — it runs only when `ZenitErrorPresenter.presentsThroughAppKit` says this
# process is the assembled bundle, which a test process never is.
printf '\n=== ZenitPDF app package : no direct error presentation ===\n'
modal_offenders="$(grep -rnE '(\.presentError\(|^[[:space:]]*presentError\()' \
    --include='*.swift' "${PACKAGE_DIR}/Sources" 2>/dev/null \
    | grep -v '/ZenitErrorPresenter\.swift:' \
    | grep -v 'super\.presentError(' || true)"
if [ -n "${modal_offenders}" ]; then
    printf 'FAIL: presentError must be called only from ZenitErrorPresenter.\n' >&2
    printf '      A direct call can run NSAlert.runModal in a headless test and hang this gate.\n' >&2
    printf '%s\n' "${modal_offenders}" >&2
    fail "modal error presentation outside ZenitErrorPresenter"
fi
printf 'presentError is reached only through ZenitErrorPresenter.\n'

# --- Parity backlog 0.6: no fabricated results in front of a user --------------------------
#
# The shipping Search panel was bound to `MockSearchPresenter` — a hard-coded hit list from a
# sample project — so a real estimator looking at a real drawing was answered with results
# belonging to a different document. That is the same defect class as a quantity computed
# without a scale, and it survived because nothing forbade it.
#
# Nothing in `Apps/ZenitPDF/Sources` may construct a mock presenter. The mocks stay where they
# belong: in `ZPDFUIPresentation/Mocks`, for the shell's `#if DEBUG` previews and for tests.
printf '\n=== ZenitPDF app package : no mock presenter in the shipping application ===\n'
mock_offenders="$(grep -rnE 'Mock[A-Za-z]*Presenter\(|ProjectShellEnvironment\.mock\(' \
    --include='*.swift' "${PACKAGE_DIR}/Sources" 2>/dev/null || true)"
if [ -n "${mock_offenders}" ]; then
    printf 'FAIL: the shipping application constructs a mock presenter.\n' >&2
    printf '      A fabricated result in front of a user is a wrong number in a bid.\n' >&2
    printf '%s\n' "${mock_offenders}" >&2
    fail "mock presenter bound in Apps/ZenitPDF"
fi
# Raised from 20, which was less than half the truth. Measured: 54.
readonly MINIMUM_SCANNED_SOURCES=54
scanned_sources="$(find "${PACKAGE_DIR}/Sources" -name '*.swift' | wc -l | tr -d ' ')"
if [ "${scanned_sources:-0}" -lt "${MINIMUM_SCANNED_SOURCES}" ]; then
    fail "the mock-presenter scan examined only ${scanned_sources} of ${MINIMUM_SCANNED_SOURCES} expected files; a gate that scans less than it did must fail"
fi
printf 'no mock presenter is constructed in %s source files.\n' "${scanned_sources}"

# --- No test may present a modal a human then dismisses ---------------------------------
#
# The watchdog above catches a suite that **hangs** on a modal. It cannot see one a person
# answers: an app-tier test whose reopen ran `NSAlert.runModal()` once put
# *"StampRotation.zpdfproj was not closed properly"* in front of whoever was at the machine.
# A dialogue a human answers makes a test
# pass that would otherwise hang or fail, so the suite's result depends on who was watching —
# the same class of defect as a skipped test reported as green.
#
# `verify-no-uninjected-modals.sh` is the structural half: nothing under `Apps/ZenitPDF` may
# run a dialogue outside `ZenitModalPresenter`, which in turn refuses to draw in any process
# that is not the assembled bundle. It is a separate script so it can be run on its own while
# working, and it is *run* here rather than merely checked for, because a gate this cheap has
# no excuse to be optional.
printf '\n'
if [ ! -x "${ROOT}/Scripts/verify-no-uninjected-modals.sh" ]; then
    fail "Scripts/verify-no-uninjected-modals.sh is missing or not executable — nothing would stop a test putting a dialogue on the user's screen"
fi
"${ROOT}/Scripts/verify-no-uninjected-modals.sh" || fail "uninjected modal presentation"

# --- No package left armed --------------------------------------------------------------
#
# Crash-recovery tests own their marker: killing the process is the point of the test, and
# leaving it armed is the defect. An armed `recovery/crash-marker` means the next open of
# that package raises the recovery dialogue to whoever is there. This gate runs before the
# suite as well as being available on its own, and it reports an armed package by name rather
# than tidying it away — see the script's header.
#
# Run from here, the gate walks the repository and its own matcher canary. It reads the account's
# Documents, Desktop and Downloads only when ZENIT_ARMED_SCAN_HOME=1 is set in the environment, so
# by default the result depends on the tree under test rather than on what is open in a person's
# home folders, and no macOS privacy prompt appears.
if [ ! -x "${ROOT}/Scripts/verify-no-armed-recovery-markers.sh" ]; then
    fail "Scripts/verify-no-armed-recovery-markers.sh is missing or not executable"
fi
# Three outcomes, not two. Until 2026-08-26 that gate could return a green
# `scanned 0 packages` because `find ~/Documents` failed with *Operation not permitted* under
# macOS privacy protection and its `2>/dev/null` swallowed the message — the sixth gate in this
# repository decided by state outside the code and the first decided by a permission. It now
# fails when it is blind, and it distinguishes the two reasons:
#
#   1  an armed marker was actually found — a defect, and the suite must not run over it;
#  75  nothing armed among the roots it could read, and at least one root it could not. With the
#      home folders opted in, the usual cause is a privacy permission; without them, only an
#      error while walking the repository or the canary can produce it.
#
# 75 is not a pass and this script does not treat it as one: the run ends non-zero with 75, so
# no caller can read it as green. But it is also not the same as an armed marker, so the suite
# still runs and still produces its evidence — a permission a run cannot grant itself must
# not take the whole application tier offline, and a gate that blocks all work is a gate people
# learn to bypass, which is worse than the blindness it replaced.
armed_marker_inconclusive=0
"${ROOT}/Scripts/verify-no-armed-recovery-markers.sh"
armed_marker_rc=$?
case "${armed_marker_rc}" in
    0) ;;
    75)
        armed_marker_inconclusive=1
        printf '\n'
        printf '========================================================================\n'
        printf 'PRECONDITION INCONCLUSIVE — the armed-marker scan was denied a root.\n'
        printf 'This run will end with exit 75. It is not a pass. The suite below still\n'
        printf 'runs, because the denial is a macOS privacy permission rather than a\n'
        printf 'defect in the code under test, and its evidence is still worth having.\n'
        printf 'A human must rerun Scripts/verify-no-armed-recovery-markers.sh (with ZENIT_ARMED_SCAN_HOME=1\n'
        printf 'if it was set) from a '
        printf 'terminal holding Full Disk Access to settle it.\n'
        printf '========================================================================\n\n'
        ;;
    *) fail "a project package was left with its crash marker armed" ;;
esac

# --- The launch gate must exist ------------------------------------------------------------
#
# Static linkage analysis is not the same as starting (the 2026-08-24 dyld crash). The gate that
# actually launches the assembled bundle is a separate script because it needs a bundle; this
# check is here so deleting it cannot go unnoticed.
if [ ! -x "${ROOT}/Scripts/verify-app-launches.sh" ]; then
    fail "Scripts/verify-app-launches.sh is missing or not executable — nothing would prove the assembled bundle starts"
fi
printf 'Scripts/verify-app-launches.sh is present and executable.\n'

# --- The viewer's millisecond budgets must still be asserted somewhere -----------------------
#
# This gate builds debug, and until 2026-08-25 the four timing `#expect`s in
# `ViewerZoomGateTests` were behind a release-build guard, so this gate ran them, printed their
# numbers, and evaluated none of them — while three documents said each run re-proved them.
#
# The repair has two halves and this gate owns one of each. The debug half is inside the suite
# below: the budgets now have a measured debug column and are asserted here (only CI's hosted
# runners set ZENIT_TIMING_ADVISORY=1, which turns a miss into a warning), with
# `noTimingBudgetIsGuardedOutOfTheGate` failing the build if the guard returns. The release
# half is `Scripts/verify-viewer-budgets.sh`, which needs an optimised build and so cannot live
# in this script; this check is here so that deleting it cannot go unnoticed.
if [ ! -x "${ROOT}/Scripts/verify-viewer-budgets.sh" ]; then
    fail "Scripts/verify-viewer-budgets.sh is missing or not executable — nothing would assert the viewer's release latency budgets"
fi
printf 'Scripts/verify-viewer-budgets.sh is present and executable.\n'

# --- The suite reads the assembled bundle's licence notices ---------------------------------
#
# `AcknowledgementsSurfaceTests` loads the notices of build/Zenit PDF.app through the product's
# own loader, because that is the artefact a person receives. Without a bundle, or with one
# assembled before the notices last changed, that test fails twenty minutes into the run with a
# message about a missing licence. `Scripts/build-app.sh` copies Apps/ZenitPDF/Bundle/Licenses
# verbatim, so a byte comparison says up front whether the bundle is current.
assembled_licences="${ROOT}/build/Zenit PDF.app/Contents/Resources/Licenses"
if [ ! -d "${assembled_licences}" ]; then
    fail "the bundle check: no build/Zenit PDF.app — run Scripts/build-app.sh first (one test reads the bundle's licence notices)"
fi
if ! diff -rq "${PACKAGE_DIR}/Bundle/Licenses" "${assembled_licences}" >/dev/null 2>&1; then
    fail "the bundle check: build/Zenit PDF.app predates the licence notices in Apps/ZenitPDF/Bundle/Licenses — rerun Scripts/build-app.sh"
fi
printf 'build/Zenit PDF.app carries the current licence notices.\n'

printf '\n=== ZenitPDF app package : swift package resolve ===\n'
swift package resolve || fail "swift package resolve"

printf '\n=== ZenitPDF app package : swift build --build-tests ===\n'
swift build --build-tests "${TEST_FLAGS[@]}" || fail "swift build --build-tests"

# --- The watchdog -------------------------------------------------------------------------
#
# The second defence, and the general one: whatever the reason, a suite that stops making
# progress must FAIL, loudly, with a stack — never sit there looking slow. The whole run is
# given TEST_TIMEOUT_SECONDS; on expiry the runner's process group is sampled (so the next
# reader gets the same evidence `sample(1)` gave for 15.8) and then killed.
#
# Two limits. The first is *progress*: the run is killed when its output has not grown
# for TEST_IDLE_SECONDS, which is what a suite blocked on a modal looks like. The second is an absolute cap.
# Before 2026-09-27 there was only a 600 s total, so a suite that had grown to 1 200+ tests (about ten minutes of
# honest work, most of it serialised behind the app-tier gate) was killed mid-run as if it had hung. The
# suite now runs 1 480 tests in about 1 300 s on the reference Mac, one at a time, so the cap scales with
# per-core speed; CI sets ZENIT_TEST_TIMEOUT_SECONDS higher for its slower runners.
readonly TEST_IDLE_SECONDS="${ZENIT_TEST_IDLE_SECONDS:-300}"
readonly TEST_TIMEOUT_SECONDS="${ZENIT_TEST_TIMEOUT_SECONDS:-3600}"

# Tests must be proven to have RUN, not merely to have exited zero.
printf '\n=== ZenitPDF app package : swift test (watchdog: %ss) ===\n' "${TEST_TIMEOUT_SECONDS}"
test_log="$(mktemp)" || fail "mktemp"
xml_dir="$(mktemp -d)" || fail "mktemp -d"
status_file="$(mktemp)" || fail "mktemp"

# Job control puts the background job in its own process group, so the watchdog can kill the
# whole tree — `swift test` spawns the runner as a child and killing only the parent leaves a
# modal-blocked runner alive.
set -m
(
    swift test "${TEST_FLAGS[@]}" --xunit-output "${xml_dir}/results.xml" > "${test_log}" 2>&1
    printf '%s' "$?" > "${status_file}"
) &
test_pid=$!
set +m

# Stream the suite's output while it runs, so the gate still reads like the others.
tail -f "${test_log}" 2>/dev/null &
tail_pid=$!

watchdog_tripped=0
elapsed=0
idle=0
last_size=0
while kill -0 "${test_pid}" 2>/dev/null; do
    size="$(wc -c < "${test_log}" 2>/dev/null | tr -d ' ')"
    if [ "${size:-0}" != "${last_size}" ]; then
        last_size="${size:-0}"
        idle=0
    fi
    if [ "${idle}" -ge "${TEST_IDLE_SECONDS}" ] || [ "${elapsed}" -ge "${TEST_TIMEOUT_SECONDS}" ]; then
        watchdog_tripped=1
        printf '\nWATCHDOG: the app suite made no progress for %ss (or ran past %ss) and is being killed.\n' \
            "${idle}" "${TEST_TIMEOUT_SECONDS}" >&2
        printf 'WATCHDOG: stacks of the hung process tree follow (a modal alert has hung this suite before).\n' >&2
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
    idle=$((idle + 2))
done
wait "${test_pid}" 2>/dev/null
kill "${tail_pid}" 2>/dev/null
wait "${tail_pid}" 2>/dev/null || true

if [ "${watchdog_tripped}" -eq 1 ]; then
    rm -f "${test_log}" "${status_file}"; rm -rf "${xml_dir}"
    fail "swift test (watchdog: no output for ${TEST_IDLE_SECONDS}s, or past ${TEST_TIMEOUT_SECONDS}s)"
fi

test_status="$(cat "${status_file}" 2>/dev/null || printf '1')"
rm -f "${status_file}"
if [ "${test_status}" != "0" ]; then
    rm -f "${test_log}"; rm -rf "${xml_dir}"
    fail "swift test"
fi
rm -f "${test_log}"

st_counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
    || { rm -rf "${xml_dir}"; fail "xunit accounting (see above)"; }
rm -rf "${xml_dir}"
swifttesting_run="$(printf '%s' "${st_counts}" | awk '{print $1}')"
swifttesting_failed="$(printf '%s' "${st_counts}" | awk '{print $2}')"
swifttesting_skipped="$(printf '%s' "${st_counts}" | awk '{print $3}')"

# Count declarations directly. Do not pipe file names through xargs: this repository lives
# under a path containing spaces, which silently splits them and yields a count of zero.
declared=$(grep -rhoE --include='*.swift' '(@Test[[:space:](]|func[[:space:]]+test[A-Za-z0-9_]*\()' \
    "${PACKAGE_DIR}/Tests" 2>/dev/null | wc -l | tr -d ' ')

printf -- '--- ZenitPDF app package : %s declared, %s executed (swift-testing, per xUnit XML) ---\n' \
    "${declared:-0}" "${swifttesting_run}"

[ "${swifttesting_failed}" = "0" ] \
    || fail "the xUnit XML records ${swifttesting_failed} swift-testing failures"
[ "${swifttesting_skipped}" = "0" ] \
    || fail "the xUnit XML records ${swifttesting_skipped} skipped tests (a skipped test is a failed test)"
if [ "${declared:-0}" -gt 0 ] && [ "${swifttesting_run}" -eq 0 ]; then
    fail "${declared} tests are declared but none executed"
fi
# T-080: a shortfall is a failure, not a warning printed above a green result. Parameterised
# cases can explain a higher count, never a lower one; the header's "declared == executed" is
# enforced here as it is in the renderer, qpdf, platform, IO, export and snap gates.
if [ "${declared:-0}" -gt 0 ] && [ "${swifttesting_run}" -lt "${declared}" ]; then
    fail "the app package executed ${swifttesting_run} of ${declared} declared tests (parameterised cases can explain a higher count, never a lower one)"
fi
if [ "${swifttesting_run}" -lt "${MINIMUM_TESTS}" ]; then
    fail "only ${swifttesting_run} tests executed; the floor is ${MINIMUM_TESTS} (the dead-⌘Z lesson: a shrinking app suite is a failure, not a quieter green)"
fi
if grep -rqE 'XCTSkip|\.disabled\(|#if[[:space:]]+false' "${PACKAGE_DIR}/Tests" 2>/dev/null; then
    fail "a test is skipped or compiled out; a skipped test counts as failed here"
fi

printf '\nZenitPDF app package built and tested: %s swift-testing tests executed, 0 failed, 0 skipped (floor %s).\n' \
    "${swifttesting_run}" "${MINIMUM_TESTS}"

if [ "${armed_marker_inconclusive}" -eq 1 ]; then
    printf '\nINCONCLUSIVE: the suite is green, and one precondition could not be evaluated.\n' >&2
    printf '      Scripts/verify-no-armed-recovery-markers.sh was denied a search root, so\n' >&2
    printf '      nobody can say whether a project package in this account'"'"'s home is left with\n' >&2
    printf '      its crash marker armed. Read the block near the top of\n' >&2
    printf '      this log for the command a human must run.\n' >&2
    printf '\nThis is exit 75, not 0 and not 1: the tests passed, and this run may not be\n' >&2
    printf 'reported green.\n' >&2
    exit 75
fi

exit 0
