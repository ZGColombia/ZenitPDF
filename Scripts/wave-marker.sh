#!/bin/bash
#
# wave-marker.sh — who holds the tree: a working-tree ownership marker for parallel builds.
#
# ## Why this exists
#
# Two builds editing one working tree and sharing one `.build`, with nothing recording that the
# other one is there, interfere with each other: files change under a verification pass while it
# runs, and a red gate that belongs to neither run is the result. Disjoint directories do not
# prevent it either — two runs that touch one shared concept (an allow-list and the hook it
# lists, say) can still leave the tree inconsistent. This script records who holds the tree.
#
# ## What it is, and what it deliberately is not
#
# It is a **convention with a reminder**, not a lock. A run (a *wave*, in this script's messages
# and file names) writes a marker naming itself and the
# directories it claims, removes it when it finishes, and every build gate prints a warning when
# somebody else's fresh marker is on the tree. It is advisory on purpose:
#
#   * `check` **always exits 0**. A marker must never be able to redden a gate. A build that fails
#     because of bookkeeping is a build people learn to bypass, and a bypassed convention is worse
#     than none — it is a false sense of a still tree.
#   * **Stale markers expire, and expire themselves.** A run killed by a watchdog, a crash, a
#     closed laptop or a `^C` leaves its marker behind. Any marker older than the TTL is deleted
#     by the next `check` — by *any* invocation of it, including one from the run that would
#     have been warned about — and so is any marker that named an owning process which has since
#     died on this host. It is therefore impossible for a leftover marker to wedge a build, which
#     was an explicit requirement: the failure mode of a lock nobody can clear is worse than the
#     collision it prevents.
#
# ## Usage
#
#   Scripts/wave-marker.sh claim <run-name> [dir ...]   # at the start of a run
#   Scripts/wave-marker.sh release [run-name]           # at the end of it
#   Scripts/wave-marker.sh check [dir ...]              # what the build scripts run; always rc=0
#   Scripts/wave-marker.sh list                         # every live marker
#
#   ZENIT_WAVE                 names the current run, so `check` knows which marker is its own
#                              and `release` needs no argument.
#   ZENIT_WAVE_TTL_SECONDS     how long a marker stays fresh. Default 5400 (90 minutes) — longer
#                              than the longest gate in this repository (build-renderer, ~200s)
#                              by two orders of magnitude, and short enough that a forgotten
#                              marker is gone before the next working session.
#   ZENIT_WAVE_QUIET=1         suppress the "tree is clear" line; warnings still print.
#   ZENIT_WAVE_PID             optional: the pid of a long-lived process that owns the run. When
#                              set, the marker also expires the moment that process is gone,
#                              which is faster than the TTL. Left unset by default — see the note
#                              on DEAD_PROCESS_GRACE for why the obvious pid is the wrong one.
#
# Markers live in `.zenit-waves/` at the repository root, one file per run, plain `key=value`
# text: readable with `cat`, editable with an editor, and needing no JSON parser in a shell that
# is not guaranteed to have one.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MARKER_DIR="${ROOT}/.zenit-waves"
readonly TTL="${ZENIT_WAVE_TTL_SECONDS:-5400}"
# A marker may *also* name a long-lived process that owns the run, and then a dead process is a
# second, faster staleness signal. It is opt-in (`ZENIT_WAVE_PID`, or `claim --pid N`) precisely
# because the obvious implementation is wrong: `claim` is a shell script that exits in a
# millisecond, so pruning on *its* pid would delete every marker two minutes after it was written
# and quietly turn this whole convention off. The grace applies on top, for a process that is
# still starting.
readonly DEAD_PROCESS_GRACE=120

slug_of() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'
}

marker_path() {
    printf '%s/%s.marker' "${MARKER_DIR}" "$(slug_of "$1")"
}

