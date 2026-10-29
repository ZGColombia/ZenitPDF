#!/bin/bash
#
# verify-multiplatform.sh — the ADR-0005 build gate.
#
# ADR-0005 splits the codebase in two: a *portable tier* that must compile for macOS and iOS
# with no AppKit and no UIKit, and a *platform tier* that is macOS-only on purpose. This script
# is the enforcement of the first half. It does two things for every portable package:
#
#   1. Compiles it for an iOS destination.
#   2. Greps its `Sources/` for the imports and platform types that must never appear there,
#      and prints file and line for every hit.
#
# It is a COMPILE GATE ONLY. Zenit PDF claims no iOS support, runs no iOS test, and ships no
# iOS product. The gate exists so that when an iPad stage starts, the work is a user interface
# rather than an archaeology project (ADR-0005 §3).
#
# ---------------------------------------------------------------------------------------------
# Why `swift build --sdk ... --triple`, and not `xcodebuild -destination 'generic/platform=iOS'`
# ---------------------------------------------------------------------------------------------
# Both were tried on this machine (Xcode 26.6, build 17F113, 2026-08-23). xcodebuild refuses:
#
#     xcodebuild: error: Unable to find a destination matching the provided destination
#     specifier: { generic:1, platform:iOS }
#         Ineligible destinations for the "ZPDFContracts" scheme:
#             { platform:iOS, ... error:iOS 26.5 is not installed. Please download and install
#               the platform from Xcode > Settings > Components. }
#
# The iPhoneOS SDK is present on disk — `xcrun --sdk iphoneos --show-sdk-path` resolves it — but
# the iOS *platform component* Xcode's destination resolver requires is not installed, and
# installing a multi-gigabyte simulator runtime is not a precondition anyone should have to meet
# to run a compile gate. SwiftPM needs only the SDK, so that is what this script uses:
#
#     swift build --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --triple arm64-apple-ios17.0
#
# `--triple` alone is not enough — it produces "error: unable to load standard library for target
# 'arm64-apple-ios17.0'" because SwiftPM keeps the macOS sysroot. `--sdk` is what fixes that.
#
# If the iOS platform component is ever installed, switching to xcodebuild is a one-line change
# and would additionally exercise the real device link step. Until then, note the one honest
# limitation of this approach: every Swift and C source file is *compiled* against the iOS SDK,
# but the final link of the few executable targets (zpdf-contract-freeze, zpdf-snap-decision-log,
# zpdf-save-harness) runs clang with the macOS sysroot and says so:
#
#     clang: warning: using sysroot for 'MacOSX' but targeting 'iPhone' [-Wincompatible-sysroot]
#
# That warning is expected and is not suppressed. It concerns linking a command-line tool nobody
# ships; the portability claim this gate makes is about compilation, and compilation is genuine.
#
# Test targets are not built. `swift build` covers the library and executable targets — the code
# that would actually ship — and an engine's test suite is allowed to be macOS-only (it spawns
# subprocesses, kills them, and reads the filesystem afterwards). Portability of the shipping
# code is the property under test here.
#
# ---------------------------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------------------------
# ADR-0005's full portable tier, including the three packages that were under concurrent edit
# when the gate was first written: ZPDFExport, ZPDFRenderer and Bridges/QPDFBridge
# are now rows in PACKAGES like everything else. ZPDFUIPresentation, which ADR-0005 placed on
# the seam, was decided by ADR-0008 (2026-08-24): an audit found zero AppKit in the package —
# its imports are Foundation, Observation and CoreGraphics only — so it joins the portable tier
# whole, with no #if canImport(AppKit) guard and no ZPDFUIPresentationAppKit split.
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

readonly TRIPLE="arm64-apple-ios17.0"

# Scratch lives outside the repository so an iOS build never invalidates the macOS `.build`
# directories that Scripts/build-core-packages.sh and Scripts/build-io-packages.sh rely on.
readonly SCRATCH_ROOT="${TMPDIR:-/tmp}/zenitpdf-multiplatform"

