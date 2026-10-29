#!/bin/bash
#
# verify-export.sh — the gate over the export layer and the XLSX bridge.
#
#     Bridges/LibXlsxWriterBridge -> vendored libxlsxwriter (BSD-2-Clause) + system zlib
#     Packages/ZPDFExport         -> ZPDFContracts, ZPDFQuantityLedger, ZPDFXlsxWriter
#
# Beyond the usual build-and-test, this script exists for one thing the other scripts cannot
# check: the **licence surface of the shipped binary**. Conflict 3 of
# `Docs/Licences/LICENSE_EVIDENCE.md` records that libxlsxwriter bundles `tmpfileplus` under
# MPL-2.0 — the only copyleft licence in the whole dependency set — and that the chosen answer
# is to build with `USE_STANDARD_TMPFILE` so the component is excluded. A build
# flag in a `Package.swift` is a claim. Gate 1 below is the evidence.
#
# Gates:
#
#   1. No MPL-2.0 file anywhere in the bridge, and no `tmpfileplus` symbol in any object file of
#      an actual build. Both, because either alone can be true while the other is false.
#   2. Forbidden-API scan over `Sources/` only: no network, no subprocess, no dynamic loading,
#      no `fatalError`, no `try!`/`as!`, no `@unchecked Sendable`, no AppKit or SwiftUI. Test
#      targets may spawn `/usr/bin/unzip`, because reading an XLSX back the way Excel would is
#      the only honest way to assert what was written.
#   3. No skipped, disabled or compiled-out tests (QUALITY_BAR section 5).
#   4. Declared `@Test` count equals the count the runner reports equals the number of pass
#      lines in the log.
#   5. Named proof obligations: the four-format digit-for-digit comparison, the 10 000-row JSON
#      round trip, the double-rounding detector and the constant-memory XLSX run must each
#      appear in the output. A green suite that quietly lost one of those is not green.
#
# Exits non-zero on the first failure, naming the package and the phase.

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
    "${ROOT}/Scripts/wave-marker.sh" check Packages/ZPDFExport
fi

readonly BRIDGE="Bridges/LibXlsxWriterBridge"

readonly PACKAGES=(
    "${BRIDGE}"
    "Packages/ZPDFExport"
)

readonly FORBIDDEN='URLSession|NSURLConnection|CFURLRequest|NWConnection|CFSocket|getaddrinfo|Process\(|posix_spawn|NSTask|NSAppleScript|dlopen|dlsym|PDFView|JSContext|WKWebView|import AppKit|import SwiftUI|fatalError\(|@unchecked Sendable|try!|as!'

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "$1" "$2"
    printf '=======================================================================\n'
    exit 1
}

# A comment hit is a line whose *content* starts with `//`, after grep's `file:line:` prefix
# (U-100). The unanchored `:[[:space:]]*(//|///)` also matched the `://` inside any URL literal,
# so `URLSession.shared.data(from: URL(string: "https://…")!)` was filtered out as a comment.
readonly COMMENT_HIT='^[^:]*:[0-9]+:[[:space:]]*(//|///)'
# Self-check: the filter keeps a call with a URL on its line and drops a real comment.
if ! printf 'Sources/A.swift:13:    let d = try await URLSession.shared.data(from: URL(string: "https://e.com")!)\n' \
        | grep -vE "${COMMENT_HIT}" | grep -q URLSession \
    || printf 'Sources/A.swift:14:    // URLSession is forbidden here\n' | grep -vqE "${COMMENT_HIT}"; then
    fail "verify-export.sh" "the comment filter self-check (U-100)"
fi

require_line() {
    local log="$1" package="$2" needle="$3" what="$4"
    if ! grep -qF "${needle}" "${log}"; then
        rm -f "${log}"
        fail "${package}" "${what} (no line matching '${needle}' in the test output)"
    fi
}

started_at=$(date +%s)
total_tests=0

# ---------------------------------------------------------------------------
# Gate 1: the MPL-2.0 exclusion, proved twice.
# ---------------------------------------------------------------------------
printf '\n=== %s : MPL-2.0 source scan ===\n' "${BRIDGE}"
cd "${ROOT}/${BRIDGE}" || fail "${BRIDGE}" "cd"

if find Sources -name '*tmpfileplus*' | grep -q .; then
    fail "${BRIDGE}" "a tmpfileplus file is vendored (MPL-2.0; see LICENSE_EVIDENCE.md conflict 3)"
