#!/bin/bash
#
# verify-hook-wiring.sh — fail when a hook declared in the shell/presenter layer has no
# assignment anywhere that can see it.
#
# ---------------------------------------------------------------------------------------------
# Why this exists
# ---------------------------------------------------------------------------------------------
# The same disease has now been found three times in this repository, in three disguises, and
# each time it was found by a human grepping rather than by a gate:
#
#   1. Engines with no caller.       Twelve capabilities were built, tested and green in their
#                                    own packages, and nothing in Apps/ ever reached them
#                                    (fixed when the application was wired to them).
#   2. Mocks in a shipping path.     A mock presenter was constructed by the application itself,
#                                    so the product answered searches with fabricated hits.
#                                    `SearchAndOCRWiringTests` now gates that one.
#   3. Hooks nobody assigns.         A `public var onSomething: (…) -> Void)?` that the declaring
#                                    type *calls* and nothing ever *installs*. The call site is
#                                    `hook?(…)`, so the compiler is satisfied, every package test
#                                    passes, and at runtime the feature is a no-op.
#
# Form 3 is the one this gate closes, and it is not hypothetical. `AppCanvasPresenter.onScrollTo`
# was called from `ZenitPDFProjectDocument` to reveal a page-text search hit and was assigned by
# nobody: search jumped to the right page and never scrolled to the word. A markup hit took a
# different branch and worked, which is exactly why the suite stayed green over it
#.
#
# ---------------------------------------------------------------------------------------------
# What counts as a hook, and what counts as wiring it
# ---------------------------------------------------------------------------------------------
# A HOOK is a `public var on<Something>` whose declared type is a closure — the outward edge of a
# presenter, model or controller in `Packages/*/Sources`. Non-closure properties that merely
# start with "on" (`GeometryEpsilon.onSegment`) are not hooks, and neither is a protocol
# requirement (`{ get set }`), which is a shape, not storage.
#
# An ASSIGNMENT is a line assigning to that name in any Swift source under `Packages/*/Sources`,
# `Apps/*/Sources` or `Bridges/*/Sources` — the shipping tiers. Tests are deliberately excluded:
# a hook that only a test assigns is exactly the defect being hunted.
#
# Attribution is the hard half, because names repeat: eight types declare an `onChange` or an
# `onSelectionChange`. A bare name match reports `ToolLibraryEditingModel.onChange` as wired
# because some *other* type's `onChange` is assigned somewhere, which is the false negative that
# once let a dead hook through. So an assignment only counts for a hook when the assigning file can actually
# see the declaring module: it is in that module, or it imports it. That rule is what separates
# a hook whose only same-named assignment sits in a module that cannot see it (dead — an
# `onResolve =` in a module that does not import ZPDFUIWorkflows says nothing about a
# ZPDFUIWorkflows hook called `onResolve`) from `AppMeasurementToolPresenter.onCommitBoundary`
# (wired, from ZenitPDFAppKit, which imports ZPDFAppCore).
#
# Within one module the same trick is played on the receiver: `model.onChange = …` where the file
# declares `let model = ToolLibraryEditingModel(…)` is not an assignment to `SearchRecentQueries`,
# which declares an `onChange` in the same module. Only a *plain* receiver is read this way —
# `core.canvas.onScrollTo` gives up nothing, because `canvas` there is a property of `core` and a
# file may hold a local of that name and another type. An unreadable receiver always keeps the
# assignment: this refinement may rule a line out, never rule one in.
#
# When a hook is reported dead but its bare name *is* assigned somewhere one of those two rules
# excluded, that site is printed under the offender — **with the type that assignment actually
# lands on**, not just the shared name. This is the half the hand-grep got wrong three times:
# `grep -rn onSaveLayoutRequested` and `grep -rn onResolve` both read as wired, and the answers are
# `LedgerTableController.onSaveLayoutRequested` (a different type in the same module) and
# `ScaleRegionCrossingSheet.onResolve` (a different type in a module that cannot see the
# declaration). A near-miss line that names only the file and the bare name misleads the next
# person exactly the way it misled the last one, so every one of them names both types and both
# modules. A false positive is therefore visible in the gate's own output rather than something to
# be argued about.
#
# The limit worth stating: two types in one module sharing a hook name, where every assignment's
# receiver is unreadable, still hide each other. The gate under-reports there; it does not
# over-report, which is the direction that matters for a gate people have to trust.
#
# ---------------------------------------------------------------------------------------------
# Two lists, and they mean opposite things
# ---------------------------------------------------------------------------------------------
# The 2026-08-25 triage of the twelve offenders this gate found on its first run split them into
# two kinds, and one list for both kinds would have been a lie in one direction or the other.
#
# ALLOW_LIST — the hook is *not* a defect. Either the host it was published for does not exist
# (a presenter that nothing outside its own previews constructs), or the shell reaches the same
# outcome another way (`ZenitToolbarModel.onToolChange`, superseded by `onSelectionChange`).
# Nobody is losing anything today. `Module.Type.hook|reason`, and the reason is not optional — an allow-list
# without reasons becomes a place to hide findings, which is how this pattern survived twice.
#
# DEFECT_REGISTER — the hook *is* a live defect: a control a person can reach, in a surface the
# shipping application presents, whose effect is nothing. Allow-listing one of these would be the
# gate lying, so they get their own list, printed under a heading that calls them defects, with
# the user-visible symptom and a gap reference on every line. The gate does not fail on them,
# because they predate it and a permanently red gate teaches people to ignore gates — but it
# never lets them go quiet either: they are re-printed, re-counted, and named in the verdict of
# every single run.
#
# Both lists are checked the same two ways. An entry that is no longer an offender fails the gate
# — a stale entry is how a real regression later hides behind a reason nobody re-read, and it is
# what made this gate's own first run red. An entry in both lists fails too: a
# defect that is also excused is neither.
#
# The register additionally carries its own size. Growing it therefore takes two edits in one
# diff — the line, and the number — so no change can quietly park a new defect in it. Shrinking it
# takes the same two, which is the point: the number is the score.
#
# Usage:  Scripts/verify-hook-wiring.sh [--list | --print-register]
#         --list            print every offender and exit 0 without judging (for a report)
#         --print-register  print the live-defect register as `hook<TAB>note`, and exit 0
#
# Exit 0 = every hook in the shell/presenter layer is assigned, allow-listed with a reason, or
#          registered as a known live defect with a gap reference; every entry in both lists is
#          still an offender; and the register is the size it says it is.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LIST_ONLY=0
PRINT_REGISTER=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --print-register) PRINT_REGISTER=1; shift ;;
        -h|--help) sed -n '2,100p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'verify-hook-wiring.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
