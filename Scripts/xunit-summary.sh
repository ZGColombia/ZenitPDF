#!/bin/bash
#
# xunit-summary.sh — machine-readable test accounting.
#
# Reads the xUnit XML that `swift test --xunit-output <base>.xml` writes for the
# swift-testing runner (`<base>-swift-testing.xml`) and prints one line to stdout:
#
#     <executed> <failed> <skipped>
#
# The build scripts used to parse the console stream ("✔ Test run with N tests…"),
# which worked only because this toolchain happens to write swift-testing results to
# stdout. That was gap 6: one toolchain change away from miscounting. The XML is the
# runner's own machine-readable record and does not depend on which stream anything
# writes to. The console tee in the calling scripts stays — for humans, and for the
# named-marker greps — but no *count* is read from it any more.
#
# Non-vacuity is enforced here, not merely in the caller:
#
#   * a missing or unparseable file is a failure, never a zero;
#   * the <testsuite> summary attributes must equal the counted <testcase> elements
#     and their counted <failure>/<error> children — the same two-independent-counts
#     rule the console parsers had, now applied to one authoritative document;
#   * a summary that accounts for zero tests exits non-zero unless the caller
#     explicitly passes --allow-empty (used only where an XCTest-only package
#     legitimately reports zero swift-testing tests).
#
# The XCTest runner on this toolchain writes no xUnit file at all (verified on
# Xcode 26.6 / Swift 6.3.3: `swift test --xunit-output x.xml` produces only
# x-swift-testing.xml even when 41 XCTest cases run). Callers with XCTest suites
# therefore keep the console "Executed N tests" line for that half — guarded by a
# declared-count floor so a broken parse fails instead of miscounting.
#
# Usage: xunit-summary.sh [--allow-empty] <path-to-swift-testing.xml>

set -u
set -o pipefail

allow_empty=0
if [ "${1:-}" = "--allow-empty" ]; then
    allow_empty=1
    shift
fi

xml="${1:-}"
if [ -z "${xml}" ]; then
    printf 'xunit-summary: usage: xunit-summary.sh [--allow-empty] <swift-testing.xml>\n' >&2
    exit 2
fi
if [ ! -s "${xml}" ]; then
    printf 'xunit-summary: %s is missing or empty — the runner wrote no machine-readable result\n' "${xml}" >&2
    exit 1
fi

/usr/bin/python3 - "${xml}" "${allow_empty}" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, allow_empty = sys.argv[1], sys.argv[2] == "1"
try:
    root = ET.parse(path).getroot()
except ET.ParseError as error:
    print(f"xunit-summary: {path} is not parseable XML: {error}", file=sys.stderr)
    sys.exit(1)

suites = root.findall(".//testsuite")
if not suites:
    print(f"xunit-summary: {path} holds no <testsuite> element", file=sys.stderr)
    sys.exit(1)

def attr(el, name):
    value = el.get(name)
    if value is None or not value.isdigit():
        print(f"xunit-summary: {path}: <testsuite> lacks a numeric '{name}' attribute", file=sys.stderr)
        sys.exit(1)
    return int(value)

claimed_tests   = sum(attr(s, "tests")    for s in suites)
claimed_failed  = sum(attr(s, "failures") for s in suites) + sum(attr(s, "errors") for s in suites)
claimed_skipped = sum(attr(s, "skipped")  for s in suites)

cases = root.findall(".//testcase")
counted_tests   = len(cases)
counted_failed  = sum(1 for c in cases if c.find("failure") is not None or c.find("error") is not None)
counted_skipped = sum(1 for c in cases if c.find("skipped") is not None)

# Two independent counts, and both must agree — the rule that used to catch a
# truncated console log now catches a truncated or inconsistent XML document.
problems = []
if claimed_tests != counted_tests:
    problems.append(f"summary claims {claimed_tests} tests, document holds {counted_tests} <testcase> elements")
if claimed_failed != counted_failed:
    problems.append(f"summary claims {claimed_failed} failures, document holds {counted_failed} failed cases")
if claimed_skipped != counted_skipped:
    problems.append(f"summary claims {claimed_skipped} skipped, document holds {counted_skipped} skipped cases")
if problems:
    for p in problems:
        print(f"xunit-summary: {path}: {p}", file=sys.stderr)
    sys.exit(1)

if claimed_tests == 0 and not allow_empty:
    print(f"xunit-summary: {path} accounts for zero tests — a gate that parsed zero tests fails", file=sys.stderr)
    sys.exit(1)

print(f"{claimed_tests} {claimed_failed} {claimed_skipped}")
PY