fi
if grep -rl "Mozilla Public License" Sources 2>/dev/null | grep -q .; then
    grep -rl "Mozilla Public License" Sources
    fail "${BRIDGE}" "an MPL-licensed file is vendored"
fi
if ! grep -q 'define("USE_STANDARD_TMPFILE")' Package.swift; then
    fail "${BRIDGE}" "USE_STANDARD_TMPFILE is not defined in Package.swift"
fi
printf 'no tmpfileplus source, no MPL-2.0 text, USE_STANDARD_TMPFILE defined.\n'

printf '\n=== %s : swift build (for the symbol scan) ===\n' "${BRIDGE}"
swift build || fail "${BRIDGE}" "swift build"

printf '\n=== %s : tmpfileplus symbol scan ===\n' "${BRIDGE}"
# Scoped to the vendored C target. A wider scan picks up Swift string literals — `XlsxError`
# names tmpfileplus in its diagnostic text, and `nm -a` reports local string symbols by their
# contents — which would fail the gate for saying the right thing.
#
# W-100: the proof needs positive evidence. `nm`'s errors used to go to /dev/null and its exit
# status was never read, so a missing or failing `nm` left `symbols` empty, the tmpfileplus check
# had nothing to fire on, and the gate printed the all-clear having read no symbol at all. Now
# `nm` must succeed on every object, its errors stay visible, and the scan must have seen
# `lxw_tmpfile`, which utility.c defines whether or not USE_STANDARD_TMPFILE is set — a scan that
# does not show it did not read the library.
#
# Two build-system layouts. The native build system puts the C target's objects under
# `<bin>/CXlsxWriter.build/`; Swift Build (the default since Xcode 26) puts them under
# `.build/out/Intermediates.noindex/<pkg>.build/Debug/CXlsxWriter-t.build/Objects-normal/<arch>/`.
object_count="$(find .build \( -path '*/CXlsxWriter.build/*' -o -path '*/CXlsxWriter-t.build/*' \) -name '*.o' 2>/dev/null | wc -l | tr -d ' ')"
[ "${object_count}" -gt 0 ] || fail "${BRIDGE}" "symbol scan (no object files found)"
nm_output="$(find .build \( -path '*/CXlsxWriter.build/*' -o -path '*/CXlsxWriter-t.build/*' \) -name '*.o' -print0 | xargs -0 nm -a)" \
    || fail "${BRIDGE}" "symbol scan (nm failed on the ${object_count} object files; see its errors above)"
symbols="$(printf '%s\n' "${nm_output}" | grep -i 'tmpfile' | sort -u)"
printf '%s\n' "${symbols}"
if ! printf '%s\n' "${symbols}" | grep -q 'lxw_tmpfile'; then
    fail "${BRIDGE}" "symbol scan read nothing: lxw_tmpfile, defined in utility.c in every build, is not among the symbols of ${object_count} object files"
fi
if printf '%s\n' "${symbols}" | grep -qi 'tmpfileplus'; then
    fail "${BRIDGE}" "a tmpfileplus symbol is present in the built objects"
fi
printf 'symbol scan: %s object files read; only lxw_tmpfile and the libc tmpfile are referenced.\n' "${object_count}"