# The portable tier, in dependency order. Do not re-sort: a package will not resolve until the
# path dependencies beneath it have been built at least once.
readonly PACKAGES=(
    "Packages/ZPDFContracts"
    "Packages/ZPDFGeometry"
    "Packages/ZPDFFormulaEngine"
    "Bridges/Clipper2Bridge"
    "Bridges/LibXlsxWriterBridge"
    "Packages/ZPDFMeasurementEngine"
    "Packages/ZPDFRenderer"
    "Packages/ZPDFQuantityLedger"
    "Packages/ZPDFExport"
    "Packages/ZPDFTestingSupport"
    "Bridges/QPDFBridge"
    "Packages/ZPDFVectorExtraction"
    "Packages/ZPDFPDFKitBridge"
    "Packages/ZPDFSnapEngine"
    "Packages/ZPDFPersistence"
    "Packages/ZPDFCompare"
    "Packages/ZPDFSearch"
    "Packages/ZPDFUIPresentation"
    "Packages/ZPDFCanvasCore"
    "Packages/ZPDFCollaboration"
    "Packages/ZPDFAppCore"
    "Packages/ZPDFImageIntake"
    "Packages/ZPDFSpreadsheet"
    "Packages/ZPDFExtensions"
    "Packages/ZPDFRasterAnalysis"
    "Packages/ZPDFDXF"
    "Packages/ZPDFMeasureDictionary"
    "Tests/GoldenMeasurements"
)

# An import of a windowing framework. Anchored at the start of the line so that a *description*
# of the rule — this repository is full of comments and contract strings that say "this package
# cannot import AppKit" — is not mistaken for a violation of it.
readonly FORBIDDEN_IMPORT='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(AppKit|Cocoa|UIKit)([[:space:]]|$)'

# Platform types that have a portable equivalent, and one PDFKit class that must not appear in
# an engine at all. `PDFView` is the only PDFKit object that *performs* a PDF action, which is
# why Scripts/build-io-packages.sh already bans it; it is repeated here because ADR-0005 makes
# the same class a portability problem as well as a security one.
#
# Portable replacements: NSImage -> CGImage, NSColor -> CGColor or ZPDFContracts.RGBAColor,
# NSBezierPath -> CGPath, NSFont -> CTFont, NSScreen/NSApplication/NSWorkspace/NSPasteboard/
# NSDocument/NSUndoManager -> a protocol the platform tier implements.
readonly FORBIDDEN_TYPE='(NSImage|NSColor|NSBezierPath|NSFont|NSPasteboard|NSWorkspace|NSDocument|NSUndoManager|NSScreen|NSApplication|PDFView)'

results=()

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s during %s\n' "$1" "$2"
    printf '=======================================================================\n'
    if [ "${#results[@]}" -gt 0 ]; then
        printf '\n%-34s %-10s %s\n' "PACKAGE" "iOS BUILD" "IMPORT SCAN"
        printf -- '-----------------------------------------------------------------------\n'
        printf '%s\n' "${results[@]}"
    fi
    exit 1
}

# Prints `file:line: text` for every forbidden hit in a package's Sources/, or nothing.
#
# The type scan blanks `//` comments and single-line string literals first, because the
# vocabulary this repository uses to *forbid* AppKit is the same vocabulary that would signal
# AppKit if it were code. A name that occurs only inside a multi-line (`"""`) literal is a known
# false positive; there are none today, and the fix if one appears is to reword the literal, not
# to loosen the scan. The import scan needs no such treatment — it is anchored to real syntax.
# How many files the import scan reads across every package, so a scan that read nothing cannot
# be reported as a clean tier. Added 2026-08-26: this gate had no floor
# of any kind, and `scan_forbidden` returned success for a package with no `Sources` directory
# at all — a renamed package, a moved layout or a typo in PACKAGES would have produced
# "no AppKit, Cocoa or UIKit import" for a directory that was never opened.
#
# Counted in the main shell rather than inside `scan_forbidden`: that function is called in a
# command substitution, and a variable a subshell increments is a variable the caller never
# sees. That is the same class of mistake as the gate this floor exists to prevent, and it is
# worth naming rather than quietly avoiding.
scanned_files=0
count_scannable() {
    find "$1" \( -name '*.swift' -o -name '*.h' -o -name '*.m' \) -type f 2>/dev/null | wc -l | tr -d ' '
}

