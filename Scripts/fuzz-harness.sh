#!/bin/bash
#
# fuzz-harness.sh — out-of-process fuzz runner with SIGKILL watchdogs.
#
# The in-process fuzz suites (`FuzzTests` in Bridges/QPDFBridge, `FuzzExtractionTests` in
# ZPDFVectorExtraction, `FuzzRegressionTests` in ZPDFPDFKitBridge) measure elapsed time and
# resident growth *after each call returns*. An operation that never returns therefore wedges
# the test runner instead of failing it, and an allocation spike kills the runner instead of
# being reported. This harness is the out-of-process shape used during S18 verification,
# promoted into the gates: it runs the fuzz suite in a child process it does not trust, and
# enforces two budgets from outside with SIGKILL —
#
#   * wall clock: if the child tree is still alive after the budget, it is killed -9 and the
#     gate fails as a HANG, naming the filter. No cooperation from the wedged process needed.
#   * resident size: the RSS of the whole child tree is sampled once a second; exceeding the
#     budget kills the tree -9 and fails the gate as a RUNAWAY ALLOCATION.
#
# The in-repo iteration counts are unchanged: this harness runs the same suites with the same
# seeds (400 mutated inputs for qpdf, 500 for extraction and PDFKit). What it adds is that a
# true hang or a runaway allocation is now a red gate instead of a wedged terminal.
#
# `--skip-build` is passed so the wall-clock budget measures the fuzz run, not a compile; the
# calling script must have run `swift build --build-tests` first. Non-vacuity: the child runs
# with `--xunit-output`, and Scripts/xunit-summary.sh must account for at least one executed
# test and zero failures — a harness whose filter matched nothing fails.
#
# Usage: fuzz-harness.sh <package-dir> <test-filter> <wall-seconds> <rss-budget-mb> [config]
#        config defaults to debug; pass release to fuzz the optimised build.

set -u
set -o pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 4 ]; then
    printf 'usage: fuzz-harness.sh <package-dir> <test-filter> <wall-seconds> <rss-budget-mb> [debug|release]\n' >&2
    exit 2
fi

readonly PACKAGE_DIR="$1"
readonly FILTER="$2"
readonly WALL_SECONDS="$3"
readonly RSS_BUDGET_MB="$4"
readonly CONFIG="${5:-debug}"

case "${WALL_SECONDS}${RSS_BUDGET_MB}" in
    *[!0-9]*) printf 'fuzz-harness: budgets must be integers\n' >&2; exit 2 ;;
esac
[ -f "${PACKAGE_DIR}/Package.swift" ] || {
    printf 'fuzz-harness: no Package.swift at %s\n' "${PACKAGE_DIR}" >&2
    exit 2
}

# Sum of the resident sizes (KB) of a pid and all its descendants. `ps -o rss=` reports KB on
# macOS. Descendants matter: `swift test` execs a separate test-runner process, and that child
# is the one a hostile input would bloat.
rss_tree_kb() {
    local pid="$1" total kid kids kb
    kb="$(ps -o rss= -p "${pid}" 2>/dev/null | tr -d ' ')"
    total="${kb:-0}"
    kids="$(pgrep -P "${pid}" 2>/dev/null || true)"
    for kid in ${kids}; do
        total=$(( total + $(rss_tree_kb "${kid}") ))
    done
    printf '%s' "${total}"
}

# SIGKILL the whole tree, leaves first, so nothing is reparented and survives. SIGKILL on
# purpose: a wedged parser cannot be trusted to honour anything gentler.
kill_tree() {
    local pid="$1" kid kids
    kids="$(pgrep -P "${pid}" 2>/dev/null || true)"
    for kid in ${kids}; do
        kill_tree "${kid}"
    done
    kill -9 "${pid}" 2>/dev/null || true
}

scratch="$(mktemp -d)" || { printf 'fuzz-harness: mktemp failed\n' >&2; exit 1; }
trap 'rm -rf "${scratch}"' EXIT
readonly CHILD_LOG="${scratch}/fuzz.log"
readonly XML_BASE="${scratch}/fuzz.xml"

printf 'fuzz-harness: %s --filter %s (%s), budgets: %ss wall, %s MB RSS, SIGKILL on breach\n' \
    "$(basename "${PACKAGE_DIR}")" "${FILTER}" "${CONFIG}" "${WALL_SECONDS}" "${RSS_BUDGET_MB}"

(
    cd "${PACKAGE_DIR}" || exit 97
    exec swift test -c "${CONFIG}" --skip-build --filter "${FILTER}" \
        --xunit-output "${XML_BASE}"
) > "${CHILD_LOG}" 2>&1 &
child=$!

started_at="${SECONDS}"
peak_rss_kb=0
verdict="ok"
while kill -0 "${child}" 2>/dev/null; do
    elapsed=$(( SECONDS - started_at ))
    if [ "${elapsed}" -ge "${WALL_SECONDS}" ]; then
        verdict="hang"
        kill_tree "${child}"
        break
    fi
    rss_kb="$(rss_tree_kb "${child}")"
    [ "${rss_kb}" -gt "${peak_rss_kb}" ] && peak_rss_kb="${rss_kb}"
    if [ "${rss_kb}" -gt $(( RSS_BUDGET_MB * 1024 )) ]; then
        verdict="rss"
        kill_tree "${child}"
        break
    fi
    sleep 1
done

wait "${child}" 2>/dev/null
status=$?
elapsed=$(( SECONDS - started_at ))

case "${verdict}" in
    hang)
        tail -20 "${CHILD_LOG}"
        printf 'fuzz-harness: HANG — %s still running after %ss; tree killed with SIGKILL.\n' \
            "${FILTER}" "${WALL_SECONDS}" >&2
        exit 1
        ;;
    rss)
        tail -20 "${CHILD_LOG}"
        printf 'fuzz-harness: RUNAWAY ALLOCATION — %s tree reached %s MB (budget %s MB); killed with SIGKILL.\n' \
            "${FILTER}" $(( peak_rss_kb / 1024 )) "${RSS_BUDGET_MB}" >&2
        exit 1
        ;;
esac

if [ "${status}" -ne 0 ]; then
    tail -40 "${CHILD_LOG}"
    printf 'fuzz-harness: %s exited %s (crash or test failure; log above).\n' "${FILTER}" "${status}" >&2
    exit 1
fi

counts="$("${HERE}/xunit-summary.sh" "${XML_BASE%.xml}-swift-testing.xml")" || {
    tail -20 "${CHILD_LOG}"
    printf 'fuzz-harness: no machine-readable account of the fuzz run — treating as failed.\n' >&2
    exit 1
}
executed="${counts%% *}"
failed="$(printf '%s' "${counts}" | awk '{print $2}')"
if [ "${executed}" -eq 0 ] || [ "${failed}" -ne 0 ]; then
    printf 'fuzz-harness: accounting says %s executed, %s failed — red.\n' "${executed}" "${failed}" >&2
    exit 1
fi

printf 'fuzz-harness: %s — %s tests, 0 failures, peak tree RSS %s MB, %ss (budgets %ss / %s MB).\n' \
    "${FILTER}" "${executed}" $(( peak_rss_kb / 1024 )) "${elapsed}" "${WALL_SECONDS}" "${RSS_BUDGET_MB}"
exit 0