done
readonly LIST_ONLY
readonly PRINT_REGISTER

# ---------------------------------------------------------------------------------------------
# The allow-list: hooks that are dead and are not a defect.
# `Module.Type.hook|one-line reason`. Nothing else is accepted.
# ---------------------------------------------------------------------------------------------
readonly ALLOW_LIST="\
ZPDFUIShell.ZenitToolbarModel.onToolChange|superseded by onSelectionChange, which carries the tool plus its parameters; the narrower hook is kept for a host that only wants the identifier"
# Removed 2026-09-26 (R-128 and R-124), when the hosts' types were deleted as
# dead code rather than wired — the gate reported each entry stale, which is the point of it:
#   ZPDFUIWorkflows.ZPDFErrorPresenter.onResolve      (ZPDFErrorPresenter.swift deleted; failures
#                                                      reach people through ZenitErrorPresenter)
#   ZPDFUILedger.LedgerSelectionCoordinator.onJump    (coordinator and LedgerMarkupJump removed
#   ZPDFUILedger.LedgerSelectionCoordinator.onSelectionChanged   from LedgerSelectionSync.swift)
# Removed 2026-09-23 (NL-UX-13), when the onboarding flow got its host (UX/ZenitOnboardingController.swift):
#   ZPDFUIWorkflows.OnboardingModel.onPerformStep
# Removed 2026-08-25, when Revision Overlay got its compositor:
#   ZPDFUIWorkflows.RevisionOverlayModel.onAlignmentChange
#   ZPDFUIWorkflows.RevisionOverlayModel.onLayersChange
# Both are now assigned by RevisionOverlayCompositing.attach() in Apps/ZenitPDF, and the third
# hook on that model, onRecomposite, is assigned there too. An allow-list entry that is no
# longer an offender is how a real regression later hides behind a reason nobody re-read
#, so the entries go rather than being edited into something vaguer.