# Files where a platform type is unavoidable because the Apple API itself takes one, and the file provides
# BOTH platform branches (AppKit and UIKit) under conditional compilation. Each entry is named with the
# reason. The file is still compiled for iOS below, and it must keep a UIKit branch or it is scanned like
# any other file.
#   AnnotationMapping.swift — PDFAnnotation.color / .interiorColor take NSColor or UIColor, and the only way
#   to give PDFKit a translucent colour (annotation opacity, /CA) is through that platform colour; ink strokes are
#   added as NSBezierPath or UIBezierPath, the only type PDFAnnotation.add(_:) accepts.
readonly PLATFORM_BRIDGE_EXEMPT=(
    "Packages/ZPDFPDFKitBridge/Sources/ZPDFPDFKitBridge/PDFKitBacked/AnnotationMapping.swift"
)

is_platform_bridge_exempt() {
    local file="$1" entry
    for entry in "${PLATFORM_BRIDGE_EXEMPT[@]}"; do
        if [ "${file}" = "${ROOT}/${entry}" ] && grep -q 'canImport(UIKit)' "${file}" && grep -q 'UIColor' "${file}"; then
            return 0
        fi
    done
    return 1
}

scan_forbidden() {
    local sources="$1"
    if [ ! -d "${sources}" ]; then
        printf '%s: no Sources directory — this package was not scanned at all\n' "${sources}"
        return 0
    fi

    grep -rnE "${FORBIDDEN_IMPORT}" "${sources}" --include='*.swift' --include='*.h' --include='*.m' 2>/dev/null \
        | while IFS= read -r hit; do
            is_platform_bridge_exempt "${hit%%:*}" || printf '%s\n' "${hit}"
        done

    find "${sources}" \( -name '*.swift' -o -name '*.h' -o -name '*.m' \) -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' file; do
        if is_platform_bridge_exempt "${file}"; then
            printf 'exempt (both platform branches, see PLATFORM_BRIDGE_EXEMPT): %s\n' "${file#"${ROOT}/"}" >&2
            continue
        fi
        sed -e 's/"[^"]*"//g' -e 's://.*::' "${file}" \
            | grep -nE "${FORBIDDEN_TYPE}" \
            | sed "s|^|${file}:|"
    done
}

started_at=$(date +%s)

printf 'Zenit PDF — ADR-0005 multiplatform build gate\n'
printf 'Toolchain: %s\n' "$(swift --version 2>/dev/null | head -1)"

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"
[ -n "${sdk_path}" ] && [ -d "${sdk_path}" ] \
    || fail "toolchain" "no iPhoneOS SDK (xcrun --sdk iphoneos --show-sdk-path returned nothing)"
printf 'Target:    %s\n' "${TRIPLE}"
printf 'SDK:       %s\n' "${sdk_path}"
printf 'Scratch:   %s\n' "${SCRATCH_ROOT}"

mkdir -p "${SCRATCH_ROOT}" || fail "scratch" "mkdir ${SCRATCH_ROOT}"