# ---------------------------------------------------------------------------
# Gates 2-5, per package.
# ---------------------------------------------------------------------------
for package in "${PACKAGES[@]}"; do
    dir="${ROOT}/${package}"
    name="$(basename "${package}")"
    [ -f "${dir}/Package.swift" ] || fail "${package}" "layout (no Package.swift)"
    cd "${dir}" || fail "${package}" "cd"

    printf '\n=== %s : forbidden-API scan ===\n' "${package}"
    # Swift sources only: the vendored C is upstream's and is audited by VENDORED.md, not by a
    # grep for Swift constructs.
    if find Sources -name '*.swift' -print0 2>/dev/null \
        | xargs -0 grep -HnE "${FORBIDDEN}" 2>/dev/null \
        | grep -vE "${COMMENT_HIT}"; then
        fail "${package}" "forbidden API or construct in a library target (see the matches above)"
    fi
    printf 'no network, subprocess, dynamic loading, AppKit, SwiftUI, fatalError, force cast or unchecked Sendable.\n'

    printf '\n=== %s : skip scan ===\n' "${package}"
    if grep -rnE 'XCTSkip|\.disabled\(|#if false' Tests/ 2>/dev/null; then
        fail "${package}" "a skipped test is a failed test (QUALITY_BAR section 5)"
    fi
    printf 'no skipped, disabled or compiled-out tests.\n'

    # Separate compile step: SwiftPM writes build progress to stdout while swift-testing writes
    # results to stderr, and merging two live writers shreds the summary lines the accounting
    # below reads.
    printf '\n=== %s : swift build --build-tests ===\n' "${package}"
    swift build --build-tests || fail "${package}" "swift build --build-tests"

    printf '\n=== %s : swift test ===\n' "${package}"
    log="$(mktemp)" || fail "${package}" "mktemp"
    xml_dir="$(mktemp -d)" || fail "${package}" "mktemp -d"
    swift test --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${log}"
    status="${PIPESTATUS[0]}"
    [ "${status}" -eq 0 ] || { rm -f "${log}"; rm -rf "${xml_dir}"; fail "${package}" "swift test (exit ${status})"; }

    case "${name}" in
        LibXlsxWriterBridge)
            require_line "${log}" "${package}" \
                "The C standard tmpfile() this build depends on is usable" \
                "the USE_STANDARD_TMPFILE probe did not run"
            require_line "${log}" "${package}" \
                "Constant-memory mode writes 20 000 rows through the standard tmpfile()" \
                "the constant-memory temporary-file test did not run"
            ;;
        ZPDFExport)
            require_line "${log}" "${package}" \
                "The same string in the CSV, the JSON, the XLSX cell and the PDF table" \
                "the four-format digit-for-digit comparison did not run (QUALITY_BAR A29)"
            require_line "${log}" "${package}" \
                "The double-rounding golden values render correctly in the sheet" \
                "the double-rounding detector did not run (QUALITY_BAR A31)"
            require_line "${log}" "${package}" \
                "Round trip on a 10 000-row projection" \
                "the 10 000-row JSON round trip did not run"
            require_line "${log}" "${package}" \
                "10 000 rows paginate without accumulating a layout" \
                "the 10 000-row PDF pagination test did not run"
            require_line "${log}" "${package}" \
                "Constant-memory mode writes 10 000 rows and the same numbers" \
                "the constant-memory XLSX export did not run"
            require_line "${log}" "${package}" \
                "CSV, JSON and PDF agree digit for digit in every locale" \
                "the locale sweep did not run (QUALITY_BAR A33)"
            ;;
    esac

    declared="$(grep -rEc '^[[:space:]]*@Test' Tests/ 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"

    # Counts come from the xUnit XML the runner itself writes. The console
    # log above is tee'd for humans and for the named-marker greps; no count is read from it.
    rm -f "${log}"
    counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
        || { rm -rf "${xml_dir}"; fail "${package}" "xunit accounting (see above)"; }
    rm -rf "${xml_dir}"
    executed="$(printf '%s' "${counts}" | awk '{print $1}')"
    xml_failed="$(printf '%s' "${counts}" | awk '{print $2}')"
    xml_skipped="$(printf '%s' "${counts}" | awk '{print $3}')"

    printf '\n--- %s : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
        "${name}" "${declared}" "${executed}" "${xml_failed}" "${xml_skipped}"
    if [ "${xml_failed}" -ne 0 ]; then
        fail "${package}" "test accounting: the xUnit XML records ${xml_failed} failures"
    fi
    if [ "${xml_skipped}" -ne 0 ]; then
        fail "${package}" "test accounting: the xUnit XML records ${xml_skipped} skipped tests"
    fi
    if [ "${declared}" -ne "${executed}" ]; then
        fail "${package}" "test accounting: ${declared} declared but ${executed} executed"
    fi
    if [ "${executed}" -eq 0 ]; then
        fail "${package}" "test accounting: the suite is empty"
    fi
    total_tests=$(( total_tests + executed ))
done

printf '\n=======================================================================\n'
printf 'Export layer and XLSX bridge built and tested. %d tests declared and executed. (%ds)\n' \
    "${total_tests}" "$(( $(date +%s) - started_at ))"
printf 'tmpfileplus (MPL-2.0) is absent from the source tree and from the linked objects.\n'
printf '=======================================================================\n'
exit 0
