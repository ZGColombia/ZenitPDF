#!/bin/bash
#
# verify-no-armed-recovery-markers.sh — no project package a person can open may be left
# with its crash marker armed.
#
# ## Why this gate exists
#
# Crash-recovery tests own their marker: killing the process is the point of the test, and
# leaving it armed is the defect. An armed `recovery/crash-marker` inside a `.zpdfproj` means
# the **next** open of that package raises *"… was not closed properly — There is unsaved work
# from the last session"*, and the next opener may be a person rather than a test.
#
# A fixture in `/private/var/folders/.../T/zenitpdf-apptests-<uuid>/` is the right placement,
# and that placement is the thing this gate holds. A package in a temporary directory is
# reclaimed by the system and nobody double-clicks it; a package in `~/Documents` is a file a
# person sees.
#
# ## What it checks
#
# Every `.zpdfproj` under the repository, plus the matcher canary described below. An armed
# marker in any of them fails the gate. The gate reports an armed package by name and never
# deletes it.
#
# The running account's Documents, Desktop and Downloads are searched too, but only when
# `ZENIT_ARMED_SCAN_HOME=1` is set. They are not searched by default because the answer there
# depends on the machine rather than on the code under test: a person who has a Zenit PDF
# project open, or whose app quit while one was open, has an armed marker in their own folders
# that no test left behind, and the first walk of those folders makes macOS ask the terminal for
# Files and Folders access. A run that sets it reads those three folders to a depth of 8.
#
# ## A root it cannot read is not a clean root
#
# macOS privacy protection (TCC) denies some processes the **enumeration** of `~/Documents`,
# `~/Desktop` and `~/Downloads`: a terminal that has never been granted Files-and-Folders access
# gets `EPERM` at the root of the walk. With `ZENIT_ARMED_SCAN_HOME=1` that is the usual way a
# root ends up DENIED; without it, only the repository and the canary are walked.
#
#     $ find "$HOME/Documents" -maxdepth 8 -name '*.zpdfproj'
#     find: /Users/…/Documents: Operation not permitted
#
# An earlier version passed every root to one `find` with `2>/dev/null`, so the message was
# swallowed, the loop body never ran once, and `scanned=0` was reported as a clean machine — the
# result depended on who ran the gate rather than on the code under test. A floor that asserted
# only that the repository root exists could not catch it: the repository genuinely holds no
# `.zpdfproj`, so a denied home and a clean home produced byte-identical output.
#
# **A gate that cannot see must fail, not pass.** Each root is therefore searched on its own, its
# stderr is read rather than discarded, and any root whose walk errors — for any reason, not only
# TCC — makes this gate exit non-zero while naming the root, the reason, and the command a human
# must run in a Finder-authorised terminal to get a real answer. A denied root is reported as
# **DENIED**, never as zero packages.
#
# ## Two non-zero exits, and why they are not the same
#
#   * **exit 1 — FAIL.** A package was found with its marker armed. This is a defect: somebody's
#     next double-click raises the recovery dialogue.
#   * **exit 75 — INCONCLUSIVE.** Nothing armed was found among the roots that *could* be read,
#     and at least one root could not be. The same code convention `build-snap-package.sh`
#     already uses. Neither is a pass and neither may be reported green; the distinction exists
#     because "there is an armed marker" and "I was not allowed to look" call for entirely
#     different actions, and a caller that cannot tell them apart is a caller that will
#     eventually be taught to ignore both.
#
# An armed marker outranks a denial: if one is found among the readable roots, the exit is 1,
# because a known defect is more actionable than an unknown one.
#
# ## A readable root that holds nothing, and the canary that closes it
#
# Failing on a *denied* root still leaves the gate green for a root it can read and finds nothing
# in: every root readable, `scanned 0`, `rc=0`, and a green closing line. A change that silently
# stopped matching `*.zpdfproj` (a renamed extension, a `-maxdepth` that no longer reaches, a
# `-type d` that stopped being true) would produce `scanned 0`, `denied 0`, and a pass.
#
# The honest floor here cannot be "at least one project package exists in the world": a clean
# machine genuinely has none, and a gate that failed on that would be teaching people to ignore
# it by the second run. The floor is that **the matcher still matches**. This gate therefore
# builds one `.zpdfproj` of its own, in its own temporary directory, adds that directory to the
# search roots, and fails if the walk does not come back holding it. The canary is deliberately
# *clean* — a directory and a `journal.json`, no `recovery/crash-marker` — so it exercises the
# find, the `-type d` match and the marker test without ever being able to produce a false FAIL.
# It is deleted on exit by the same trap that removes the scratch files, whatever the outcome.
#
# `ZENIT_ARMED_SCAN_ROOTS` replaces the whole root list — repository, canary and, when asked for,
# the home folders — with a space-separated list of directories. It exists so the floor itself
# can be proven rather than asserted: point it at an empty directory and this gate must FAIL,
# point it at a directory holding one clean project package and it must PASS. Both are exercised
# in `GateFloorTests` (application package). Setting it is never the normal way to run this gate,
# and the banner says so on every such run, because a scan of a chosen directory is not a scan of
# the places the gate exists to watch.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF
fi

