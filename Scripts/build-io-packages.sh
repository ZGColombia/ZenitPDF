#!/bin/bash
#
# build-io-packages.sh — the verification command for the Zenit PDF document-IO and
# persistence packages.
#
# Builds and tests every package that touches the filesystem or a PDF, in dependency order:
#
#     Packages/ZPDFTestingSupport   synthetic PDF corpus + fuzz mutators, no dependencies
#     Packages/ZPDFVectorExtraction -> TestingSupport (test target only)
#     Packages/ZPDFPDFKitBridge     -> TestingSupport (test target only)
#     Packages/ZPDFPersistence      -> GRDB
#     Packages/ZPDFSearch           -> Persistence + PDFKitBridge, Vision for on-device OCR
#     Packages/ZPDFCompare          -> PDFKitBridge, VectorExtraction, TestingSupport (tests)
#     Packages/ZPDFServiceClient    -> VectorExtraction, PDFKitBridge, Compare, DXF, QPDFBridge,
#                                      TestingSupport (tests): the XPC/process isolation boundary
#
# ZPDFTestingSupport comes first because the others resolve it as a path dependency and
# their test targets will not link until it has been built once. SwiftPM resolves the path
# dependencies itself, so the order is for the reader. ZPDFServiceClient comes last: it
# depends on three of the others (R-187 — no gate ran it before, so its crash-isolation,
# hang-deadline and "qpdf is not linked into the app" tests never executed).
#
# Beyond build and test, this script enforces three properties that a green test run does not
# by itself prove, and that are the whole reason these packages are held to a stricter bar:
#
#   1. Every test that is *defined* was actually *executed*. A suite that compiles but never
#      runs has already shipped once in this repository. The count of `@Test` declarations is
#      compared against the count swift-testing reports as passed.
#   2. No skips. A skipped test is a failed test (`QUALITY_BAR.md` section 5).
#   3. No network, no subprocess execution, no dynamic loading from any library target. A PDF
#      is hostile data; these packages parse it and must not be able to phone anywhere.
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
    "${ROOT}/Scripts/wave-marker.sh" check Packages
fi


# Dependency order. Do not re-sort.
readonly PACKAGES=(
    "Packages/ZPDFTestingSupport"
    "Packages/ZPDFVectorExtraction"
    "Packages/ZPDFPDFKitBridge"
    "Packages/ZPDFPersistence"
    "Packages/ZPDFCompare"
    "Packages/ZPDFSearch"
    "Packages/ZPDFServiceClient"
)

# APIs no package here may reach for. Network and subprocess execution are the two ways a
# malformed PDF could turn a parsing bug into something worse than a crash; `dlopen` is the
# third. `PDFView` is PDFKit's only object that performs a PDF action.
#
# `Process(` is matched as a whole word, so `extractInProcess(` and `.inProcess(` are not
# subprocess execution.
readonly FORBIDDEN='URLSession|NSURLConnection|CFURLRequest|NWConnection|CFSocket|getaddrinfo|(^|[^A-Za-z0-9_])Process\(|posix_spawn|execve?\(|NSTask|NSAppleScript|dlopen|dlsym|PDFView|JSContext|WKWebView'

# The one file allowed to spawn a process: the isolation boundary's subprocess transport,
# whose whole purpose is to run the parser somewhere a hostile PDF cannot reach the app.
readonly SUBPROCESS_ALLOWED='^Sources/ZPDFServiceClient/WireSubprocessConnection\.swift:[0-9]+:[[:space:]]*let process = Process\(\)$'

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "$1" "$2"
    printf '=======================================================================\n'
    exit 1
}

