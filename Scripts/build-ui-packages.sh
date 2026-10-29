#!/bin/bash
#
# build-ui-packages.sh — the verification command for the Zenit PDF UI packages.
#
# Builds and unit-tests the six local SwiftPM packages in dependency order and exits non-zero
# on the first failure. There are no remote dependencies, so the run is offline and repeatable.
#
# Dependency graph (an arrow means "depends on"):
#
#                          ZPDFUIShell
#                     /         |         \
#        ZPDFUILedger   ZPDFUIMeasurement   ZPDFUIWorkflows
#                     \         |         /
#                       ZPDFDesignSystem
#                              |
#                              v
#                      ZPDFUIPresentation
#
# ZPDFUIPresentation has no dependencies. ZPDFDesignSystem depends on it (it is the one place
# allowed to turn a presentation value into something drawable). The three surface packages
# depend on both. ZPDFUIShell depends on all three, because it is the only package that composes
# a whole project window and therefore the only place their panels can be made reachable: the
# docked Quantity Ledger table is ZPDFUILedger's grouped NSOutlineView,
# the Scale Regions panel is ZPDFUIMeasurement's, and the canvas view modes — Split Canvas and
# Revision Overlay — plus the no-dead-ends mode registry are ZPDFUIWorkflows'. There is no cycle:
# no arrow points back out of the shell.
#
# The build order below therefore puts ZPDFUIShell last. It is fixed only so the output is
# comparable between runs; SwiftPM resolves each package's own dependencies regardless.
#
# ---------------------------------------------------------------------------------------------
# Testing.framework note
# ---------------------------------------------------------------------------------------------
# TOOLCHAIN.md requires full Xcode, but these gates also have to run where only the Command Line
# Tools are installed. Two consequences:
#
# 1. The script passes the swift-testing search paths explicitly, taken from the selected Xcode's
#    macOS platform first and from the Command Line Tools only when Xcode has none:
#
#      Xcode:  <DEVELOPER_DIR>/Platforms/MacOSX.platform/Developer/Library/Frameworks   (and usr/lib)
#      CLT:    /Library/Developer/CommandLineTools/Library/Developer/Frameworks       (and usr/lib)
#
#    `-F` finds Testing.swiftmodule, and the two rpaths find Testing.framework and
#    lib_TestingInterop.dylib. Under the Command Line Tools alone, `swift test` fails without them
#    with "no such module 'Testing'". Under Xcode they name the copy SwiftPM would use anyway, so
#    the compiler and the framework come from the same toolchain. If no Testing.framework is
#    found at all, the script refuses to run rather than reporting a green it did not verify.
#
# 2. Under the Command Line Tools alone there is no XCTest framework to link against.
#    ZPDFDesignSystem's suite is XCTest-based and is compiled out behind
#    `#if canImport(XCTest)`, so `swift test` can legitimately report zero tests for it. Its
#    assertions are also expressed as `ZPDFSelfCheck`, which the `zpdf-design-audit` executable
#    runs, so the script runs that executable for that package. Do not remove it: without it,
#    ZPDFDesignSystem is unverified on such a machine.

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

readonly PACKAGES_DIR="${ROOT}/Packages"

# Dependency order. Do not re-sort: ZPDFUIShell depends on the three surface packages and
# must come last, so a shell failure is never mistaken for one of theirs.
readonly PACKAGES=(
    ZPDFUIPresentation
    ZPDFDesignSystem
    ZPDFUILedger
    ZPDFUIMeasurement
    ZPDFUIWorkflows
    ZPDFUIShell
)

# Look for Testing.framework in the active developer dir first, then in the Command Line Tools.
# `xcode-select -p` can point at an Xcode.app that is still being installed, or at one whose
# Frameworks directory does not exist; in that case the Command Line Tools copy is the one that
# actually works. Only when neither location has it does the script refuse to run.
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

if [ -n "${TESTING_FRAMEWORKS}" ]; then
    printf 'Testing.framework: %s\n' "${TESTING_FRAMEWORKS}"
    TEST_FLAGS=(
        -Xswiftc -F -Xswiftc "${TESTING_FRAMEWORKS}"
        -Xlinker -F -Xlinker "${TESTING_FRAMEWORKS}"
        -Xlinker -rpath -Xlinker "${TESTING_FRAMEWORKS}"
        -Xlinker -rpath -Xlinker "${TESTING_LIBS}"
    )
else
    printf 'FAIL: no Testing.framework in any of:\n' >&2
    printf '        %s/Platforms/MacOSX.platform/Developer/Library/Frameworks\n' "${DEVELOPER_DIR_CANDIDATES[@]}" >&2
    printf '        %s/Library/Developer/Frameworks\n' "${DEVELOPER_DIR_CANDIDATES[@]}" >&2
    printf '      swift-testing is required to verify these packages.\n' >&2
    exit 1
fi

RESULTS=()

record() { RESULTS+=("$1"); }

print_table() {
    printf '\n'
    printf '  %-20s  %s\n' "PACKAGE" "RESULT"
    printf '  %-20s  %s\n' "--------------------" "------"
    local row
    for row in "${RESULTS[@]}"; do
        printf '  %s\n' "${row}"
    done
}

fail() {
    # fail <package> <stage>
    record "$(printf '%-20s  FAIL (%s)' "$1" "$2")"
    print_table
    printf '\nFAILED: %s during %s\n' "$1" "$2"
    exit 1
}