readonly MARKER="recovery/crash-marker"

# The home folders are read only on request; see the header.
scan_home=0
[ "${ZENIT_ARMED_SCAN_HOME:-}" = "1" ] && scan_home=1

printf '=== project packages : no crash marker left armed ===\n'

# The canary. One clean `.zpdfproj` this gate makes and this gate deletes,
# in a temporary directory nobody double-clicks. If the walk does not find it, the matcher is
# broken and every other number this script prints is meaningless.
readonly CANARY_ROOT="$(mktemp -d -t zenit-armed-canary)"
readonly CANARY_PACKAGE="${CANARY_ROOT}/MatcherCanary.zpdfproj"
readonly CANARY_MADE=$([ -d "${CANARY_ROOT}" ] && printf 1 || printf 0)
if [ "${CANARY_MADE}" = '1' ]; then
    mkdir -p "${CANARY_PACKAGE}"
    printf '{"canary":true}\n' >"${CANARY_PACKAGE}/journal.json"
fi

# The roots. `${ROOT}` is mandatory — a repository that cannot be walked is a broken checkout,
# not a permission problem. With `ZENIT_ARMED_SCAN_HOME=1` the three home roots are searched when
# they exist; a root that does not exist at all (no `~/Downloads`, say) is genuinely nothing to
# scan and is skipped, which is different from a root that exists and refuses to be read.
#
# `ZENIT_ARMED_SCAN_ROOTS` replaces the list outright — the proof harness of the non-vacuity
# floor, and never the normal path. The canary is not added in that mode: the whole point of the
# override is to ask what this gate does when the roots it is given hold nothing.
override_roots="${ZENIT_ARMED_SCAN_ROOTS:-}"
if [ -n "${override_roots}" ]; then
    printf 'NOTE: ZENIT_ARMED_SCAN_ROOTS is set. This is the proof of the non-vacuity floor,\n'
    printf '      not a scan of the places a person keeps project packages.\n'
    # shellcheck disable=SC2206  # word splitting is the documented interface
    search_roots=(${override_roots})
else
    search_roots=("${ROOT}")
    if [ "${scan_home}" -eq 1 ]; then
        printf 'NOTE: ZENIT_ARMED_SCAN_HOME=1 is set; Documents, Desktop and Downloads are searched too.\n'
        for extra in "${HOME}/Documents" "${HOME}/Desktop" "${HOME}/Downloads"; do
            [ -d "${extra}" ] && search_roots+=("${extra}")
        done
    fi
    [ "${CANARY_MADE}" = '1' ] && search_roots+=("${CANARY_ROOT}")
fi

scanned=0
armed=0
offenders=""
denied=0
denied_report=""
denied_roots=()

# Every package found, across all roots, before de-duplication. `sort -u`, because a checkout of
# this repository may live under `~/Desktop` and, with the home folders searched, the roots then
# overlap —
# without it one package is reported as two, which is the sort of arithmetic that makes a
# gate's output distrusted.
readonly FOUND_LIST="$(mktemp -t zenit-armed-scan)"
readonly ERR_FILE="$(mktemp -t zenit-armed-scan-err)"
trap 'rm -f "${FOUND_LIST}" "${ERR_FILE}"; rm -rf "${CANARY_ROOT}"' EXIT

# One root at a time, stderr read rather than discarded. `find` exits non-zero when any part of
# the walk failed, and prints the reason; both are evidence and neither may be thrown away.
for root in "${search_roots[@]}"; do
    : >"${ERR_FILE}"
    if find "${root}" -maxdepth 8 -name '*.zpdfproj' -type d 2>"${ERR_FILE}" >>"${FOUND_LIST}"; then
        root_status='searched'
    else
        root_status='failed'
    fi
    reason="$(tr '\n' '; ' <"${ERR_FILE}" | sed 's/; *$//')"
    if [ "${root_status}" = 'failed' ] || [ -n "${reason}" ]; then
        denied=$((denied + 1))
        denied_roots+=("${root}")
        [ -n "${reason}" ] || reason='find exited non-zero without printing a reason'
        denied_report="${denied_report}  · ${root}\n      ${reason}\n"
        printf '  %-60s DENIED\n' "${root}"
    else
        printf '  %-60s searched\n' "${root}"
    fi
done

canary_seen=0
while IFS= read -r package; do
    [ -n "${package}" ] || continue
    if [ "${package}" = "${CANARY_PACKAGE}" ]; then
        canary_seen=1
        continue
    fi
    scanned=$((scanned + 1))
    [ -e "${package}/${MARKER}" ] || continue
    when="$(stat -f '%Sm' "${package}/${MARKER}" 2>/dev/null || printf 'unknown')"
    armed=$((armed + 1))
    offenders="${offenders}  · ${package}  (armed ${when})\n"
done < <(sort -u "${FOUND_LIST}")

# A gate that examined nothing must fail.
if [ ! -d "${ROOT}" ]; then
    printf 'FAIL: the scan had no repository to search.\n' >&2
    exit 1