# A comment hit is a line whose *content* starts with `//` or `///`, after grep's `file:line:`
# prefix (V-092, U-100's filter from verify-export.sh). The old chain dropped every hit whose line
# held `///` anywhere — a `file:///` URL literal, a trailing doc comment — so
# `URLSession.shared.data(from: URL(string: "file:///tmp/x")!)` and `let t = Process() /// runs
# helper` both passed the gate. `grep -H` keeps the prefix even when a batch is one file.
readonly COMMENT_HIT='^[^:]*:[0-9]+:[[:space:]]*(//|///)'
# Self-check: the filter keeps a call with a URL literal or a trailing doc comment on its line,
# drops a real comment, and the one subprocess exception still matches its line.
if ! printf 'Sources/A.swift:13:    let d = try await URLSession.shared.data(from: URL(string: "file:///tmp/x")!)\n' \
        | grep -vE "${COMMENT_HIT}" | grep -q URLSession \
    || ! printf 'Sources/A.swift:14:    let t = Process() /// runs helper\n' \
        | grep -vE "${COMMENT_HIT}" | grep -q 'Process()' \
    || printf 'Sources/A.swift:15:    /// URLSession is forbidden here\n' | grep -vqE "${COMMENT_HIT}" \
    || printf 'Sources/A.swift:16:  // Process() is forbidden here\n' | grep -vqE "${COMMENT_HIT}" \
    || ! printf 'Sources/ZPDFServiceClient/WireSubprocessConnection.swift:9:        let process = Process()\n' \
        | grep -qE "${SUBPROCESS_ALLOWED}"; then
    fail "build-io-packages.sh" "the comment filter self-check (V-092)"
fi

started_at=$(date +%s)
total_tests=0