for package in "${PACKAGES[@]}"; do
    dir="${PACKAGES_DIR}/${package}"
    if [ ! -f "${dir}/Package.swift" ]; then
        printf '\nFAIL: no Package.swift at %s\n' "${dir}"
        fail "${package}" "layout"
    fi

    cd "${dir}" || fail "${package}" "cd"

    printf '\n=== %s : swift build ===\n' "${package}"
    swift build || fail "${package}" "swift build"

    # Tests must be proven to have RUN, not merely to have exited zero.
    # The swift-testing count is read from the xUnit XML the runner itself writes
    # (`--xunit-output`) via Scripts/xunit-summary.sh, never from the console stream. The tee
    # stays for humans. Every UI package except ZPDFDesignSystem is swift-testing only, so the
    # XML must account for at least one test — no --allow-empty. ZPDFDesignSystem is the one
    # XCTest-based suite (guarded by `#if canImport(XCTest)`): on a machine with Xcode its
    # cases run and the console "Executed N tests" line is read for that half; on a Command
    # Line Tools machine they compile out and `zpdf-design-audit` below stands in — that is
    # why it alone gets --allow-empty and is exempt from the executed-count floor.
    printf '\n=== %s : swift test ===\n' "${package}"
    test_log="$(mktemp)" || fail "${package}" "mktemp"
    xml_dir="$(mktemp -d)" || fail "${package}" "mktemp -d"
    if ! swift test "${TEST_FLAGS[@]}" --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${test_log}"; then
        rm -f "${test_log}"; rm -rf "${xml_dir}"
        fail "${package}" "swift test"
    fi

    xctest_run=$(sed -n 's/.*Executed \([0-9][0-9]*\) tests*, with .*/\1/p' "${test_log}" | tail -1)
    xctest_failed=$(sed -n 's/.*Executed [0-9][0-9]* tests*, with \([0-9][0-9]*\) failure.*/\1/p' "${test_log}" | tail -1)
    rm -f "${test_log}"

    allow_empty_flag=()
    if [ "${package}" = "ZPDFDesignSystem" ]; then
        allow_empty_flag=(--allow-empty)
    fi
    st_counts="$("${ROOT}/Scripts/xunit-summary.sh" ${allow_empty_flag[@]+"${allow_empty_flag[@]}"} \
        "${xml_dir}/results-swift-testing.xml")" \
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
    if [ "${package}" != "ZPDFDesignSystem" ]; then
        # Non-vacuity, added 2026-08-26. Both checks were guarded on `declared > 0`,
        # so a package whose declaration scan broke reported 0 declared, 0 executed and passed.
        # ZPDFDesignSystem is the one documented exemption (its XCTest suite cannot compile
        # without Xcode and its assertions run inline below); every other package must show that
        # something was examined.
        if [ "${executed}" -eq 0 ]; then
            fail "${package}" "no test executed at all (declared ${declared:-0}); a gate that ran nothing does not pass"
        fi
        if [ "${declared:-0}" -eq 0 ]; then
            fail "${package}" "no test declaration was found in ${dir}/Tests; the declaration scan examined nothing"
        fi
        if [ "${declared:-0}" -gt 0 ] && [ "${executed}" -eq 0 ]; then
            fail "${package}" "${declared} tests are declared but none executed"
        fi
        # T-080: a shortfall fails (ZPDFDesignSystem keeps its documented exemption above).
        if [ "${declared:-0}" -gt 0 ] && [ "${executed}" -lt "${declared}" ]; then
            fail "${package}" "executed ${executed} of ${declared} declared tests (parameterised cases can explain a higher count, never a lower one)"
        fi
    fi
    if grep -rqE 'XCTSkip|\.disabled\(|#if[[:space:]]+false' "${dir}/Tests" 2>/dev/null; then
        fail "${package}" "a test is skipped or compiled out with #if false; a skipped test counts as failed here"
    fi

    # ZPDFDesignSystem's XCTest suite cannot compile without Xcode. Its equivalent assertions
    # run here instead, so the package is not silently unverified. See the header note.
    if [ "${package}" = "ZPDFDesignSystem" ]; then
        printf '\n=== %s : zpdf-design-audit (stands in for the XCTest suite) ===\n' "${package}"
        swift run zpdf-design-audit || fail "${package}" "zpdf-design-audit"
    fi

    record "$(printf '%-20s  PASS' "${package}")"
done

# --- Hosted hit targets (LT3-01, NL-MARKUP-01) -----------------------------------------------
#
# The package suites above run inside `xctest`, which is stamped with the current SDK and
# hit-tests the modern way. The shipped app is stamped with the macOS 14 SDK, and there SwiftUI
# leaves a nearly transparent hosted AppKit control out of hit-testing — which is how the
# Inspector's colour swatches shipped doing nothing when clicked, under a green suite. This step
# runs the opacity lint over every UI source and `zpdf-hit-probe`, a SwiftPM executable stamped
# like the app, which clicks the real Inspector off screen. See the script's header.
printf '\n=== hosted hit targets : verify-hosted-hit-targets.sh ===\n'
if [ ! -x "${ROOT}/Scripts/verify-hosted-hit-targets.sh" ]; then
    fail "hit targets" "Scripts/verify-hosted-hit-targets.sh is missing or not executable"
fi
"${ROOT}/Scripts/verify-hosted-hit-targets.sh" || fail "hit targets" "verify-hosted-hit-targets.sh (LT3-01 class)"
record "$(printf '%-20s  PASS' "hit targets")"

print_table
printf '\nAll %d UI packages built and tested, and their hosted hit targets verified.\n' "${#PACKAGES[@]}"
exit 0