for package in "${PACKAGES[@]}"; do
    dir="${ROOT}/${package}"
    name="$(basename "${package}")"
    [ -f "${dir}/Package.swift" ] || fail "${package}" "layout (no Package.swift)"

    printf '\n=== %s : manifest declares iOS ===\n' "${package}"
    grep -qE '\.iOS\(\.v17\)' "${dir}/Package.swift" \
        || fail "${package}" "manifest does not declare .iOS(.v17) (ADR-0005 §2)"
    grep -qE '\.swiftLanguageMode\(\.v6\)' "${dir}/Package.swift" \
        || fail "${package}" "manifest lost .swiftLanguageMode(.v6)"
    printf 'platforms: [.macOS(.v14), .iOS(.v17)], Swift 6 language mode.\n'

    printf '\n=== %s : forbidden-import scan ===\n' "${package}"
    if [ -d "${dir}/Sources" ]; then
        scanned_files=$(( scanned_files + $(count_scannable "${dir}/Sources") ))
    fi
    hits="$(scan_forbidden "${dir}/Sources")"
    if [ -n "${hits}" ]; then
        printf '%s\n' "${hits}"
        results+=("$(printf '%-34s %-10s %s' "${name}" "-" "FAIL")")
        fail "${package}" "AppKit/UIKit/Cocoa or a platform type in the portable tier (see above)"
    fi
    printf 'no AppKit, Cocoa or UIKit import; no platform image, colour, path, font, pasteboard,\n'
    printf 'workspace, document, undo-manager, screen, application or PDFView type.\n'

    printf '\n=== %s : swift build (%s) ===\n' "${package}" "${TRIPLE}"
    log="$(mktemp)" || fail "${package}" "mktemp"
    (
        cd "${dir}" || exit 1
        swift build \
            --scratch-path "${SCRATCH_ROOT}/${name}" \
            --sdk "${sdk_path}" \
            --triple "${TRIPLE}"
    ) > "${log}" 2>&1
    status=$?
    if [ "${status}" -ne 0 ]; then
        grep -E 'error:' "${log}" | sort -u | head -40
        printf '(full log: %s)\n' "${log}"
        results+=("$(printf '%-34s %-10s %s' "${name}" "FAIL" "pass")")
        fail "${package}" "swift build for ${TRIPLE} (exit ${status})"
    fi
    tail -1 "${log}"
    rm -f "${log}"

    results+=("$(printf '%-34s %-10s %s' "${name}" "PASS" "pass")")
done

# The non-vacuity floor. The nineteen portable packages held 462 scannable
# `.swift`, `.h` and `.m` files when this floor was written, 2026-08-26. A run that reads fewer
# is reading less of the portable tier than the last one did, and "no AppKit import" is only a
# statement about files that were actually opened.
readonly MIN_SCANNED_FILES=462
if [ "${scanned_files}" -lt "${MIN_SCANNED_FILES}" ]; then
    printf '\nFAILED: the import scan read %s file(s) across %s package(s); the floor is %s.\n' \
        "${scanned_files}" "${#PACKAGES[@]}" "${MIN_SCANNED_FILES}" >&2
    printf '        "no AppKit import" is a statement about files that were read. A gate that\n' >&2
    printf '        examined nothing does not pass.\n' >&2
    exit 1
fi

printf '\n=======================================================================\n'
printf 'import scan: %s files read across %s packages (floor %s)\n' \
    "${scanned_files}" "${#PACKAGES[@]}" "${MIN_SCANNED_FILES}"
printf '%-34s %-10s %s\n' "PACKAGE" "iOS BUILD" "IMPORT SCAN"
printf -- '-----------------------------------------------------------------------\n'
printf '%s\n' "${results[@]}"
printf -- '-----------------------------------------------------------------------\n'
printf 'All %d portable packages compile for %s and are free of AppKit/UIKit apart from %d named dual-platform bridge file(s). (%ds)\n' \
    "${#PACKAGES[@]}" "${TRIPLE}" "${#PLATFORM_BRIDGE_EXEMPT[@]}" "$(( $(date +%s) - started_at ))"
printf 'Compile gate only: no iOS support is claimed and no iOS product is shipped.\n'
printf '=======================================================================\n'
exit 0
