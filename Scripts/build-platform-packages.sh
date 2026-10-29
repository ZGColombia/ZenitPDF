#!/bin/bash
#
# build-platform-packages.sh — builds and tests the platform packages that no other gate tested:
# image and CAD intake, spreadsheets, measure dictionaries, collaboration, extensions, raster analysis, the AppKit-free
# canvas core, the command-line tool and the Quick Look thumbnail extension.
#
# Before 2026-09-26 these were only *built* for iOS by verify-multiplatform.sh (or linked by build-app.sh). Their test
# suites ran only when somebody happened to run them. Same accounting as build-io-packages.sh: forbidden-API scan,
# skip scan, build, build-tests, swift test with xUnit output, and declared == executed with zero failures and
# zero skips.
set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Packages Tools Apps/QuickLookThumbnail
fi

readonly PACKAGES=(
    "Packages/ZPDFImageIntake"
    "Packages/ZPDFSpreadsheet"
    "Packages/ZPDFDXF"
    "Packages/ZPDFMeasureDictionary"
    "Packages/ZPDFCollaboration"
    "Packages/ZPDFExtensions"
    "Packages/ZPDFRasterAnalysis"
    "Packages/ZPDFCanvasCore"
    "Tools/ZenitCLI"
    "Apps/QuickLookThumbnail"
)

# APIs a package here may not reach for — build-io-packages.sh's list (R-187), applied here since S-121. Most of
# these packages read hostile input: a DXF parsed inside GeometryService, the XLSX reader ZPDFPersistence links,
# images, a Shared Review Folder anyone can write to, extension manifests. Network, subprocess execution and
# dynamic loading are how a parsing bug in one of them becomes something worse than a crash. `Process(` is a
# whole word, so `inProcess(` is not a hit.
readonly FORBIDDEN_APIS=(
    'URLSession' 'NSURLConnection' 'CFURLRequest' 'NWConnection' 'CFSocket' 'getaddrinfo'
    '(^|[^A-Za-z0-9_])Process\(' 'posix_spawn' 'execve?\(' 'NSTask' 'NSAppleScript'
    'dlopen' 'dlsym' 'PDFView' 'JSContext' 'WKWebView'
)

# What a package may use from that list: nothing. The product makes no network connection at all, so no package
# is excused (the update package that once was has been removed).
allowed_apis() { :; }

# The alternation of every forbidden API the package is not allowed.
forbidden_pattern() {
    local package="$1" api allowed pattern=""
    allowed="$(allowed_apis "${package}")"
    for api in "${FORBIDDEN_APIS[@]}"; do
        if [ -n "${allowed}" ] && printf '%s\n' "${allowed}" | grep -qxF -- "${api}"; then continue; fi
        pattern="${pattern:+${pattern}|}${api}"
    done
    printf '%s' "${pattern}"
}

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "$1" "$2"
    printf '=======================================================================\n'
    exit 1
}

# A comment hit is a line whose *content* starts with `//` or `///`, after grep's `file:line:`
# prefix (V-092, U-100's filter from verify-export.sh). The old chain dropped every hit whose line
# held `///` anywhere — a `file:///` URL literal, a trailing doc comment — so a network or
# subprocess call with either on its line passed the gate. `grep -H` keeps the prefix even when a
# batch is one file.
readonly COMMENT_HIT='^[^:]*:[0-9]+:[[:space:]]*(//|///)'
# Self-check: the filter keeps a call with a URL literal or a trailing doc comment on its line and
# drops a real comment.
if ! printf 'Sources/A.swift:13:    let d = try await URLSession.shared.data(from: URL(string: "file:///tmp/x")!)\n' \
        | grep -vE "${COMMENT_HIT}" | grep -q URLSession \
    || ! printf 'Sources/A.swift:14:    let t = Process() /// runs helper\n' \
        | grep -vE "${COMMENT_HIT}" | grep -q 'Process()' \
    || printf 'Sources/A.swift:15:    /// URLSession is forbidden here\n' | grep -vqE "${COMMENT_HIT}" \
    || printf 'Sources/A.swift:16:  // Process() is forbidden here\n' | grep -vqE "${COMMENT_HIT}"; then
    fail "build-platform-packages.sh" "the comment filter self-check (V-092)"
