#!/bin/bash
#
# verify-no-uninjected-modals.sh — nothing in the application tier may run a dialogue
# outside `ZenitModalPresenter`.
#
# ## Why this gate exists
#
# On 2026-08-25 a person at the machine was interrupted by *"StampRotation.zpdfproj was not
# closed properly — There is unsaved work from the last session"*, with Recover / Open
# Read-Only / Discard. It was raised by a **test**: the test killed the application to arm the
# crash marker, and the reopen a few lines later ran `NSAlert.runModal()` with nobody there but
# that person. The fixture was in the right place. The modal was the leak.
#
# `build-app-package.sh` already fails a suite that **hangs** on a modal — that is its
# watchdog. It cannot see one a human dismisses, and that is the whole problem: a dialogue a
# human answers makes a test pass that would otherwise hang or fail, so the suite's result
# depends on who was watching. That is the same class of defect as a skipped test reported as
# green.
#
# ## What is an offence
#
# **Running** a dialogue, not building one. `ZenitJSONImport.makeOpenPanel()` constructs an
# `NSOpenPanel` so a test can assert its configuration without opening it; that is the pattern
# this repository wants and it is not flagged. What is flagged is the line that puts the thing
# in front of a person or spins a modal run loop:
#
#     .runModal()                       NSAlert / NSSavePanel / NSOpenPanel / NSApp
#     .beginSheetModal(                 alerts and file panels, sheeted
#     .beginSheet(                      a workflow sheet hung straight from its window
#                                       (`ZenitModalPresenter.beginSheet(` is the door, not
#                                       an offence)
#     runModalSavePanel(                AppKit's own, on NSDocument
#     runModalPrintOperation(           AppKit's own, on NSDocument
#     runModalOpenPanel(                AppKit's own, on NSDocumentController
#     .orderFrontRegardless(            a panel onto whatever screen is in front
#
# in any file under `Apps/ZenitPDF/Sources` other than `ZenitModalPresenter.swift`, and in any
# file at all under `Apps/ZenitPDF/Tests`.
#
# Three things are deliberately not offences, and the edges are drawn because an exemption is
# only honest if they are:
#
#   1. **Declarations.** `public override func runModalSavePanel(` is the override that
#      *diverts* the panel; flagging it would forbid the fix.
#   2. **`super.` forms** inside those overrides. They run only past a
#      `ZenitModalPresenter.canPresentModally` guard, which a test process never satisfies.
#   3. **A workflow sheet presented through `ZenitModalPresenter.beginSheet(`.** Workflow
#      sheets must go through that door: it records the request for the test that answers it,
#      and refuses to hang a sheet from a window a person can see when no person is there. A
#      direct `window.beginSheet(` skipped both, and eight review sheets did (R-039), so a
#      direct call is an offence everywhere but `ZenitModalPresenter.swift`, which is the one
#      caller the door itself needs. A sheet whose *content* is an alert or a file panel is
#      covered by `.beginSheetModal(` above, because AppKit presents those itself and escalates
#      them to an application-modal window when the parent is not visible.
#
# ## Proving it bites
#
# A gate nobody has seen fail is a gate nobody knows works (a gate that scans nothing must fail
# is the same lesson one step along). Add `_ = NSAlert().runModal()` to any file under Sources,
# run this script, watch it go red, and take it out again. This gate was proved that way when it
# was written.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF
fi

readonly SOURCES="${ROOT}/Apps/ZenitPDF/Sources"
readonly TESTS="${ROOT}/Apps/ZenitPDF/Tests"
readonly PRESENTER="ZenitModalPresenter.swift"

