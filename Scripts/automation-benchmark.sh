#!/bin/bash
#
# automation-benchmark.sh — precision and recall of every automation detector, gated
# (NL-AUTO-25).
#
# Runs `AutomationBenchmarkTests` in ZPDFAppCore over the labelled synthetic corpus that
# ZPDFTestingSupport generates (door symbols on walls with hatch, stroked text and a dimension
# chain; rooms behind door openings; Swedish and English title blocks), prints one line per
# detector — symbols, rooms, sheet names, scales — and fails when any falls under the gates in
# Docs/Execution/quality-thresholds.json → "automation".
#
# Real drawings stay on the machine that runs the benchmark and out of git. Describe them in a JSON
# manifest of the same format (ZPDFTestingSupport AutomationCorpusManifest: drawing paths
# relative to the manifest, and per page the symbol boxes and instance points, room clicks and
# areas, sheet numbers and scales) and run:
#
#   ZENIT_AUTOMATION_CORPUS=/path/to/manifest.json Scripts/automation-benchmark.sh
#
# Everything runs on this Mac. Nothing is uploaded.
#
# Exit status: 0 when every detector meets its gate on every configured corpus, 1 otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"${REPO_ROOT}/Scripts/wave-marker.sh" check Packages/ZPDFAppCore Packages/ZPDFTestingSupport || true

SCRATCH="${ZENIT_AUTOMATION_BENCHMARK_SCRATCH:-${REPO_ROOT}/Packages/ZPDFAppCore/.build-automation-benchmark}"
LOG="$(mktemp -t zenit-automation-benchmark)"
trap 'rm -f "$LOG"' EXIT

set +e
swift test \
    --package-path "${REPO_ROOT}/Packages/ZPDFAppCore" \
    --scratch-path "$SCRATCH" \
    --filter AutomationBenchmarkTests >"$LOG" 2>&1
STATUS=$?
set -e

LINES="$(grep -E '^AUTOMATION-BENCHMARK ' "$LOG" | sed 's/^AUTOMATION-BENCHMARK //' || true)"
if [[ -z "$LINES" ]]; then
    echo "automation-benchmark: the suite printed no results — it did not run." >&2
    tail -40 "$LOG" >&2
    exit 1
fi
echo "$LINES"

# All four detectors must have reported on the synthetic corpus: a missing line is a detector
# that silently stopped running, not a pass.
for detector in symbols rooms sheetNames scales; do
    if ! grep -qE "^synthetic ${detector}: " <<<"$LINES"; then
        echo "automation-benchmark: no result for synthetic ${detector}." >&2
        exit 1
    fi
done

if grep -q ' FAIL$' <<<"$LINES" || [[ $STATUS -ne 0 ]]; then
    echo "automation-benchmark: FAILED — a detector is under its gate, or the suite failed (status ${STATUS})." >&2
    grep -E '✘' "$LOG" | head -20 >&2 || true
    exit 1
fi
echo "automation-benchmark: every detector meets its gate."