# ---------------------------------------------------------------------------------------------
# The live-defect register: hooks that are dead AND cost a person something today.
# `Module.Type.hook|gap reference — the control they use and what fails to happen`.
# Growing this list means also raising DEFECT_REGISTER_SIZE, in the same diff.
# ---------------------------------------------------------------------------------------------
# EMPTY as of 2026-08-26. All five entries were wired in one pass and each was
# re-derived by this gate, not by hand — the run above printed "defect register entry that is
# now wired" for every one of them before the lines were deleted:
#
#   ZPDFAppCore.AppComparePresenter.onPromoteDiff
#       Apps/ZenitPDF/Sources/ZenitPDFAppKit/Document/ZenitPDFProjectDocument.swift:736
#       Accept / Accept All now build a revision cloud over the difference's page bounds and
#       send it through the command bus, so promoting is one undoable step like any markup.
#   ZPDFUIWorkflows.RevisionCompareModel.onSettingsChange
#       Apps/ZenitPDF/Sources/ZenitPDFAppKit/Window/ProjectWindowController.swift:1927
#       the tolerance slider sets the presenter's detection settings and re-runs detection,
#       and the run is recorded so the review can render a verdict again.
#   ZPDFUIWorkflows.RevisionCompareModel.onFocusDifference
#       Apps/ZenitPDF/Sources/ZenitPDFAppKit/Window/ProjectWindowController.swift:1935
#       clicking a difference, and Next/Previous, now reveal it on the canvas.
#   ZPDFUILedger.LedgerTableHost.onSaveLayoutRequested
#       Packages/ZPDFUIShell/Sources/ZPDFUIShell/Ledger/LedgerPaneModel.swift:145
#       Save Layout… opens the naming prompt, and the layout is written to the pane's
#       preferences so the header menu's Apply Layout list can finally be non-empty.
#   ZPDFUIWorkflows.ToolLibraryEditingModel.onImportFailure
#       Apps/ZenitPDF/Sources/ZenitPDFAppKit/Window/ProjectWindowController.swift:1630
#       an unreadable .zpdftools file reaches ZenitErrorPresenter instead of nothing.
#
# The register being empty is not the same as the score being zero for ever. A new dead hook
# still fails as an unexplained offender; parking one here again means raising the size in the
# same diff, and `SearchAndOCRWiringTests.hookGateDefectRegisterIsHonest` still reads it.
readonly DEFECT_REGISTER=""

readonly DEFECT_REGISTER_SIZE=0

if [ "${PRINT_REGISTER}" -eq 1 ]; then
    # Machine-readable, for a test that wants the register rather than the script's prose. The
    # launch gate learned this the hard way: a test that greps a comment fails when someone
    # rewrites the comment.
    printf '%s\n' "${DEFECT_REGISTER}" | while IFS='|' read -r key note; do
        [ -n "${key}" ] || continue
        printf '%s\t%s\n' "${key}" "${note}"
    done
    exit 0
fi

# Minimums, so a scan that found nothing cannot pass quietly (two gates once passed vacuously in
# this repository).
#
# Raised 2026-08-26 from 200/50, where they had been since the gate was written and
# where they had drifted to roughly a third of the truth. A floor far below the real count
# cannot catch a scan that quietly shrinks: at 200 this gate would have passed on a run that
# lost two thirds of the shipping tier. Measured on the run that raised them: 699 files, 112
# hooks. A legitimate shrink — packages merged, a tier deleted — lowers these in the same diff
# and says why, which is the same rule every test floor in this repository carries.
readonly MIN_FILES=699
readonly MIN_HOOKS=112

WORK_DIR="$(mktemp -d)" || { printf 'FAIL: mktemp -d\n' >&2; exit 1; }
trap 'rm -rf "${WORK_DIR}"' EXIT

printf '%s\n' "${ALLOW_LIST}" > "${WORK_DIR}/allow.txt"
printf '%s\n' "${DEFECT_REGISTER}" > "${WORK_DIR}/defects.txt"

/usr/bin/python3 - "${ROOT}" "${WORK_DIR}/report.txt" <<'PY' || { printf 'FAIL: the hook scan did not run\n' >&2; exit 1; }
import os, re, sys

root, out_path = sys.argv[1], sys.argv[2]

HOOK = re.compile(r'^[ \t]*public var (on[A-Z][A-Za-z0-9_]*)[ \t]*:[ \t]*(.*)$')
TYPE = re.compile(
    r'^[ \t]*(?:@\w+[ \t]+)*(?:public |internal |private |fileprivate |open )*'
    r'(?:final[ \t]+)*(?:struct|class|actor|enum|extension)[ \t]+([A-Za-z_]\w*)')
IMPORT = re.compile(r'^[ \t]*(?:@testable[ \t]+)?import[ \t]+([A-Za-z_]\w*)', re.M)