# Group A — forms nobody may run anywhere but the presenter. These draw on a screen or spin a
# modal run loop, and there is no legitimate second caller for any of them.
readonly RUN_PATTERN='(\.runModal\(|\.beginSheetModal\(|\.orderFrontRegardless\()'
# A sheet hung straight from its window (R-039). `ZenitModalPresenter.beginSheet(` is the door and
# is struck out of each line before the line is judged, so a line cannot hide a direct call
# behind a door call. `ModalInjectionTests.nothingRunsADialogueOutsideThePresenter` applies the
# same rule, the same way.
readonly SHEET_PATTERN='\.beginSheet\('

# Group B — AppKit's own document panels. These are not call sites we own: AppKit reaches them
# from Cmd-S, from File > Open, from saveDocumentAs: and from the autosave machinery, so the
# only place they can be stopped is an override on the class AppKit calls. The override is
# therefore allowed, and so is calling the overridden method *from the class that carries it* —
# which is exactly `ZenitPDFProjectDocument.runModalSavePanel(for:...)` calling itself. Every
# other file is an offender, and the two owning files are checked below for the diversion.
readonly APPKIT_PANEL_PATTERN='(runModalSavePanel\(|runModalPrintOperation\(|runModalOpenPanel\()'
# `ModalInjectionTests.swift` is on this list because it is the suite that *proves* the
# diversion: it calls each overridden method and asserts the panel was answered rather than
# opened. Group A still applies to it in full — it may not run a real dialogue — so the
# exemption is exactly "may call the method that refuses to present", which is the point.
readonly APPKIT_PANEL_OWNERS='(ZenitPDFProjectDocument|ZenitDocumentController|ModalInjectionTests)\.swift:'

status=0

# A comment hit is a line whose *content* starts with `//`, `///` or a block comment's `*`,
# after grep's `file:line:` prefix (U-100). The unanchored `:[[:space:]]*(///|//|\*)` also
# matched the `://` of any URL, so `panel.runModal() // see https://…` passed as a comment.
readonly COMMENT_HIT='^[^:]*:[0-9]+:[[:space:]]*(///|//|\*)'
# Self-check: the filter keeps a call with a URL on its line and drops a real comment.
if ! printf '/x/A.swift:7:        panel.runModal() // see https://x\n' | grep -vE "${COMMENT_HIT}" | grep -q runModal \
    || printf '/x/A.swift:8:    /// panel.runModal() is routed through the presenter\n' | grep -vqE "${COMMENT_HIT}"; then
    printf 'FAIL: the comment filter self-check (U-100).\n' >&2
    exit 1
fi

scan() {
    local root="$1" label="$2" exclude_presenter="$3"
    local hits appkit sheets
    hits="$(grep -rnE "${RUN_PATTERN}" --include='*.swift' "${root}" 2>/dev/null || true)"
    appkit="$(grep -rnE "${APPKIT_PANEL_PATTERN}" --include='*.swift' "${root}" 2>/dev/null \
        | grep -vE "${APPKIT_PANEL_OWNERS}" || true)"
    sheets="$(grep -rnE "${SHEET_PATTERN}" --include='*.swift' "${root}" 2>/dev/null \
        | awk '{ line = $0; gsub(/ZenitModalPresenter\.beginSheet\(/, "", line); if (line ~ /\.beginSheet\(/) print $0 }' \
        || true)"
    hits="$(printf '%s\n%s\n%s\n' "${hits}" "${appkit}" "${sheets}")"
    if [ "${exclude_presenter}" = "yes" ]; then
        hits="$(printf '%s\n' "${hits}" | grep -v "/${PRESENTER}:" || true)"
    fi
    # Comments are documentation, not calls; `super.` and `func` forms are the diversion
    # itself and would make the fix illegal.
    hits="$(printf '%s\n' "${hits}" \
        | grep -vE "${COMMENT_HIT}" \
        | grep -vE '(func|super\.)[[:space:]]*[A-Za-z]*[Rr]unModal' \
        | grep -vE '^[[:space:]]*$' || true)"
    if [ -n "${hits}" ]; then
        printf 'FAIL: %s runs a dialogue outside ZenitModalPresenter.\n' "${label}" >&2
        printf '      A dialogue a person answers makes a test pass that would otherwise hang.\n' >&2
        printf '%s\n' "${hits}" >&2
        status=1
    fi
}

