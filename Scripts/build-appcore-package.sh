#!/bin/bash
#
# build-appcore-package.sh — the verification command for ZPDFAppCore.
#
# ZPDFAppCore is the seam between the engines and the UI, so it is the one package that
# depends on both sides of the product at once:
#
#     ZPDFAppCore
#       ├─ ZPDFContracts  ZPDFGeometry  ZPDFMeasurementEngine  ZPDFQuantityLedger
#       ├─ ZPDFSnapEngine  ZPDFVectorExtraction  ZPDFPDFKitBridge
#       ├─ ZPDFSearch (→ ZPDFPersistence → GRDB)  ZPDFCompare
#       └─ ZPDFUIPresentation                       ZPDFTestingSupport (tests only)
#
# It therefore has its own script rather than living in build-core-packages.sh or
# build-ui-packages.sh: a failure here can come from either side, and the point of running
# it separately is to see which.
#
# GRDB is the one remote dependency in the graph, pinned by revision and resolved from the
# local SwiftPM cache. `swift package resolve` runs first so a cold checkout fails with a
# clear message instead of in the middle of a build.
#
# ---------------------------------------------------------------------------------------------
# Testing.framework note
# ---------------------------------------------------------------------------------------------
# This script passes the swift-testing search paths explicitly, from the selected Xcode first and
# the Command Line Tools as the fallback: the same flags and the same reasoning as
# Scripts/build-ui-packages.sh. If no Testing.framework is found at all the script refuses to
# run rather than reporting a green it did not verify.

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
    "${ROOT}/Scripts/wave-marker.sh" check Packages/ZPDFAppCore
fi

readonly PACKAGE_DIR="${ROOT}/Packages/ZPDFAppCore"

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
    printf '\nFAILED: ZPDFAppCore during %s\n' "$1" >&2
    exit 1
}

if [ ! -f "${PACKAGE_DIR}/Package.swift" ]; then
    printf 'FAIL: no Package.swift at %s\n' "${PACKAGE_DIR}" >&2
    exit 1
fi

cd "${PACKAGE_DIR}" || fail "cd"

printf '\n=== ZPDFAppCore : swift package resolve ===\n'
swift package resolve || fail "swift package resolve"

# Built separately from the test run: SwiftPM writes build progress to stdout and
# swift-testing writes results to stderr, so building first keeps the summary readable.
printf '\n=== ZPDFAppCore : swift build --build-tests ===\n'
swift build --build-tests "${TEST_FLAGS[@]}" || fail "swift build --build-tests"

# Tests must be proven to have RUN, not merely to have exited zero.
# ZPDFAppCore's suite is swift-testing only, so the count comes from the runner's own
# --xunit-output XML via Scripts/xunit-summary.sh — no --allow-empty: an XML that accounts
# for zero tests fails this gate. The console tee stays for humans.
printf '\n=== ZPDFAppCore : swift test ===\n'
test_log="$(mktemp)" || fail "mktemp"
xml_dir="$(mktemp -d)" || fail "mktemp -d"
if ! swift test "${TEST_FLAGS[@]}" --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${test_log}"; then
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

printf -- '--- ZPDFAppCore : %s declared, %s executed (swift-testing, per xUnit XML) ---\n' \
    "${declared:-0}" "${swifttesting_run}"

[ "${swifttesting_failed}" = "0" ] \
    || fail "the xUnit XML records ${swifttesting_failed} swift-testing failures"
[ "${swifttesting_skipped}" = "0" ] \
    || fail "the xUnit XML records ${swifttesting_skipped} skipped tests (a skipped test is a failed test)"
# Non-vacuity, added 2026-08-26. Both checks here were guarded on `declared > 0`, so
# a broken declaration scan produced 0 declared, 0 executed and a green gate. The floor is that
# something was examined, and that has to hold when the declaration count is what broke.
#
# The absolute floor is this package's measured size: 192 declared on 2026-08-26, raised to 860
# on 2026-09-27 (loop iteration 3, T-080) — the declared count when the review measured it, all
# swift-testing, 668 above the old floor. A run below it has lost tests; a legitimate shrink
# lowers this line in the same diff and says why.
readonly MINIMUM_TESTS=860
if [ "${swifttesting_run}" -lt "${MINIMUM_TESTS}" ]; then
    fail "only ${swifttesting_run} tests executed; the floor is ${MINIMUM_TESTS} (a shrinking suite is a failure, not a quieter green)"
fi
if [ "${declared:-0}" -eq 0 ]; then
    fail "no @Test declaration was found in ${PACKAGE_DIR}/Tests; the declaration scan examined nothing"
fi
if [ "${declared:-0}" -gt 0 ] && [ "${swifttesting_run}" -eq 0 ]; then
    fail "${declared} tests are declared but none executed"
fi
# T-080: a shortfall fails; it used to print a warning above a green result.
if [ "${declared:-0}" -gt 0 ] && [ "${swifttesting_run}" -lt "${declared}" ]; then
    fail "ZPDFAppCore executed ${swifttesting_run} of ${declared} declared tests (parameterised cases can explain a higher count, never a lower one)"
fi
if grep -rqE 'XCTSkip|\.disabled\(|#if[[:space:]]+false' "${PACKAGE_DIR}/Tests" 2>/dev/null; then
    fail "a test is skipped or compiled out; a skipped test counts as failed here"
fi

printf '\nZPDFAppCore built and tested: %s swift-testing tests executed, 0 failed, 0 skipped.\n' \
    "${swifttesting_run}"
exit 0
