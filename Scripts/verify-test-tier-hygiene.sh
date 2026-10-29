#!/bin/bash
#
# verify-test-tier-hygiene.sh — the test tier's own shared state, over the WHOLE repository.
#
# ## Why this exists
#
# Five gate unreliabilities in this repository have been decided by something other than the
# code under test, and every one of them was a process-wide or machine-wide resource that a
# *test* reached:
#
#   * `NSDocumentController.shared`, one object for the whole test process.
#   * A launch marker left on disk.
#   * A first-open write that marked a fresh drawing edited.
#   * `{"myTools":"apply"}` written into a REAL preference file on the machine, where it
#     survived every process and reddened `build-app-package.sh` three times
#     *deterministically*. Three identical runs agreeing with each other is not evidence when
#     the thing deciding the result lives outside the tree.
#   * `NSCursor.arrow`, an AppKit global that does not exist until something asks for
#     `NSApplication.shared`. The state need not be anything anybody wrote.
#
# `SharedTestStateTests` turned that class into eight tests — and **found a blind spot in
# itself**. It scans one directory, `Apps/ZenitPDF/Tests`, and the class lives in every test
# tier. Its own gate sweep created three `zenit-author-tests-<UUID>.plist` files from a
# `ZPDFAppCore` test it cannot see, and 24 more appeared from `ZPDFUIShell` during the repair
# runs: 2 594 → 2 634 preference files in eleven minutes. It also counted only `zenit`-prefixed
# names, so 26 `zpdf-update-tests-<UUID>.plist` files (from a package since removed) were
# invisible to the count as well as to the scan.
#
# This script is the widening. Two halves:
#
#   1. **A static scan of every test target in the repository** — `Apps/*/Tests`,
#      `Packages/*/Tests`, `Bridges/*/Tests`, `Tests/*/Tests` and `Tools/*/Tests` (the `zenit`
#      CLI's, since T-087). Written in shell, deliberately
#      independent of the Swift audit it duplicates, so that a test tier which fails to *compile*
#      cannot take its own auditor down with it.
#
#   2. **A preference-file census across a real suite run** — the assertion that suite could only make
#      by hand. List the test-prefixed plists in `~/Library/Preferences`, run every test target
#      that touches `UserDefaults`, list again, and require that nothing was removed and nothing
#      was added except a fixed scratch prefix's one file on its first use on this machine. This is
#      the half that cannot be faked by reading source: `cfprefsd` owns a named domain the moment
#      it is asked for one, writes the file whether or not a key is stored, and rewrites it after
#      any attempt to delete it. The only fix that works is a fixed suite name per prefix, and
#      the only proof that it works is the count.
#
# ## Usage
#
#     Scripts/verify-test-tier-hygiene.sh              # static scan + census (runs the suites)
#     Scripts/verify-test-tier-hygiene.sh --scan-only  # static scan only, no build, ~1 s
#
# Exit 0 only when both halves pass. Read the log, not the exit code.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Tests Packages Apps Bridges
fi

SCAN_ONLY=0
if [ "${1:-}" = "--scan-only" ]; then
    SCAN_ONLY=1
fi