def source_roots():
    for tier in ('Packages', 'Apps', 'Bridges'):
        base = os.path.join(root, tier)
        if not os.path.isdir(base):
            continue
        for entry in sorted(os.listdir(base)):
            sources = os.path.join(base, entry, 'Sources')
            if os.path.isdir(sources):
                yield tier, sources

files = []
for tier, sources in source_roots():
    for walk_root, _, names in os.walk(sources):
        for name in sorted(names):
            if name.endswith('.swift'):
                files.append((tier, os.path.join(walk_root, name)))

text = {}
for _, path in files:
    with open(path, encoding='utf-8') as handle:
        text[path] = handle.read().split('\n')

def module_of(path):
    parts = path.split(os.sep)
    return parts[parts.index('Sources') + 1]

visible = {}
for _, path in files:
    joined = '\n'.join(text[path])
    visible[path] = set(IMPORT.findall(joined)) | {module_of(path)}

def enclosing_types(lines):
    """Innermost type name per line, tracked by brace depth so a nested enum that has
    already closed is not credited with the properties that follow it."""
    stack, depth, owner = [], 0, {}
    for number, line in enumerate(lines, 1):
        match = TYPE.match(line)
        owner[number] = stack[-1][0] if stack else None
        opened, closed = line.count('{'), line.count('}')
        if match and opened > 0:
            stack.append((match.group(1), depth))
            owner[number] = match.group(1)
        depth += opened - closed
        while stack and depth <= stack[-1][1]:
            stack.pop()
    return owner

# Innermost type per line, for every file in the shipping tiers — not just the ones that declare
# hooks. The near-miss report needs it for the *assigning* file too: "the bare name is assigned at
# LedgerTableHost.swift:66" is the sentence that misled the hand-grep, and
# "assigns LedgerTableController.onSaveLayoutRequested" is the sentence that does not.
owners = {path: enclosing_types(text[path]) for _, path in files}

hooks = []
for tier, path in files:
    if tier != 'Packages':
        continue
    lines = text[path]
    owner = owners[path]
    for number, line in enumerate(lines, 1):
        match = HOOK.match(line)
        if not match:
            continue
        declared = match.group(2)
        if '->' not in declared:      # not a closure: a plain property whose name starts "on"
            continue
        if '{ get' in declared:       # a protocol requirement is a shape, not storage
            continue
        hooks.append({
            'module': module_of(path),
            'type': owner.get(number) or '?',
            'hook': match.group(1),
            'path': os.path.relpath(path, root),
            'line': number,
        })

def local_type(receiver, lines):
    """The type of `receiver`, if this file says so unambiguously.

    Only two forms are trusted, both declarations in the same file: an explicit annotation, and
    a constructor call. A function *parameter* is not read, because a labelled argument at a call
    site is spelled identically, and guessing wrong here turns a wired hook red. Two different
    answers in one file also count as unknown. Unknown always keeps the assignment: this
    refinement may rule a line *out*, never rule one in."""
    patterns = (
        re.compile(r'\b(?:let|var)[ \t]+' + receiver + r'[ \t]*:[ \t]*([A-Z]\w*)'),
        re.compile(r'\b(?:let|var)[ \t]+' + receiver + r'[ \t]*=[ \t]*([A-Z]\w*)\('),
    )
    seen = set()
    for line in lines:
        for pattern in patterns:
            for match in pattern.finditer(line):
                seen.add(match.group(1))
    return seen.pop() if len(seen) == 1 else None

# `receiver.hook = …` where `receiver` is a plain identifier, not the tail of a longer path.
# `model.onChange` gives up `model`; `core.canvas.onScrollTo` gives up nothing, because `canvas`
# there is a property of `core` and a file may well have a local of the same name and a different
# type — which is precisely the shape that made an earlier draft of this gate report a wired hook
# as dead.
def receiver_of(line, name):
    match = re.search(r'(?:^|[^A-Za-z0-9_.])([A-Za-z_]\w*)\.' + name + r'[ \t]*=[^=]', line)
    return match.group(1) if match else None

