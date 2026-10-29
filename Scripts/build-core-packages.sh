#!/bin/bash
#
# build-core-packages.sh — the verification command for the Zenit PDF core packages.
#
# Builds and unit-tests every core SwiftPM package and vendored bridge in dependency order, then
# re-runs the contract freeze and fails if Docs/Contracts is not byte-identical to what the
# current source generates (apart from the frozenAt timestamp, which is pinned from the committed
# files so that a re-run is not a diff).
#
# Scope is the headless calculation core:
#
#     Bridges/Clipper2Bridge        vendored Clipper2 + extern "C" shim, no dependencies
#     Packages/ZPDFContracts        frozen vocabulary, no dependencies at all
#     Packages/ZPDFGeometry         -> Contracts
#     Packages/ZPDFFormulaEngine    -> Contracts
#     Packages/ZPDFMeasurementEngine -> Contracts, Geometry, Clipper2Bridge
#     Packages/ZPDFQuantityLedger   -> Contracts, FormulaEngine
#     Tests/GoldenMeasurements      -> Contracts, MeasurementEngine   (the acceptance corpus)
#
# The UI packages have Scripts/build-ui-packages.sh; the persistence and document-IO packages
# have their own script. Nothing here depends on a ZPDFUI* package: the dependency direction is
# UI -> core, never core -> UI, and nothing here reaches the network.
#
# `Packages/ZPDFSnapEngine` is deliberately absent. It is a critical area and it is green, but it
# depends on `ZPDFVectorExtraction` and `ZPDFTestingSupport`, which are document-IO packages built
# by Scripts/build-io-packages.sh. Putting it here would drag the IO layer into the headless
# calculation core and invert the scope this script is defined by; it belongs to a gate that runs
# after the IO script.
#
# Exits non-zero on the first failure, naming the package and the phase.

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

readonly CONTRACTS_DIR="${ROOT}/Docs/Contracts"

# Dependency order. Do not re-sort: ZPDFMeasurementEngine will not resolve until Clipper2Bridge,
# ZPDFContracts and ZPDFGeometry have each been built at least once, and Tests/GoldenMeasurements
# — the acceptance corpus for the quantity-calculation critical area — will not resolve until
# ZPDFMeasurementEngine has.
readonly PACKAGES=(
    "Bridges/Clipper2Bridge"
    "Packages/ZPDFContracts"
    "Packages/ZPDFGeometry"
    "Packages/ZPDFFormulaEngine"
    "Packages/ZPDFMeasurementEngine"
    "Packages/ZPDFQuantityLedger"
    "Tests/GoldenMeasurements"
)

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "$1" "$2"
    printf '=======================================================================\n'
    exit 1
}

started_at=$(date +%s)