FAILURES=0
note()  { printf '%s\n' "$*"; }
bad()   { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# ---------------------------------------------------------------------------------------------
# The test targets. A scan that scans nothing must fail, so the count is asserted.
# ---------------------------------------------------------------------------------------------
cd "${ROOT}" || exit 2
TEST_DIRS=()
while IFS= read -r line; do
    [ -n "${line}" ] && TEST_DIRS+=("${line}")
done < <(ls -d Apps/*/Tests Packages/*/Tests Bridges/*/Tests Tests/*/Tests Tools/*/Tests 2>/dev/null)

# Raised 2026-08-26 from 25 — four targets below the truth, and a floor below the
# truth cannot see a target that disappears. Measured on that run: 29.
readonly EXPECTED_MINIMUM_TARGETS=29
note "=== test targets scanned: ${#TEST_DIRS[@]} ==="
if [ "${#TEST_DIRS[@]}" -lt "${EXPECTED_MINIMUM_TARGETS}" ]; then
    bad "only ${#TEST_DIRS[@]} test target directories found; the scan proves nothing below ${EXPECTED_MINIMUM_TARGETS}"
fi

# A grep over every test target that ignores comment lines. Prints "path:line: text".
scan() {
    # scan <extended-regexp>
    grep -rnE --include='*.swift' "$1" "${TEST_DIRS[@]}" 2>/dev/null \
        | grep -vE '^[^:]*:[0-9]+: *(///|//|\*)'
}

# A rule: name, regexp, explanation, and the files allowed to match it (they are the auditors).
rule() {
    # rule <name> <regexp> <why> [allow-substring ...]
    local name="$1" pattern="$2" why="$3"
    shift 3
    local hits
    hits="$(scan "${pattern}")"
    local allow
    for allow in "$@"; do
        hits="$(printf '%s\n' "${hits}" | grep -v -- "${allow}")"
    done
    hits="$(printf '%s\n' "${hits}" | grep -v '^$')"
    if [ -n "${hits}" ]; then
        bad "${name} — ${why}"
        printf '%s\n' "${hits}" | sed 's/^/        /' >&2
    else
        note "  ok  ${name}"
    fi
}

note ''
note '=== 1. static scan, every test target in the repository ==='

# The `myTools` defect exactly, and the fallback that is a write waiting to happen.
rule "no scratch suite falls back to the real defaults" \
     '\?\? *\.standard' \
     "a suite name that cannot be created must be a failure, never UserDefaults.standard" \
     "SharedTestStateTests.swift" "ShellScratchDefaults.swift" "RepositoryTestTierAuditTests.swift"

rule "no test writes the real UserDefaults" \
     'UserDefaults\.standard.*\.(set|removeObject|removePersistentDomain)\(|defaults: *\.standard' \
     "the standard domain is the user's real preferences" \
     "SharedTestStateTests.swift" "RepositoryTestTierAuditTests.swift"

# One plist per test per run is how a development machine's Preferences folder reached 2 634.
rule "no defaults suite name carries a UUID" \
     'UserDefaults\(suiteName:.*UUID\(\)|suiteName *= *"[^"]*\\\(UUID\(\)' \
     "cfprefsd writes a plist per named domain and rewrites it after any delete; use one fixed name per prefix" \
     "RepositoryTestTierAuditTests.swift"

rule "no test writes the general pasteboard" \
     'NSPasteboard\.general.*\.(clearContents|setData|setString|setPropertyList|writeObjects)\(' \
     "NSPasteboard.general is the user's clipboard, not a test fixture" \
     "SharedTestStateTests.swift" "RepositoryTestTierAuditTests.swift"

rule "no test opens anything through NSWorkspace" \
     'NSWorkspace\.shared\.(open|launchApplication|selectFile)' \
     "that puts an application on the user's screen" \
     "SharedTestStateTests.swift" "RepositoryTestTierAuditTests.swift"

rule "no test writes into the user's home" \
     '(NSHomeDirectory\(\)|\.desktopDirectory|\.downloadsDirectory|\.documentDirectory|\.applicationSupportDirectory)' \
     "a fixture belongs in FileManager.default.temporaryDirectory" \
     "SharedTestStateTests.swift" "AppTestSupport.swift" "ShellScratchDefaults.swift" \
     "RepositoryTestTierAuditTests.swift"

# ---------------------------------------------------------------------------------------------
# 2. Every test target that reaches AppKit's lazily-created globals must serialise itself.
#
# `NSCursor.arrow` is empty until something asks for `NSApplication.shared`, and in a full
# run that "something" is whichever of your own tests happened to make a window first. A target
# with more than one concurrent @MainActor suite and any of these references inherits that race.
# ---------------------------------------------------------------------------------------------
note ''
note '=== 2. AppKit process-global state: serialisation ==='
for dir in "${TEST_DIRS[@]}"; do
    appkit="$(grep -rlE --include='*.swift' 'NSCursor\.|NSApplication\.shared|NSWindow\(' "${dir}" 2>/dev/null | wc -l | tr -d ' ')"
    [ "${appkit}" = "0" ] && continue
    suites="$(grep -rhcE --include='*.swift' '^@Suite' "${dir}" 2>/dev/null | awk '{t+=$1} END {print t+0}')"
    gate="$(ls "${dir}"/*/*SerialGate.swift 2>/dev/null | wc -l | tr -d ' ')"
    unserialised="$(grep -rhE --include='*.swift' '^@Suite' "${dir}" 2>/dev/null \
        | grep -vcE 'TierSerialised' | tr -d ' ')"
    if [ "${gate}" = "0" ] || [ "${unserialised}" != "0" ]; then
        bad "${dir} touches AppKit process globals in ${suites} suites, ${unserialised} of them not serialised (gate files: ${gate})"
    else
        note "  ok  ${dir}: ${suites} suites, all serialised"
    fi
done

# ---------------------------------------------------------------------------------------------
# 2b. The census list against the targets that name a defaults suite (T-087).
#
# Every package whose tests name a UserDefaults suite is run by the census below. Derived, not
# remembered: the list is checked against what the scan finds, so a new test target that names a
# suite fails here — in the static half, which runs in --scan-only too — instead of being left out
# of the census while the gate stays green. The comment used to say so while the list was only
# printed.
# ---------------------------------------------------------------------------------------------
CENSUS_PACKAGES=(
    "Packages/ZPDFAppCore"
    "Packages/ZPDFUIShell"
)
# Run separately by the census, after the packages: the expensive tier.
readonly CENSUS_APP="Apps/ZenitPDF"
DEFAULTS_USERS="$(grep -rlE --include='*.swift' 'UserDefaults\(suiteName' "${TEST_DIRS[@]}" 2>/dev/null \
    | sed -E 's|/Tests/.*||' | sort -u)"
note ''
note '=== 2b. the census covers every target that names a defaults suite ==='
while IFS= read -r user; do
    [ -n "${user}" ] || continue
    covered=0
    for package in "${CENSUS_PACKAGES[@]}" "${CENSUS_APP}"; do
        [ "${user}" = "${package}" ] && covered=1
    done
    if [ "${covered}" = "1" ]; then
        note "  ok  ${user}"
    else
        bad "${user} names a UserDefaults suite in its tests and is not in CENSUS_PACKAGES; the census below would not run it (T-087)"
    fi
done <<< "${DEFAULTS_USERS}"

if [ "${SCAN_ONLY}" = "1" ]; then
    note ''
    if [ "${FAILURES}" = "0" ]; then
        note "PASS (scan only): ${#TEST_DIRS[@]} test targets, no shared-state offender."
        exit 0
    fi
    printf 'FAILED: %s static rule(s) broken.\n' "${FAILURES}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------------------------
# 3. The census. The assertion `SharedTestStateTests` could only make by hand.
# ---------------------------------------------------------------------------------------------
# The app suite below reads the licence notices of build/Zenit PDF.app, so check up front, as
# `build-app-package.sh` does, that the bundle exists and carries the current notices.
ASSEMBLED_LICENCES="${ROOT}/build/Zenit PDF.app/Contents/Resources/Licenses"
if ! diff -rq "${ROOT}/Apps/ZenitPDF/Bundle/Licenses" "${ASSEMBLED_LICENCES}" >/dev/null 2>&1; then
    printf 'FAIL: build/Zenit PDF.app is missing or predates the licence notices in Apps/ZenitPDF/Bundle/Licenses;\n' >&2
    printf '      run Scripts/build-app.sh first, because the app suite reads the bundle.\n' >&2
    exit 1
fi

readonly PREFS="${HOME}/Library/Preferences"

census() {
    ls "${PREFS}" 2>/dev/null | grep -icE '^(zenit|zpdf).*\.plist$' | tr -d ' '
}

manifest() {
    ls "${PREFS}" 2>/dev/null | grep -iE '^(zenit|zpdf).*\.plist$' | sort
}

note ''
note '=== 3. preference-file census across a real suite run ==='

DEV="$(xcode-select -p 2>/dev/null || true)"
FW=""
LIB=""
# Full Xcode keeps the framework in its macOS platform; the Command Line Tools keep it at the top
# level. Same search as Scripts/build-ui-packages.sh.
if [ -n "${DEV}" ] && [ -d "${DEV}/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework" ]; then
    FW="${DEV}/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    LIB="${DEV}/Platforms/MacOSX.platform/Developer/usr/lib"
elif [ -n "${DEV}" ] && [ -d "${DEV}/Library/Developer/Frameworks/Testing.framework" ]; then
    FW="${DEV}/Library/Developer/Frameworks"
    LIB="${DEV}/Library/Developer/usr/lib"
elif [ -d "/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework" ]; then
    FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
    LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
fi
if [ -z "${FW}" ]; then
    printf 'FAIL: no Testing.framework; refusing to report a green it did not verify.\n' >&2
    exit 1
fi
TEST_FLAGS=(
    -Xswiftc -F -Xswiftc "${FW}"
    -Xlinker -F -Xlinker "${FW}"
    -Xlinker -rpath -Xlinker "${FW}"
    -Xlinker -rpath -Xlinker "${LIB}"
)

# CENSUS_PACKAGES and the targets naming a defaults suite were checked against each other in
# step 2b; a target the list misses has already failed the run.
note "test targets naming a defaults suite:"
printf '%s\n' "${DEFAULTS_USERS}" | sed 's/^/    /'

# ---------------------------------------------------------------------------------------------
# The *other* real preference domain, and the one no source scan can see.
#
# `swiftpm-testing-helper` is `UserDefaults.standard` for every `swift test` process on this
# machine. A test that constructs the shipping window controller writes product state into it
# without ever naming `UserDefaults` — the write goes through `ProjectWindowLayoutStore()`,
# whose `defaults:` parameter defaults to `UserDefaults.standard`. That is the `myTools`
# mechanism above exactly (a product key in a real preference domain, outside the tree, surviving
# every process) reached by a path every text rule above is blind to.
#
# Measured 2026-08-26: one run of the application tier changes `Zenit.ProjectWindow.LayoutState`
# every time; one run of `ZPDFUIShell` and one of `ZPDFAppCore` leave the whole domain
# byte-identical. So this is not a warning about a hypothetical.
#
# It is a **register, not a red gate**, on the pattern `verify-hook-wiring.sh` uses: the known
# writer is named with its cost, a change confined to registered keys prints and does not fail,
# and any *unregistered* key that appears or moves fails the run. Closing it needs a seam in
# `Apps/ZenitPDF/Sources` — product code — so it cannot be closed from the test tier, and a gate
# that is red for something the test tier may not fix is a gate people learn to bypass.
readonly REGISTERED_HELPER_KEYS=(
    "Zenit.ProjectWindow.LayoutState"
    "NSWindow Frame Zenit.ProjectWindow.Frame"
    "NSToolbar Configuration Zenit.ProjectWindow.Toolbar"
    "NSToolbar Configuration Zenit.ProjectWindow.Toolbar.v2"
    "NSToolbar Configuration Zenit.ProjectWindow.Toolbar.v3"
    "NSSplitView Subview Frames Zenit.ProjectWindow.OuterSplit"
    "NSSplitView Subview Frames Zenit.ProjectWindow.ContentSplit"
)

# One "<md5>  <key>" line per top-level key of the standard domain of the test process.
helper_domain() {
    defaults export swiftpm-testing-helper - 2>/dev/null | python3 -c '
import hashlib, plistlib, sys
raw = sys.stdin.buffer.read()
try:
    d = plistlib.loads(raw)
except Exception:
    d = {}
for key in sorted(d):
    blob = plistlib.dumps({"v": d[key]}, fmt=plistlib.FMT_BINARY)
    print(hashlib.md5(blob).hexdigest(), key, sep="  ")
'
}

HELPER_BEFORE="$(mktemp)"
HELPER_AFTER="$(mktemp)"
helper_domain > "${HELPER_BEFORE}"
note "standard domain of the test process (swiftpm-testing-helper): $(wc -l < "${HELPER_BEFORE}" | tr -d ' ') top-level keys"

BEFORE_LIST="$(mktemp)"
AFTER_LIST="$(mktemp)"
manifest > "${BEFORE_LIST}"
BEFORE="$(census)"
note "census before: ${BEFORE} zenit*/zpdf* plists in ${PREFS}"

for package in "${CENSUS_PACKAGES[@]}"; do
    note ''
    note "--- ${package}: swift test ---"
    (
        cd "${ROOT}/${package}" || exit 2
        swift build --build-tests "${TEST_FLAGS[@]}" >/dev/null 2>&1 || exit 3
        # Keep the lines that name a failing test, not only the summary: a red run whose issues are not named
        # cannot be fixed (I-7).
        swift test "${TEST_FLAGS[@]}" 2>&1 | grep -E 'recorded an issue|✘ Test "|✘ Test run|✔ Test run' | tail -40
        exit "${PIPESTATUS[0]}"
    )
    rc=$?
    if [ "${rc}" != "0" ]; then
        bad "${package} did not pass; a census over a red suite proves nothing (rc=${rc})"
    fi
done

# The app tier is the one that already had the audit, and it is the expensive one; run it too,
# because a census that skips the biggest suite is a census of the quiet tiers.
note ''
note "--- ${CENSUS_APP}: swift test ---"
(
    cd "${ROOT}/${CENSUS_APP}" || exit 2
    swift build --build-tests "${TEST_FLAGS[@]}" >/dev/null 2>&1 || exit 3
    swift test "${TEST_FLAGS[@]}" 2>&1 | grep -E 'recorded an issue|✘ Test "|✘ Test run|✔ Test run' | tail -40
    exit "${PIPESTATUS[0]}"
)
rc=$?
[ "${rc}" = "0" ] || bad "${CENSUS_APP} did not pass; a census over a red suite proves nothing (rc=${rc})"

sleep 2   # cfprefsd writes lazily; give it the chance to add a file before claiming none appeared.
manifest > "${AFTER_LIST}"
AFTER="$(census)"
note ''
note "census after:  ${AFTER} zenit*/zpdf* plists in ${PREFS}"

# A fixed-prefix scratch suite writes its one `<prefix>.scratch.plist` the first time that prefix
# is ever used on a machine, by design (see ScratchDefaults and ShellScratchDefaults). On a machine
# that has never run the suites those files appear during this census, so a new file is accepted
# when its prefix is a literal in the test sources. Anything else that appears, and anything that
# disappears, fails the gate.
ADDED="$(comm -13 "${BEFORE_LIST}" "${AFTER_LIST}")"
REMOVED="$(comm -23 "${BEFORE_LIST}" "${AFTER_LIST}")"
FIRST_USE=""
LEAKED=""
while IFS= read -r name; do
    [ -n "${name}" ] || continue
    prefix="${name%.scratch.plist}"
    if [ "${prefix}" != "${name}" ] && (cd "${ROOT}" && grep -rqF -e "\"${prefix}\"" -e "\"${prefix}.scratch\"" "${TEST_DIRS[@]}" 2>/dev/null); then
        FIRST_USE="${FIRST_USE}${name}"$'\n'
    else
        LEAKED="${LEAKED}${name}"$'\n'
    fi
done <<< "${ADDED}"

if [ -n "${LEAKED}" ]; then
    bad "the suite run added $(printf '%s' "${LEAKED}" | grep -c .) preference file(s) to this machine that no fixed scratch prefix explains"
    printf '%s' "${LEAKED}" | sed 's/^/        /' >&2
fi
if [ -n "${REMOVED}" ]; then
    bad "the suite run removed $(printf '%s\n' "${REMOVED}" | grep -c .) preference file(s) from this machine"
    printf '%s\n' "${REMOVED}" | sed 's/^/        /' >&2
fi
if [ -n "${FIRST_USE}" ]; then
    note "  note  first use of $(printf '%s' "${FIRST_USE}" | grep -c .) fixed scratch prefix(es) on this machine (one file each, ever):"
    printf '%s' "${FIRST_USE}" | sed 's/^/        /'
fi
if [ -z "${LEAKED}" ] && [ -z "${REMOVED}" ]; then
    if [ "${AFTER}" = "${BEFORE}" ]; then
        note "  ok  the count is unchanged across a full run of every defaults-touching test target."
    else
        note "  ok  every new file is a fixed scratch prefix's one file; nothing else was added or removed."
    fi
fi
rm -f "${BEFORE_LIST}" "${AFTER_LIST}"

# --- 4. the standard domain of the test process ----------------------------------------------
note ''
note '=== 4. the standard domain of the test process (swiftpm-testing-helper) ==='
helper_domain > "${HELPER_AFTER}"
MOVED="$(comm -13 <(sort "${HELPER_BEFORE}") <(sort "${HELPER_AFTER}") | sed 's/^[0-9a-f]*  //' | sort -u)"
if [ -z "${MOVED}" ]; then
    note "  ok  no key in the test process's real defaults moved."
else
    while IFS= read -r key; do
        [ -n "${key}" ] || continue
        registered=0
        # `ZENIT_HYGIENE_EMPTY_REGISTER=1` empties the register for one run. It exists so this
        # branch can be *seen* to fail — "a gate nobody has seen fail is a gate nobody knows
        # works" — and it can only ever make the gate stricter, never quieter, so it cannot be
        # used to silence a finding.
        if [ "${ZENIT_HYGIENE_EMPTY_REGISTER:-0}" != "1" ]; then
            for known in "${REGISTERED_HELPER_KEYS[@]}"; do
                [ "${key}" = "${known}" ] && registered=1 && break
            done
        fi
        if [ "${registered}" = "1" ]; then
            printf '  REGISTERED  %s moved.\n' "${key}"
        else
            bad "an unregistered key moved in the test process's real defaults: '${key}' — a product key in a real preference domain, which no source scan can see"
        fi
    done <<< "${MOVED}"
    note ''
    note '  Live-defect register (not a failure, and not fixable from the test tier):'
    note '    Apps/ZenitPDF/Sources/ZenitPDFAppKit/Window/ProjectWindowController.swift:387 builds'
    note '    ProjectWindowLayoutController with the default ProjectWindowLayoutStore(), whose'
    note '    `defaults:` parameter defaults to UserDefaults.standard. Every application-tier test'
    note '    that opens a project window therefore reads and writes the product key'
    note '    Zenit.ProjectWindow.LayoutState in this domain, plus AppKit`s own window, toolbar and'
    note '    split-view autosaves. Cost today: a run can be decided by what the previous run left.'
    note '    Closing it needs a layout-store seam in the application tier — product code.'
fi
rm -f "${HELPER_BEFORE}" "${HELPER_AFTER}"

note ''
if [ "${FAILURES}" = "0" ]; then
    note "PASS: ${#TEST_DIRS[@]} test targets scanned; ${BEFORE} preference files before and ${AFTER} after a full run of every defaults-touching suite ($(printf '%s' "${FIRST_USE}" | grep -c .) first-use scratch file(s) accepted)."
    exit 0
fi
printf 'FAILED: %s rule(s) broken.\n' "${FAILURES}" >&2
exit 1