def assignment_sites(name, owner, module):
    """Classify every line in the shipping tiers that assigns this name.

    Returns (counted, excluded) where `excluded` carries a reason, so a false positive shows up
    in the gate's own output instead of being argued about."""
    pattern = re.compile(r'(?:^|[^A-Za-z0-9_])' + name + r'[ \t]*=[^=]')
    redeclare = re.compile(r'\b(?:var|let)[ \t]+' + name + r'\b')
    counted, excluded = [], []
    for _, path in files:
        lines = text[path]
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith('//'):
                continue
            if redeclare.search(stripped):        # the declaration itself, or a local of the name
                continue
            if not pattern.search(line):
                continue
            where = '%s:%d' % (os.path.relpath(path, root), number)
            here = module_of(path)
            receiver = receiver_of(line, name)
            resolved = local_type(receiver, lines) if receiver and receiver != 'self' else None
            if resolved is not None and resolved != owner:
                excluded.append('%s assigns %s.%s.%s — a different type%s' % (
                    where, here, resolved, name,
                    ', in the same module' if here == module else ''))
                continue
            if module not in visible[path]:
                # Name the type this line does land on, so the reader is not left with the bare
                # name that misled the grep. The receiver's type when the file says it, otherwise
                # the type the line sits inside; `?` only when neither is readable.
                landed = resolved or (owners[path].get(number) if receiver in (None, 'self') else None)
                excluded.append('%s assigns %s.%s.%s — %s does not import %s, which declares %s.%s' % (
                    where, here, landed or '?', name, here, module, module, owner))
                continue
            counted.append(where)
    return counted, excluded

rows = []
for hook in hooks:
    counted, excluded = assignment_sites(hook['hook'], hook['type'], hook['module'])
    if counted:
        continue
    rows.append('%s.%s.%s|%s:%d|%s' % (
        hook['module'], hook['type'], hook['hook'], hook['path'], hook['line'],
        '; '.join(excluded[:3])))

with open(out_path, 'w', encoding='utf-8') as handle:
    handle.write('files %d\nhooks %d\n' % (len(files), len(hooks)))
    for row in sorted(rows):
        handle.write('dead %s\n' % row)
PY

REPORT="${WORK_DIR}/report.txt"
[ -s "${REPORT}" ] || { printf 'FAIL: the hook scan produced no report\n' >&2; exit 1; }

files_scanned="$(/usr/bin/awk '$1 == "files" { print $2 }' "${REPORT}")"
hooks_found="$(/usr/bin/awk '$1 == "hooks" { print $2 }' "${REPORT}")"

printf '=== scan ===\n'
printf 'swift files in the shipping tiers: %s\n' "${files_scanned}"
printf 'closure hooks declared in Packages/*/Sources: %s\n' "${hooks_found}"

if [ "${files_scanned}" -lt "${MIN_FILES}" ] || [ "${hooks_found}" -lt "${MIN_HOOKS}" ]; then
    printf '\nFAILED: the scan examined %s files and found %s hooks (floors %s and %s). A gate that\n' \
        "${files_scanned}" "${hooks_found}" "${MIN_FILES}" "${MIN_HOOKS}" >&2
    printf '        scanned nothing must fail, not pass quietly.\n' >&2
    exit 1
fi

/usr/bin/awk '$1 == "dead"' "${REPORT}" | /usr/bin/sed 's/^dead //' > "${WORK_DIR}/dead.txt"
dead_count="$(/usr/bin/wc -l < "${WORK_DIR}/dead.txt" | tr -d ' ')"

printf '\n=== hooks with no assignment in any file that can see their module ===\n'
if [ "${dead_count}" -eq 0 ]; then
    printf 'none\n'
else
    while IFS='|' read -r key where elsewhere; do
        reason="$(/usr/bin/awk -F'|' -v k="${key}" '$1 == k { print $2 }' "${WORK_DIR}/allow.txt")"
        defect="$(/usr/bin/awk -F'|' -v k="${key}" '$1 == k { print $2 }' "${WORK_DIR}/defects.txt")"
        if [ -n "${defect}" ] && [ -n "${reason}" ]; then
            printf '  BOTH     %s\n           %s\n' "${key}" "${where}"
            printf '           on the allow-list AND the defect register — it is one or the other\n'
        elif [ -n "${defect}" ]; then
            printf '  DEFECT   %s\n           %s\n           %s\n' "${key}" "${where}" "${defect}"
        elif [ -n "${reason}" ]; then
            printf '  allowed  %s\n           %s\n           reason: %s\n' "${key}" "${where}" "${reason}"
        else
            printf '  DEAD     %s\n           %s\n' "${key}" "${where}"
        fi
        [ -n "${elsewhere}" ] && printf '           near miss: %s\n' "${elsewhere}"
    done < "${WORK_DIR}/dead.txt"
fi

if [ "${LIST_ONLY}" -eq 1 ]; then
    printf '\n--list: %s hook(s) with no assignment; nothing judged.\n' "${dead_count}"
    exit 0
fi