fi

started_at=$(date +%s)
total_tests=0
for package in "${PACKAGES[@]}"; do
    dir="${ROOT}/${package}"
    name="$(basename "${package}")"
    [ -f "${dir}/Package.swift" ] || fail "${package}" "layout (no Package.swift)"
    cd "${dir}" || fail "${package}" "cd"

    printf '\n=== %s : forbidden-API scan ===\n' "${package}"
    if grep -rnHE "$(forbidden_pattern "${package}")" Sources/ 2>/dev/null \
        | grep -vE "${COMMENT_HIT}"; then
        fail "${package}" "forbidden API in a library target (see the matches above)"
    fi
    printf 'no forbidden network, subprocess, dynamic-loading or action-performing API in Sources/.\n'

    printf '\n=== %s : skip scan ===\n' "${package}"
    # `.disabled(` as a swift-testing trait only, so a model enum's own `.disabled(…)` case is not a hit.
    if grep -rnE 'XCTSkip|(@Test|@Suite)[^/]*\.disabled\(|#if false' Tests/ 2>/dev/null; then
        fail "${package}" "a skipped test is a failed test (QUALITY_BAR section 5)"
    fi
    printf 'no skipped, disabled or compiled-out tests.\n'

    printf '\n=== %s : swift build ===\n' "${package}"
    swift build || fail "${package}" "swift build"
    printf '\n=== %s : swift build --build-tests ===\n' "${package}"
    swift build --build-tests || fail "${package}" "swift build --build-tests"

    printf '\n=== %s : swift test ===\n' "${package}"
    xml_dir="$(mktemp -d)" || fail "${package}" "mktemp -d"
    swift test --skip-build --xunit-output "${xml_dir}/results.xml" 2>&1
    status=$?
    [ "${status}" -eq 0 ] || { rm -rf "${xml_dir}"; fail "${package}" "swift test (exit ${status})"; }

    declared="$(grep -rEc '^[[:space:]]*@Test' Tests/ 2>/dev/null | awk -F: '{ sum += $2 } END { print sum + 0 }')"
    counts="$("${ROOT}/Scripts/xunit-summary.sh" "${xml_dir}/results-swift-testing.xml")" \
        || { rm -rf "${xml_dir}"; fail "${package}" "xunit accounting (see above)"; }
    rm -rf "${xml_dir}"
    executed="$(printf '%s' "${counts}" | awk '{print $1}')"
    failed="$(printf '%s' "${counts}" | awk '{print $2}')"
    skipped="$(printf '%s' "${counts}" | awk '{print $3}')"
    printf '\n--- %s : %s declared, %s executed, %s failed, %s skipped (per xUnit XML) ---\n' \
        "${name}" "${declared}" "${executed}" "${failed}" "${skipped}"
    [ "${failed}" -eq 0 ] || fail "${package}" "the xUnit XML records ${failed} failures"
    [ "${skipped}" -eq 0 ] || fail "${package}" "the xUnit XML records ${skipped} skipped tests"
    [ "${declared}" -eq "${executed}" ] || fail "${package}" "test accounting: ${declared} declared but ${executed} executed"
    [ "${executed}" -gt 0 ] || fail "${package}" "test accounting: the suite is empty"
    total_tests=$(( total_tests + executed ))
done

printf '\n=======================================================================\n'
printf 'All %d platform packages built and tested. %d tests declared and executed. (%ds)\n' \
    "${#PACKAGES[@]}" "${total_tests}" "$(( $(date +%s) - started_at ))"
printf '=======================================================================\n'
exit 0