field() {
    # field <file> <key> — the value, or empty. Tolerant of a truncated or hand-edited file.
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

now() { date +%s; }

# Deletes every marker that can no longer be speaking for a live run, and says so.
# Never fails: an unreadable marker directory is not a build error.
prune() {
    [ -d "${MARKER_DIR}" ] || return 0
    local current file age started pid host
    current="$(now)"
    for file in "${MARKER_DIR}"/*.marker; do
        [ -e "${file}" ] || continue
        started="$(field "${file}" started_epoch)"
        case "${started}" in
            ''|*[!0-9]*)
                printf 'wave-marker: removing %s — it carries no start time.\n' "$(basename "${file}")"
                rm -f "${file}" 2>/dev/null
                continue
                ;;
        esac
        age=$(( current - started ))
        if [ "${age}" -ge "${TTL}" ]; then
            printf 'wave-marker: expiring %s — %ss old, past the %ss TTL.\n' \
                "$(field "${file}" run)" "${age}" "${TTL}"
            rm -f "${file}" 2>/dev/null
            continue
        fi
        pid="$(field "${file}" owner_pid)"
        host="$(field "${file}" host)"
        if [ "${host}" = "$(hostname -s 2>/dev/null)" ] \
            && [ -n "${pid}" ] && [ "${age}" -ge "${DEAD_PROCESS_GRACE}" ] \
            && ! kill -0 "${pid}" 2>/dev/null; then
            printf 'wave-marker: expiring %s — its owning process (%s) is gone.\n' \
                "$(field "${file}" run)" "${pid}"
            rm -f "${file}" 2>/dev/null
        fi
    done
    return 0
}

cmd_claim() {
    local run="${1:-${ZENIT_WAVE:-}}"
    if [ -z "${run}" ]; then
        printf 'usage: wave-marker.sh claim <run-name> [dir ...]\n' >&2
        return 2
    fi
    shift || true
    local owner_pid="${ZENIT_WAVE_PID:-}"
    if [ "${1:-}" = "--pid" ]; then owner_pid="${2:-}"; shift 2; fi
    prune
    mkdir -p "${MARKER_DIR}" || { printf 'wave-marker: cannot create %s\n' "${MARKER_DIR}" >&2; return 1; }
    local file
    file="$(marker_path "${run}")"
    {
        printf 'run=%s\n' "${run}"
        printf 'claimed_by_pid=%s\n' "$$"
        printf 'owner_pid=%s\n' "${owner_pid}"
        printf 'host=%s\n' "$(hostname -s 2>/dev/null)"
        printf 'started_epoch=%s\n' "$(now)"
        printf 'started_iso=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'ttl_seconds=%s\n' "${TTL}"
        printf 'dirs=%s\n' "$*"
    } > "${file}" || { printf 'wave-marker: cannot write %s\n' "${file}" >&2; return 1; }
    printf 'wave-marker: %s claims [%s]\n' "${run}" "${*:-the whole tree}"
    # Claiming is also a check: if somebody else is already here, say so now rather than at the
    # first gate twenty minutes later.
    cmd_check "$@"
    printf 'wave-marker: export ZENIT_WAVE=%s so the gates know this marker is yours.\n' "${run}"
    return 0
}

cmd_release() {
    local run="${1:-${ZENIT_WAVE:-}}"
    if [ -z "${run}" ]; then
        printf 'usage: wave-marker.sh release <run-name>   (or set ZENIT_WAVE)\n' >&2
        return 2
    fi
    local file
    file="$(marker_path "${run}")"
    if [ -e "${file}" ]; then
        rm -f "${file}"
        printf 'wave-marker: %s released the tree.\n' "${run}"
    else
        printf 'wave-marker: %s held no marker (already released, or expired).\n' "${run}"
    fi
    prune
    return 0
}

# The one the gates call. Warns; never fails.
cmd_check() {
    prune
    local mine others file run age dirs overlap claimed asked
    mine="$(slug_of "${ZENIT_WAVE:-}")"
    others=0
    if [ -d "${MARKER_DIR}" ]; then
        for file in "${MARKER_DIR}"/*.marker; do
            [ -e "${file}" ] || continue
            run="$(field "${file}" run)"
            [ -n "${ZENIT_WAVE:-}" ] && [ "$(slug_of "${run}")" = "${mine}" ] && continue
            others=$(( others + 1 ))
            age=$(( $(now) - $(field "${file}" started_epoch) ))
            dirs="$(field "${file}" dirs)"
            if [ "${others}" -eq 1 ]; then
                printf '\n'
                printf 'WARNING: another wave holds this tree. Two builds in one working\n'
                printf '         directory can rewrite files under each other.\n'
            fi
            printf '         · %s — started %s (%ss ago), claims: %s\n' \
                "${run}" "$(field "${file}" started_iso)" "${age}" \
                "${dirs:-the whole tree}"
            # Name the actual overlap when both sides said what they wanted. A shared concept is
            # enough to collide even with disjoint directories, so this is a hint and not
            # a clearance.
            if [ "$#" -gt 0 ] && [ -n "${dirs}" ]; then
                overlap=""
                for claimed in ${dirs}; do
                    for asked in "$@"; do
                        case "${asked}" in
                            "${claimed}"|"${claimed}"/*) overlap="${overlap} ${asked}" ;;
                            *) case "${claimed}" in "${asked}"/*) overlap="${overlap} ${claimed}" ;; esac ;;
                        esac
                    done
                done
                [ -n "${overlap}" ] && printf '           overlaps what you asked about:%s\n' "${overlap}"
            fi
        done
    fi
    if [ "${others}" -gt 0 ]; then
        printf '         This gate is running anyway — a marker is a convention, never a lock.\n'
        printf '         Results from a shared tree are not evidence. Re-run alone before\n'
        printf '         reporting anything green.\n\n'
    elif [ -z "${ZENIT_WAVE_QUIET:-}" ]; then
        printf 'wave-marker: no other wave holds this tree.\n'
    fi
    return 0
}

cmd_list() {
    prune
    if [ ! -d "${MARKER_DIR}" ] || [ -z "$(ls -A "${MARKER_DIR}" 2>/dev/null)" ]; then
        printf 'wave-marker: no live markers.\n'
        return 0
    fi
    local file
    for file in "${MARKER_DIR}"/*.marker; do
        [ -e "${file}" ] || continue
        printf -- '--- %s\n' "$(basename "${file}")"
        cat "${file}"
    done
    return 0
}

case "${1:-check}" in
    claim)   shift; cmd_claim "$@" ;;
    release) shift; cmd_release "$@" ;;
    check)   shift || true; cmd_check "$@" ;;
    list)    cmd_list ;;
    -h|--help|help)
        sed -n '3,52p' "${BASH_SOURCE[0]}"
        ;;
    *)
        printf 'wave-marker.sh: unknown command "%s"\n' "$1" >&2
        printf 'usage: wave-marker.sh claim|release|check|list\n' >&2
        exit 2
        ;;
esac
