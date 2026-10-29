#!/bin/bash
#
# verify-localization.sh — how far Swedish is, and whether what exists is safe (NL-PLAT-19).
#
# The rule: a secondary language ships complete or not at all.
# Scripts/build-app.sh ships only en.lproj until Swedish covers every key. This script is the
# tracker that makes "how close is it" a number instead of a guess:
#
#   - collects every key the code asks for: NSLocalizedString("…") and String(localized: "…") in
#     Apps/*/Sources and Packages/*/Sources (string literals only; a key built at run time cannot
#     be counted and is not);
#   - prints `sv: <covered>/<total> (<percent>)`, then the missing keys grouped by package;
#   - FAILS on a Swedish entry whose format conversions (%@, %d, %lld, %1$@ …) differ from the
#     English key's — that entry would crash or print garbage the day Swedish ships;
#   - FAILS on a missing Swedish key only with --strict or ZENIT_REQUIRE_SWEDISH=1, the
#     switch for the day Swedish is meant to ship. Without it, missing keys are reported, not fatal.
#
# Usage: Scripts/verify-localization.sh [--strict] [--list N]   (N missing keys per package, default 10)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT="${ZENIT_REQUIRE_SWEDISH:-0}"
LIST=10
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        --list) LIST="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "verify-localization.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

exec /usr/bin/env python3 - "$ROOT" "$STRICT" "$LIST" <<'PY'
import os, re, sys, collections
root, strict, listn = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3])

literal = r'"((?:[^"\\\n]|\\.)*)"'
patterns = [re.compile(r'NSLocalizedString\(\s*' + literal), re.compile(r'String\(\s*localized:\s*' + literal)]

def unescape(s):
    return (s.replace('\\"', '"').replace('\\n', '\n').replace('\\t', '\t').replace('\\\\', '\\'))

keys = collections.OrderedDict()
for top in ("Apps", "Packages"):
    base = os.path.join(root, top)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if not d.startswith(".build") and d != "Tests"]
        if "/Sources" not in dirpath.replace(base, ""):
            continue
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            package = os.path.relpath(path, base).split(os.sep)[0]
            text = open(path, encoding="utf-8", errors="replace").read()
            for pattern in patterns:
                for match in pattern.finditer(text):
                    # Adjacent literals joined with + (a key split over lines) are skipped: only
                    # whole literals are counted, never half a key.
                    tail = text[match.end():match.end() + 8].lstrip()
                    if tail.startswith("+"):
                        continue
                    keys.setdefault(unescape(match.group(1)), package)

def catalogue(lang):
    path = os.path.join(root, "Apps/ZenitPDF/Bundle", lang + ".lproj", "Localizable.strings")
    text = open(path, encoding="utf-8").read()
    entries = {}
    for match in re.finditer(r'^\s*' + literal + r'\s*=\s*' + literal + r'\s*;', text, re.M):
        entries[unescape(match.group(1))] = unescape(match.group(2))
    return entries

sv = catalogue("sv")
spec = re.compile(r'%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(ll|l|h|hh|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])')
def conversions(s):
    found = []
    for position, m in enumerate(spec.finditer(s)):
        if m.group(3) == "%":
            continue
        found.append((m.group(1) or str(position + 1), (m.group(2) or "") + m.group(3)))
    return sorted(found)

total = len(keys)
covered = [k for k in keys if k in sv]
missing = collections.defaultdict(list)
for k, package in keys.items():
    if k not in sv:
        missing[package].append(k)

mismatches = []
for k, value in sv.items():
    if conversions(k) != conversions(value):
        mismatches.append((k, value))

percent = 100.0 * len(covered) / total if total else 100.0
print(f"sv: {len(covered)}/{total} ({percent:.1f} %)")
for package in sorted(missing, key=lambda p: -len(missing[p])):
    items = missing[package]
    print(f"  {package}: {len(items)} missing")
    for k in items[:listn]:
        print("      " + k.replace("\n", "\\n")[:110])
status = 0
if mismatches:
    print(f"FAILED: {len(mismatches)} Swedish entries change the format conversions of their key:")
    for k, v in mismatches[:50]:
        print(f"  \"{k}\" -> \"{v}\"")
    status = 1
if strict and len(covered) < total:
    print(f"FAILED: Swedish is required (--strict / ZENIT_REQUIRE_SWEDISH=1) and {total - len(covered)} keys have no Swedish string.")
    status = 1
if status == 0:
    print("ok: every Swedish entry keeps its key's conversions" + ("" if strict else "; missing keys are reported, not fatal (pass --strict to require them)"))
sys.exit(status)
PY