for package in "${PACKAGES[@]}"; do
    dir="${ROOT}/${package}"
    name="$(basename "${package}")"
    [ -f "${dir}/Package.swift" ] || fail "${package}" "layout (no Package.swift)"
    cd "${dir}" || fail "${package}" "cd"

    printf '\n=== %s : forbidden-API scan ===\n' "${package}"
    if grep -rnHE "${FORBIDDEN}" Sources/ 2>/dev/null | grep -vE "${COMMENT_HIT}" \
        | grep -vE "${SUBPROCESS_ALLOWED}"; then
        fail "${package}" "forbidden API in a library target (see the matches above)"
    fi
    printf 'no network, subprocess, dynamic-loading or action-performing API in Sources/.\n'

    printf '\n=== %s : skip scan ===\n' "${package}"
    if grep -rnE 'XCTSkip|\.disabled\(|#if false' Tests/ 2>/dev/null | grep -v 'backgroundFilter'; then
        fail "${package}" "a skipped test is a failed test (QUALITY_BAR section 5)"
    fi
    printf 'no skipped, disabled or compiled-out tests.\n'

    printf '\n=== %s : swift build ===\n' "${package}"
    swift build || fail "${package}" "swift build"

    # The build of the test targets is a separate step, and not for speed. `swift test`
    # writes SwiftPM's compile progress to stdout while swift-testing writes its results to
    # stderr; merging two live writers into one pipe with `2>&1 |` interleaves them mid-line,
    # and a result line with a build line glued to its front no longer begins with the marker
    # the accounting counts. That was observed in this repository: a run of 69 tests counted
    # as 18. Compiling first leaves nothing else writing to stdout during the measured run.
    printf '\n=== %s : swift build --build-tests ===\n' "${package}"
    swift build --build-tests || fail "${package}" "swift build --build-tests"

    printf '\n=== %s : swift test ===\n' "${package}"
    log="$(mktemp)" || fail "${package}" "mktemp"
    xml_dir="$(mktemp -d)" || fail "${package}" "mktemp -d"
    swift test --xunit-output "${xml_dir}/results.xml" 2>&1 | tee "${log}"
    status="${PIPESTATUS[0]}"
    rm -f "${log}"
    [ "${status}" -eq 0 ] || { rm -rf "${xml_dir}"; fail "${package}" "swift test (exit ${status})"; }

    # Executed-versus-declared. swift-testing counts a parameterised `@Test` once, which is
    # the same way it is declared, so the two numbers are directly comparable.
    declared="$(grep -rEc '^[[:space:]]*@Test' Tests/ 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"

    # The executed and failed counts come from the xUnit XML the runner itself writes, never
    # from the console stream (console parsing rests on the toolchain happening to write
    # results to stdout). Scripts/xunit-summary.sh refuses a missing,
    # unparseable, internally inconsistent or empty document, so a gate that parsed zero
    # tests still fails. The tee above stays for humans.
    counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
        || { rm -rf "${xml_dir}"; fail "${package}" "xunit accounting (see above)"; }
    rm -rf "${xml_dir}"
    executed="$(printf '%s' "${counts}" | awk '{print $1}')"
    failed="$(printf '%s' "${counts}" | awk '{print $2}')"
    skipped="$(printf '%s' "${counts}" | awk '{print $3}')"

    printf '\n--- %s : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
        "${name}" "${declared}" "${executed}" "${failed}" "${skipped}"
    if [ "${failed}" -ne 0 ]; then
        fail "${package}" "the xUnit XML records ${failed} failures"
    fi
    if [ "${skipped}" -ne 0 ]; then
        fail "${package}" "the xUnit XML records ${skipped} skipped tests (a skipped test is a failed test)"
    fi
    if [ "${declared}" -ne "${executed}" ]; then
        fail "${package}" "test accounting: ${declared} declared but ${executed} executed"
    fi
    if [ "${executed}" -eq 0 ]; then
        fail "${package}" "test accounting: the suite is empty"
    fi
    total_tests=$(( total_tests + executed ))

    # The in-process fuzz suites measure time and resident growth after a
    # call *returns*, so a true hang wedges the runner instead of failing it. The two fuzz
    # packages are re-run out of process under Scripts/fuzz-harness.sh, which SIGKILLs the
    # child tree on a wall-clock or RSS breach. Iteration counts are the suites' own,
    # unchanged (500 mutated documents each).
    case "${name}" in
        ZPDFVectorExtraction)
            printf '\n=== %s : fuzz sweep under the out-of-process watchdog ===\n' "${package}"
            "${ROOT}/Scripts/fuzz-harness.sh" "${dir}" "FuzzExtractionTests" 900 2048 \
                || fail "${package}" "fuzz-harness (FuzzExtractionTests)"
            ;;
        ZPDFPDFKitBridge)
            printf '\n=== %s : fuzz sweep under the out-of-process watchdog ===\n' "${package}"
            "${ROOT}/Scripts/fuzz-harness.sh" "${dir}" "FuzzRegressionTests" 900 2048 \
                || fail "${package}" "fuzz-harness (FuzzRegressionTests)"
            ;;
        ZPDFPersistence)
            # A performance number measured in debug measures the compiler,
            # not the layer. The 100 000-row envelope runs again here, optimised and isolated.
            printf '\n=== %s : performance suite (release, isolated) ===\n' "${package}"
            swift build -c release --build-tests || fail "${package}" "swift build -c release --build-tests"
            # Accounted like the debug run (R-204): a `--filter` that matches nothing exits 0,
            # so a renamed suite used to pass this step having run nothing. xunit-summary.sh
            # refuses an empty document, and the executed count must cover every @Test the
            # suite declares.
            perf_xml="$(mktemp -d)" || fail "${package}" "mktemp -d (performance)"
            swift test -c release --skip-build --filter PerformanceTests \
                --xunit-output "${perf_xml}/results.xml" \
                || { rm -rf "${perf_xml}"; fail "${package}" "performance suite in release"; }
            perf_counts="$("${ROOT}/Scripts/xunit-summary.sh" "${perf_xml}/results-swift-testing.xml")" \
                || { rm -rf "${perf_xml}"; fail "${package}" "performance suite accounting (see above)"; }
            rm -rf "${perf_xml}"
            perf_executed="$(printf '%s' "${perf_counts}" | awk '{print $1}')"
            perf_failed="$(printf '%s' "${perf_counts}" | awk '{print $2}')"
            perf_declared="$(grep -Ec '^[[:space:]]*@Test' Tests/ZPDFPersistenceTests/PerformanceTests.swift 2>/dev/null || echo 0)"
            printf -- '--- %s release performance: %s declared, %s executed, %s failed ---\n' \
                "${name}" "${perf_declared}" "${perf_executed}" "${perf_failed}"
            [ "${perf_failed}" -eq 0 ] || fail "${package}" "performance suite: ${perf_failed} failures"
            [ "${perf_executed}" -gt 0 ] || fail "${package}" "performance suite ran nothing"
            [ "${perf_executed}" -eq "${perf_declared}" ] \
                || fail "${package}" "performance suite: ${perf_declared} declared but ${perf_executed} executed"
            ;;
    esac
done

printf '\n=======================================================================\n'
printf 'All %d IO packages built and tested. %d tests declared and executed. (%ds)\n' \
    "${#PACKAGES[@]}" "${total_tests}" "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