fi

# The non-vacuity floor. Zero packages on a clean machine is a real and honest
# answer, so the floor is not "packages exist" — it is "the matcher still matches", proven
# against a package this gate created itself and knows the path of. A run that cannot find its
# own canary has not established anything about the other roots either, and the only honest
# verdict for it is red.
if [ -z "${override_roots}" ]; then
    if [ "${CANARY_MADE}" != '1' ]; then
        printf 'FAIL: the matcher canary could not be created, so this scan proves nothing\n' >&2
        printf '      about whether the walk still matches a project package.\n' >&2
        exit 1
    fi
    if [ "${canary_seen}" -ne 1 ]; then
        printf 'FAIL: the walk did not find this gate'"'"'s own canary package.\n' >&2
        printf '      Created: %s\n' "${CANARY_PACKAGE}" >&2
        printf '      The scan therefore examined nothing it can prove it examined, and\n' >&2
        printf '      "scanned %s, armed 0" is a statement about a broken matcher rather than\n' "${scanned}" >&2
        printf '      about the packages on this machine. The usual causes are a changed\n' >&2
        printf '      extension, a -maxdepth that no longer reaches, or -type d ceasing to hold.\n' >&2
        exit 1
    fi
else
    # Override mode: there is no canary, so the floor is the plain one — a scan that found no
    # project package at all examined nothing and may not report success.
    if [ "${scanned}" -eq 0 ] && [ "${denied}" -eq 0 ]; then
        printf 'FAIL: the scan found no project package in any given root.\n' >&2
        printf '      A gate that examined nothing does not pass.\n' >&2
        for given in "${search_roots[@]}"; do printf '      · %s\n' "${given}" >&2; done
        exit 1
    fi
fi

printf 'scanned %s project package(s) across %s root(s), %s of them denied.\n' \
    "${scanned}" "${#search_roots[@]}" "${denied}"
if [ -z "${override_roots}" ]; then
    printf 'matcher canary: found (the walk still matches a .zpdfproj).\n'
fi

# An armed marker outranks a denial. A known defect is more actionable than an unknown one, and
# reporting INCONCLUSIVE while holding a concrete offender in hand would bury it.
if [ "${armed}" -gt 0 ]; then
    printf '\nFAIL: %s project package(s) were left with the crash marker armed.\n' "${armed}" >&2
    printf '      The next open of each raises "… was not closed properly", to whoever is there.\n' >&2
    printf '%b' "${offenders}" >&2
    printf '      The gate does not delete them. For a package that is not open in Zenit PDF,\n' >&2
    printf '      removing its %s clears it.\n' "${MARKER}" >&2
    if [ "${denied}" -gt 0 ]; then
        printf '      %s root(s) were also unreadable, so this count is a lower bound.\n' "${denied}" >&2
    fi
    printf '\nFAILED: an armed recovery marker outside a temporary directory.\n' >&2
    exit 1
fi

# A gate that cannot see must not pass. Nothing armed was found among the roots
# that could be read, and at least one could not be — so the honest verdict is INCONCLUSIVE, not
# green. Exit 75, the code `build-snap-package.sh` already uses for exactly this distinction.
if [ "${denied}" -gt 0 ]; then
    printf '\nINCONCLUSIVE: %s search root(s) could not be enumerated, so this gate is blind\n' "${denied}" >&2
    printf '      there and its result is a lower bound, not an answer.\n' >&2
    printf '%b' "${denied_report}" >&2
    printf '\n      The usual cause is macOS privacy protection (TCC): the process running this\n' >&2
    printf '      gate has not been granted Files and Folders access to that location. It is not\n' >&2
    printf '      a defect in the code under test, and it is not something a script can grant\n' >&2
    printf '      itself — only a human at the machine can.\n' >&2
    printf '\n      What a human must run, in Terminal.app or another application that already\n' >&2
    printf '      holds Full Disk Access (System Settings ▸ Privacy & Security ▸ Full Disk Access):\n' >&2
    if [ "${scan_home}" -eq 1 ]; then
        printf '\n        ZENIT_ARMED_SCAN_HOME=1 Scripts/verify-no-armed-recovery-markers.sh\n' >&2
    else
        printf '\n        Scripts/verify-no-armed-recovery-markers.sh\n' >&2
    fi
    printf '\n      Or, to answer only the question this gate exists to ask:\n' >&2
    for denied_root in "${denied_roots[@]}"; do
        printf '        find %q -maxdepth 8 -name '"'"'*.zpdfproj'"'"' -type d -exec test -e {}/%s \\; -print\n' \
            "${denied_root}" "${MARKER}" >&2
    done
    printf '\nARMED-MARKERS: INCONCLUSIVE  denied=%s  scanned=%s  exit=75\n' \
        "${denied}" "${scanned}" >&2
    printf 'FAILED: the scan was denied a root it must see. A blind gate does not pass.\n' >&2
    exit 75
fi

printf 'no project package is left armed, every root was read,\n'
printf 'and the walk proved it can still find a project package.\n'
exit 0