# Offenders that are on neither list, and offenders that are on both.
offenders=0
doubled=0
while IFS='|' read -r key _ _; do
    [ -n "${key}" ] || continue
    on_allow=1; on_defect=1
    /usr/bin/awk -F'|' -v k="${key}" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "${WORK_DIR}/allow.txt" || on_allow=0
    /usr/bin/awk -F'|' -v k="${key}" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "${WORK_DIR}/defects.txt" || on_defect=0
    if [ "${on_allow}" -eq 1 ] && [ "${on_defect}" -eq 1 ]; then
        printf '\non both lists at once (a defect that is also excused is neither): %s\n' "${key}" >&2
        doubled=$(( doubled + 1 ))
    elif [ "${on_allow}" -eq 0 ] && [ "${on_defect}" -eq 0 ]; then
        offenders=$(( offenders + 1 ))
    fi
done < "${WORK_DIR}/dead.txt"

# Entries on either list that are no longer offenders, and entries with no reason.
stale=0
unreasoned=0
for list in allow defects; do
    case "${list}" in
        allow)   label='allow-list' ;;
        defects) label='defect register' ;;
    esac
    while IFS='|' read -r key reason; do
        [ -n "${key}" ] || continue
        if [ -z "${reason}" ]; then
            printf '\n%s entry with no reason: %s\n' "${label}" "${key}" >&2
            unreasoned=$(( unreasoned + 1 ))
        fi
        /usr/bin/awk -F'|' -v k="${key}" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "${WORK_DIR}/dead.txt" \
            || { printf '\n%s entry that is now wired (delete the line): %s\n' "${label}" "${key}" >&2
                 stale=$(( stale + 1 )); }
    done < "${WORK_DIR}/${list}.txt"
done

# The register's declared size. Adding a defect without raising this is the quiet park the
# separate number exists to prevent; fixing one without lowering it leaves a stale score.
registered="$(/usr/bin/grep -c . "${WORK_DIR}/defects.txt" | tr -d ' ')"
miscounted=0
if [ "${registered}" -ne "${DEFECT_REGISTER_SIZE}" ]; then
    printf '\nthe defect register holds %s entries and declares DEFECT_REGISTER_SIZE=%s\n' \
        "${registered}" "${DEFECT_REGISTER_SIZE}" >&2
    miscounted=1
fi

printf '\n=== verdict ===\n'
if [ "${offenders}" -gt 0 ] || [ "${stale}" -gt 0 ] || [ "${unreasoned}" -gt 0 ] \
   || [ "${doubled}" -gt 0 ] || [ "${miscounted}" -gt 0 ]; then
    printf '\n=======================================================================\n' >&2
    printf 'FAILED: %d hook(s) declared in the shell/presenter layer are never assigned and\n' "${offenders}" >&2
    printf '        appear on neither list; %d entry/entries are stale, %d carry no reason,\n' "${stale}" "${unreasoned}" >&2
    printf '        %d sit on both lists, register size %s.\n' \
        "${doubled}" "$([ "${miscounted}" -eq 0 ] && printf 'correct' || printf 'WRONG')" >&2
    printf '        A hook the declaring type calls and nobody installs is a feature that\n' >&2
    printf '        compiles, tests green and does nothing.\n' >&2
    printf '=======================================================================\n' >&2
    exit 1
fi

allowed_count="$(/usr/bin/grep -c . "${WORK_DIR}/allow.txt" | tr -d ' ')"
printf 'Every closure hook in the shell/presenter layer is wired, excused or registered:\n'
printf '  %s hooks checked\n' "${hooks_found}"
printf '  %s allow-listed with a reason (dead and harmless)\n' "${allowed_count}"
printf '  %s on the live-defect register (dead and it costs a person something)\n' "${registered}"
printf '  0 unexplained\n'

if [ "${registered}" -gt 0 ]; then
    printf '\n'
    printf '***********************************************************************\n'
    printf 'GREEN, AND %s KNOWN LIVE DEFECTS ARE STILL OPEN. This gate passes because\n' "${registered}"
    printf 'they predate it and are triaged, not because they are acceptable. Each\n'
    printf 'one is a control a person can reach whose effect is nothing:\n'
    while IFS='|' read -r key note; do
        [ -n "${key}" ] || continue
        printf '  - %s\n      %s\n' "${key}" "${note}"
    done < "${WORK_DIR}/defects.txt"
    printf 'Fix one, delete its line, lower DEFECT_REGISTER_SIZE. The number is the score.\n'
    printf '***********************************************************************\n'
fi