for package in "${PACKAGES[@]}"; do
    dir="${ROOT}/${package}"
    [ -f "${dir}/Package.swift" ] || fail "${package}" "layout (no Package.swift)"
    cd "${dir}" || fail "${package}" "cd"

    printf '\n=== %s : swift build ===\n' "${package}"
    swift build || fail "${package}" "swift build"

    # Tests must be proven to have RUN, not merely to have exited zero. A package can hold XCTest
    # cases, swift-testing cases, or both. The swift-testing count is read from the xUnit XML the
    # runner itself writes (`--xunit-output`), never from the console stream: console parsing
    # worked only because this toolchain writes results to stdout. The tee stays
    # for humans. XCTest is the one remainder: on this toolchain (Xcode 26.6 / Swift 6.3.3,
    # verified 2026-08-23) `swift test --xunit-output x.xml` writes only x-swift-testing.xml and
    # no XCTest file at all, so the "Executed N tests" console line is still read for the XCTest
    # half — protected by the declared-count floor below, which turns a broken parse into a red
    # gate instead of a miscount.
    printf '\n=== %s : swift test ===\n' "${package}"
    test_log="$(mktemp)" || fail "${package}" "mktemp"
    xml_dir="$(mktemp -d)" || fail "${package}" "mktemp -d"
    if ! swift test --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${test_log}"; then
        rm -f "${test_log}"; rm -rf "${xml_dir}"
        fail "${package}" "swift test"
    fi

    xctest_run=$(sed -n 's/.*Executed \([0-9][0-9]*\) tests*, with .*/\1/p' "${test_log}" | tail -1)
    xctest_failed=$(sed -n 's/.*Executed [0-9][0-9]* tests*, with \([0-9][0-9]*\) failure.*/\1/p' "${test_log}" | tail -1)
    rm -f "${test_log}"

    # --allow-empty because an XCTest-only package (Clipper2Bridge) legitimately reports zero
    # swift-testing tests; the combined floor below still refuses a package that ran nothing.
    st_counts="$("${ROOT}/Scripts/xunit-summary.sh" --allow-empty "${xml_dir}/results-swift-testing.xml")" \
        || { rm -rf "${xml_dir}"; fail "${package}" "xunit accounting (see above)"; }
    rm -rf "${xml_dir}"
    swifttesting_run="$(printf '%s' "${st_counts}" | awk '{print $1}')"
    swifttesting_failed="$(printf '%s' "${st_counts}" | awk '{print $2}')"
    swifttesting_skipped="$(printf '%s' "${st_counts}" | awk '{print $3}')"

    # Count declarations directly. Do not pipe file names through xargs: this repository lives
    # under a path containing spaces, which silently splits them and yields a count of zero.
    declared=$(grep -rhoE --include='*.swift' '(@Test[[:space:](]|func[[:space:]]+test[A-Za-z0-9_]*\()' \
        "${dir}/Tests" 2>/dev/null | wc -l | tr -d ' ')

    executed=$(( ${xctest_run:-0} + ${swifttesting_run:-0} ))
    printf -- '--- %s : %s declared, %s executed (XCTest %s, swift-testing %s per xUnit XML) ---\n' \
        "${package}" "${declared:-0}" "${executed}" "${xctest_run:-0}" "${swifttesting_run:-0}"

    [ "${xctest_failed:-0}" = "0" ] || fail "${package}" "XCTest reported ${xctest_failed} failures"
    [ "${swifttesting_failed:-0}" = "0" ] \
        || fail "${package}" "the xUnit XML records ${swifttesting_failed} swift-testing failures"
    [ "${swifttesting_skipped:-0}" = "0" ] \
        || fail "${package}" "the xUnit XML records ${swifttesting_skipped} skipped tests (a skipped test is a failed test)"
    # Non-vacuity, added 2026-08-26. The two checks below were both guarded on
    # `declared > 0`, so a package whose declaration grep broke — a renamed Tests directory, a
    # path the `grep -r` no longer reaches — reported 0 declared, 0 executed and passed. The
    # floor a gate needs is not "executed matches declared" but "something was examined", and
    # that has to hold when the declaration count itself is the thing that failed.
    if [ "${executed}" -eq 0 ]; then
        fail "${package}" "no test executed at all (declared ${declared:-0}); a gate that ran nothing does not pass"
    fi
    if [ "${declared:-0}" -eq 0 ]; then
        fail "${package}" "no @Test or testXxx declaration was found in ${dir}/Tests; the declaration scan examined nothing"
    fi
    if [ "${declared:-0}" -gt 0 ] && [ "${executed}" -eq 0 ]; then
        fail "${package}" "${declared} tests are declared but none executed"
    fi
    # T-080: a shortfall fails; it used to print a warning above a green result.
    if [ "${declared:-0}" -gt 0 ] && [ "${executed}" -lt "${declared}" ]; then
        fail "${package}" "executed ${executed} of ${declared} declared tests (parameterised cases can explain a higher count, never a lower one)"
    fi
    if grep -rqE 'XCTSkip|\.disabled\(|#if[[:space:]]+false' "${dir}/Tests" 2>/dev/null; then
        fail "${package}" "a test is skipped or compiled out; a skipped test counts as failed here"
    fi
done

# The frozen contracts must match what the source generates right now. The freeze is regenerated
# into a scratch directory using the committed frozenAt, so only real content drift shows up.
printf '\n=== Docs/Contracts : freeze drift check ===\n'
frozen_at="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['frozenAt'])" \
    "${CONTRACTS_DIR}/ARCHITECTURE_FREEZE.json")" || fail "contracts" "read frozenAt"

tmp_dir="$(mktemp -d)" || fail "contracts" "mktemp"
trap 'rm -rf "${tmp_dir}"' EXIT

cd "${ROOT}/Packages/ZPDFContracts" || fail "contracts" "cd"
swift run zpdf-contract-freeze "${tmp_dir}" "${frozen_at}" >/dev/null \
    || fail "contracts" "swift run zpdf-contract-freeze"

if diff -r "${CONTRACTS_DIR}" "${tmp_dir}" >/dev/null 2>&1; then
    printf 'Docs/Contracts matches the Swift source.\n'
else
    diff -r "${CONTRACTS_DIR}" "${tmp_dir}" | head -40
    fail "contracts" "freeze drift — run: swift run zpdf-contract-freeze ../../Docs/Contracts"
fi

printf '\n=======================================================================\n'
printf 'All %d core packages and corpora built and tested; contracts are in sync. (%ds)\n' \
    "${#PACKAGES[@]}" "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