# The two classes AppKit calls directly must actually divert, or group B's exemption is a hole.
require_diversion() {
    local file="$1" method="$2"
    if ! grep -q "override func ${method}" "${file}" 2>/dev/null; then
        printf 'FAIL: %s no longer overrides %s, so AppKit can run that panel in a test.\n' \
            "$(basename "${file}")" "${method}" >&2
        status=1
        return
    fi
    if ! grep -q 'ZenitModalPresenter.canPresentModally' "${file}" 2>/dev/null; then
        printf 'FAIL: %s overrides %s without the canPresentModally diversion.\n' \
            "$(basename "${file}")" "${method}" >&2
        status=1
    fi
}

printf '=== application tier : no dialogue outside ZenitModalPresenter ===\n'

# The standing rule: a gate that scans zero items must fail.
# Raised 2026-08-26 from 20 and 20 — both roughly a third of the truth, and a floor
# at a third cannot see two thirds of the application tier vanish. Measured that day: 54 source
# files and 53 test files (51 before two later suites).
readonly MIN_SOURCE_FILES=54
readonly MIN_TEST_FILES=53
source_files="$(find "${SOURCES}" -name '*.swift' | wc -l | tr -d ' ')"
test_files="$(find "${TESTS}" -name '*.swift' | wc -l | tr -d ' ')"
if [ "${source_files:-0}" -lt "${MIN_SOURCE_FILES}" ] || [ "${test_files:-0}" -lt "${MIN_TEST_FILES}" ]; then
    printf 'FAIL: the scan examined %s source and %s test files (floors %s and %s); a gate that\n' \
        "${source_files}" "${test_files}" "${MIN_SOURCE_FILES}" "${MIN_TEST_FILES}" >&2
    printf '      scans less than it did last time has lost files, not gained a quieter green.\n' >&2
    exit 1
fi

# The presenter itself must exist, or the whole rule is a comment.
if [ ! -f "${SOURCES}/ZenitPDFAppKit/App/${PRESENTER}" ]; then
    printf 'FAIL: %s is gone, so nothing routes the application tier'"'"'s dialogues.\n' "${PRESENTER}" >&2
    exit 1
fi

scan "${SOURCES}" "the shipping application" yes
scan "${TESTS}" "an application-tier test" no

readonly DOCUMENT="${SOURCES}/ZenitPDFAppKit/Document/ZenitPDFProjectDocument.swift"
readonly CONTROLLER="${SOURCES}/ZenitPDFAppKit/Document/ZenitDocumentController.swift"
require_diversion "${DOCUMENT}" "runModalSavePanel"
require_diversion "${DOCUMENT}" "runModalPrintOperation"
require_diversion "${CONTROLLER}" "runModalOpenPanel"

# The seam is a *test* seam. An application that assigns it has a second behaviour rather than
# an injection point — the same rule `SearchAndOCRWiringTests.recoveryPromptOverrideIsTestOnly`
# already applies to the recovery prompt.
seam_offenders="$(grep -rnE 'ZenitModalPresenter\.handler[[:space:]]*=[^=]' --include='*.swift' "${SOURCES}" 2>/dev/null \
    | grep -v "/${PRESENTER}:" || true)"
if [ -n "${seam_offenders}" ]; then
    printf 'FAIL: the shipping application assigns the modal test seam.\n' >&2
    printf '%s\n' "${seam_offenders}" >&2
    status=1
fi

if [ "${status}" -ne 0 ]; then
    printf '\nFAILED: uninjected modal presentation in the application tier.\n' >&2
    exit 1
fi

printf 'no dialogue is run outside ZenitModalPresenter in %s source and %s test files.\n' \
    "${source_files}" "${test_files}"
exit 0
