#!/bin/bash
#
# build-app.sh — assembles Zenit PDF.app from a clean tree.
#
# What it does, in order:
#
#   1. builds the executable release twice, once per architecture;
#   2. lipos the two slices into one Universal 2 binary;
#   3. assembles the bundle: Info.plist, icons, the English localization catalogue, PkgInfo,
#      licence notices, Shortcuts metadata, the two XPC services, the two Quick Look extensions
#      and the `zenit` command-line tool;
#   4. signs it with Hardened Runtime and the App Sandbox entitlements, innermost code
#      first (our XPC services, extensions and helper, then the app);
#   5. verifies the signature, reports what `spctl` says about it, and runs the bundle gates:
#      licence notices, competitor names, dynamic linkage and the no-network inspection.
#
# The application has no updater and makes no network connection. A newer version is installed
# by downloading it from the project's GitHub releases page.
#
# ---------------------------------------------------------------------------------------------
# Why the build is two invocations rather than `--arch arm64 --arch x86_64`
# ---------------------------------------------------------------------------------------------
# SwiftPM can emit a universal binary in one pass, but it puts both slices through one build
# graph, so a failure in either architecture reports against a merged log and the per-slice
# artefacts are gone. Building each slice into its own product directory and running `lipo`
# explicitly means a cross-compilation failure names its architecture, and the two inputs to the
# fat binary are on disk to inspect.
#
# ---------------------------------------------------------------------------------------------
# Signing — every published release is ad-hoc; the certificate is a local maintainer option
# ---------------------------------------------------------------------------------------------
# There is no Apple Developer ID and no notarization, so `spctl --assess` rejects every build.
# That rejection is expected, printed rather than suppressed, and does not fail the build. What a
# signature does buy is real: entitlements are attached, so the sandbox and the Hardened Runtime
# are in force, and `codesign --verify` proves the bundle is intact. Scripts/lib/zenit-codesign.sh
# holds the details; the two modes are:
#
#   default (no environment variable)
#       Ad-hoc signed, with the explicit designated requirement `identifier "com.zenitgroup.
#       zenitpdf"` so consecutive builds keep one identity. No certificate, no keychain access and
#       no pin check: this is the build for contributors, CI and anyone building from source.
#
#   ZENIT_RELEASE_SIGNING=1
#       A maintainer option for local builds, never used for published releases
#       (.github/workflows/release.yml signs ad-hoc). Signs with the self-signed certificate "Zenit PDF Code Signing
#       (self-signed)" from the login keychain (or ZENIT_CODESIGN_IDENTITY), stops if it is
#       missing, and fails unless the signed bundle's designated requirement equals the pin in
#       Apps/ZenitPDF/Bundle/DesignatedRequirement.txt. A sandboxed app's container and its
#       security-scoped bookmarks are tied to that requirement, so the pin changes only on purpose.
#
# Usage:  Scripts/build-app.sh [--output DIR] [--short-version X.Y.Z] [--build-version N]
#                              [--scratch-path NAME] [--skip-verify]
#
#   --short-version X.Y.Z  CFBundleShortVersionString (default 1.0.0); a release passes its tag.
#   --build-version N      CFBundleVersion (default: UTC yyyymmddHHMM).
#   --scratch-path NAME    SwiftPM build directory, joined to each package's path (default `.build`):
#                          a relative name beginning with `.build-` (e.g. `.build-release`), which
#                          .gitignore covers, never an absolute path. One per release or parallel build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Who holds the tree -----------------------------------------------------------------------
#
# Two builds sharing one working tree and one `.build` interfere with each other, and nothing
# else records that the other one is there. `wave-marker.sh check` prints a warning when another
# run's fresh marker is present, and **always exits 0**: a marker is a convention, never a lock,
# and a leftover one must not be able to redden or wedge a gate. Stale markers expire.
if [ -x "${REPO_ROOT}/Scripts/wave-marker.sh" ]; then
    "${REPO_ROOT}/Scripts/wave-marker.sh" check Apps
fi

APP_PACKAGE="${REPO_ROOT}/Apps/ZenitPDF"
BUNDLE_SOURCE="${APP_PACKAGE}/Bundle"
ICON_SOURCE="${REPO_ROOT}/Resources/Icons"

OUTPUT_DIR="${REPO_ROOT}/build"
SHORT_VERSION="1.0.0"
BUILD_VERSION="$(date -u +%Y%m%d%H%M)"
RUN_VERIFY=1
SCRATCH_NAME=".build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --build-version) BUILD_VERSION="$2"; shift 2 ;;
        --short-version) SHORT_VERSION="$2"; shift 2 ;;
        --skip-verify) RUN_VERIFY=0; shift ;;
        --scratch-path) SCRATCH_NAME="$2"; shift 2 ;;
        -h|--help) sed -n '2,58p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) echo "build-app.sh: unknown option '$1'" >&2; exit 2 ;;
        # A bare directory is the output directory. `.github/workflows/release.yml` invokes the
        # script as `Scripts/build-app.sh build`, and that contract predates this file.
        *) OUTPUT_DIR="$1"; shift ;;
    esac
done

# The default output folder is reached through `build`, a link to `build.noindex`. Spotlight
# skips any folder whose name ends in .noindex, while it no longer honours a
# .metadata_never_index file, so the indexer kept re-registering the built bundle as a second
# "Zenit PDF" in the app list beside the installed one (seen 2026-10-10). Every script still
# finds the bundle at build/Zenit PDF.app through the link.
if [[ "${OUTPUT_DIR}" == "${REPO_ROOT}/build" && ! -e "${OUTPUT_DIR}" ]]; then
    mkdir -p "${REPO_ROOT}/build.noindex"
    ln -s "build.noindex" "${OUTPUT_DIR}"
elif [[ "${OUTPUT_DIR}" == "${REPO_ROOT}/build" && ! -L "${OUTPUT_DIR}" ]]; then
    echo "note: build/ is a plain folder, so Spotlight may list the built bundle as a second app;"
    echo "      move it to build.noindex and link build -> build.noindex to keep it out."
fi

APP_NAME="Zenit PDF"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
EXECUTABLE_NAME="ZenitPDF"

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31mbuild-app.sh: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------------------------

section "Toolchain"
command -v swift >/dev/null || fail "swift is not on PATH"
command -v lipo  >/dev/null || fail "lipo is not on PATH"
command -v codesign >/dev/null || fail "codesign is not on PATH"
swift --version
echo "Xcode: $(xcode-select -p)"

for required in \
    "${BUNDLE_SOURCE}/Info.plist.in" \
    "${BUNDLE_SOURCE}/ZenitPDF.entitlements" \
    "${SCRIPT_DIR}/lib/zenit-codesign.sh" \
    "${ICON_SOURCE}/AppIcon.icns" \
    "${ICON_SOURCE}/ProjectDocument.icns"
do
    [[ -e "$required" ]] || fail "missing required input: $required"
done

# ---------------------------------------------------------------------------------------------
# 1. Build both slices — the app and the two XPC service workers
# ---------------------------------------------------------------------------------------------

# S15: parsing-heavy work runs out of process. The two services are
# separate SwiftPM executable packages; their entire behaviour lives in
# Packages/ZPDFServiceClient (where the tests are), the Apps/ targets are thin mains.
XPC_SERVICES=(GeometryService RepairService)

# NL-PLAT-12: Shortcuts actions. Xcode's "Extract App Intents Metadata" phase does not run in a
# SwiftPM build, so the compiler is asked for the constant values it would have gathered, and
# `appintentsmetadataprocessor` turns them into Metadata.appintents below (step 3c).
#
# No runtime search path is added: the bundle embeds no frameworks, and every dynamic dependency
# of every binary in it resolves to the operating system (Scripts/verify-bundle-linkage.sh).
APP_LINK_FLAGS=(-Xswiftc -emit-const-values
                 -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
                 -Xswiftc -Xfrontend -Xswiftc "${SCRIPT_DIR}/lib/app-intents-protocols.json")

# Where each slice is kept once built. SwiftPM's product directory is NOT per-architecture under
# the build backend this toolchain uses (Swift 6.4 writes `<scratch>/out/Products/Release` for
# every `--arch`), so the x86_64 build overwrites the arm64 product in place. And the old
# `<scratch>/<arch>-apple-macosx/release/` paths this script used to read still exist from earlier
# toolchains — holding binaries from 2026-09-02 that no longer change. Reading them assembled a
# stale application with no error anywhere (found 2026-09-23). So: ask SwiftPM where
# the product is, copy it out immediately, and refuse it unless it is the architecture just built
# and newer than this run.
SLICE_DIR="$(mktemp -d)"
trap 'rm -rf "${SLICE_DIR}"' EXIT
BUILD_STARTED="${SLICE_DIR}/.started"
touch "${BUILD_STARTED}"

# collect_slice <package dir> <product> <arch> — copies the fresh product into SLICE_DIR/<arch>/.
collect_slice() {
    local package="$1" product="$2" arch="$3" bin_path built
    bin_path="$(cd "${package}" && swift build -c release --arch "${arch}" --scratch-path "${package}/${SCRATCH_NAME}" --show-bin-path)" \
        || fail "could not ask SwiftPM where the ${arch} ${product} product is"
    built="${bin_path}/${product}"
    [[ -f "${built}" ]] || fail "expected ${arch} product at ${built}"
    [[ "${built}" -nt "${BUILD_STARTED}" ]] || fail "${built} predates this build; refusing a stale ${product}"
    [[ "$(lipo -archs "${built}")" == "${arch}" ]] \
        || fail "${built} is '$(lipo -archs "${built}")', not the ${arch} slice just built"
    mkdir -p "${SLICE_DIR}/${arch}"
    cp -p "${built}" "${SLICE_DIR}/${arch}/${product}"
    # The app's resource bundles (none today) travel from the arm64 build.
    if [[ "${product}" == "${EXECUTABLE_NAME}" && "${arch}" == "arm64" ]]; then
        APP_BIN_PATH="${bin_path}"
    fi
}

SLICES=()
APP_BIN_PATH=""
for arch in arm64 x86_64; do
    section "Release build (${arch})"
    ( cd "${APP_PACKAGE}" && swift build -c release --arch "${arch}" --scratch-path "${APP_PACKAGE}/${SCRATCH_NAME}" --product "${EXECUTABLE_NAME}" "${APP_LINK_FLAGS[@]}" )
    collect_slice "${APP_PACKAGE}" "${EXECUTABLE_NAME}" "${arch}"
    SLICES+=("${SLICE_DIR}/${arch}/${EXECUTABLE_NAME}")
    if [[ "${arch}" == "arm64" ]]; then
        # The executable module's constant values, taken before the x86_64 build can touch them.
        # Not filtered by age: an incremental build that did not recompile the module leaves the
        # previous (still current) values in place, and those are the ones that match the binary.
        mkdir -p "${SLICE_DIR}/constvalues"
        while IFS= read -r constvalues; do
            cp -p "$constvalues" "${SLICE_DIR}/constvalues/"
        done < <(find "${APP_PACKAGE}/${SCRATCH_NAME}" -path "*/Release/*" -path "*arm64*" -name "*.swiftconstvalues" 2>/dev/null \
                 | grep -E "/${EXECUTABLE_NAME}\.build/|/${EXECUTABLE_NAME}-")
    fi

    for service in "${XPC_SERVICES[@]}"; do
        section "Release build (${arch}, ${service})"
        ( cd "${REPO_ROOT}/Apps/${service}" && swift build -c release --arch "${arch}" --scratch-path "${REPO_ROOT}/Apps/${service}/${SCRATCH_NAME}" --product "${service}" )
        collect_slice "${REPO_ROOT}/Apps/${service}" "${service}" "${arch}"
    done

    # NL-PLAT-13: the read-only `zenit` command-line tool, shipped in Contents/Helpers.
    section "Release build (${arch}, zenit)"
    ( cd "${REPO_ROOT}/Tools/ZenitCLI" && swift build -c release --arch "${arch}" --scratch-path "${REPO_ROOT}/Tools/ZenitCLI/${SCRATCH_NAME}" --product zenit )
    collect_slice "${REPO_ROOT}/Tools/ZenitCLI" zenit "${arch}"

    # NL-PLAT-21: the Quick Look thumbnail extension, shipped in Contents/PlugIns.
    section "Release build (${arch}, ZenitQuickLook)"
    ( cd "${REPO_ROOT}/Apps/QuickLookThumbnail" && swift build -c release --arch "${arch}" --scratch-path "${REPO_ROOT}/Apps/QuickLookThumbnail/${SCRATCH_NAME}" --product ZenitQuickLook )
    collect_slice "${REPO_ROOT}/Apps/QuickLookThumbnail" ZenitQuickLook "${arch}"

    # NL-PLAT-21: the Quick Look preview extension (the Space-bar preview), in Contents/PlugIns.
    section "Release build (${arch}, ZenitQuickLookPreview)"
    ( cd "${REPO_ROOT}/Apps/QuickLookThumbnail" && swift build -c release --arch "${arch}" --scratch-path "${REPO_ROOT}/Apps/QuickLookThumbnail/${SCRATCH_NAME}" --product ZenitQuickLookPreview )
    collect_slice "${REPO_ROOT}/Apps/QuickLookThumbnail" ZenitQuickLookPreview "${arch}"
done

# ---------------------------------------------------------------------------------------------
# 2. Universal binary
# ---------------------------------------------------------------------------------------------

section "Universal binary"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
lipo -create -output "${MACOS_DIR}/${EXECUTABLE_NAME}" "${SLICES[@]}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"
lipo -info "${MACOS_DIR}/${EXECUTABLE_NAME}"

# ---------------------------------------------------------------------------------------------
# 3. Bundle contents
# ---------------------------------------------------------------------------------------------

section "Bundle"
sed -e "s/@SHORT_VERSION@/${SHORT_VERSION}/g" \
    -e "s/@BUILD_VERSION@/${BUILD_VERSION}/g" \
    "${BUNDLE_SOURCE}/Info.plist.in" > "${CONTENTS}/Info.plist"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null || fail "the generated Info.plist is not a valid plist"

# 'APPL????' is the four-character creator record every macOS application bundle carries.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

cp "${ICON_SOURCE}/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
# NL-PLAT-11: the AppleScript dictionary Info.plist's OSAScriptingDefinition names.
cp "${BUNDLE_SOURCE}/ZenitPDF.sdef" "${RESOURCES_DIR}/ZenitPDF.sdef"
cp "${ICON_SOURCE}/ProjectDocument.icns" "${RESOURCES_DIR}/ProjectDocument.icns"

# The localization catalogues go to the top of Contents/Resources, not into a SwiftPM resource
# bundle: every `NSLocalizedString` in every package resolves against `Bundle.main`, so one
# catalogue per language at the bundle root is what makes the whole product localizable.
#
# English only: the base localization is English, and a secondary
# catalogue ships complete or not at all. The Swedish catalogue in the repository is partial, and
# shipping a partial catalogue is exactly what produced the mixed "Arkiv/Mata" menu bar on a
# Swedish-locale machine — macOS picks the system language whenever the bundle declares it. Until
# `sv.lproj` covers every key, only `en.lproj` goes into the bundle and the default run is English
# everywhere.
SHIPPED_LOCALIZATIONS=(en)
# NL-PLAT-19: the switch for the day Swedish is complete. The tracker must then pass in
# strict mode (every key has a Swedish string, every conversion intact) or the build stops;
# a partial catalogue can never ship by accident.
if [[ "${ZENIT_SHIP_SWEDISH:-0}" == "1" ]]; then
    "${SCRIPT_DIR}/verify-localization.sh" --strict --list 5 || fail "ZENIT_SHIP_SWEDISH=1 but Swedish is not complete (Scripts/verify-localization.sh)"
    SHIPPED_LOCALIZATIONS+=(sv)
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string sv" "${CONTENTS}/Info.plist" >/dev/null \
        || fail "could not add sv to CFBundleLocalizations"
fi
for lang in "${SHIPPED_LOCALIZATIONS[@]}"; do
    lproj="${BUNDLE_SOURCE}/${lang}.lproj"
    [[ -d "$lproj" ]] || fail "missing localization catalogue: ${lproj}"
    cp -R "$lproj" "${RESOURCES_DIR}/"
    # The plural rules. Their source lives with `LocalizedPlural` in ZPDFUIPresentation, and until
    # 2026-09-23 nothing copied them, so every plural silently took the English one/other fallback
    # A shipped language without its rules fails the build.
    plurals="${REPO_ROOT}/Packages/ZPDFUIPresentation/Localization/${lang}.lproj/Plurals.stringsdict"
    [[ -f "$plurals" ]] || fail "missing plural rules for ${lang}: ${plurals}"
    plutil -lint "$plurals" >/dev/null || fail "${plurals} is not a valid plist"
    cp "$plurals" "${RESOURCES_DIR}/${lang}.lproj/Plurals.stringsdict"
done
echo "Localizations: $(ls -1 "${RESOURCES_DIR}" | grep -c '\.lproj$') catalogue(s), each with Plurals.stringsdict"

# The third-party licence notices, in full, offline, inside the bundle.
#
# Until 2026-08-26 `Contents/Resources` held icons, the GRDB resource bundle and `en.lproj` and
# nothing else. That is a compliance failure rather than an omission: qpdf's Apache-2.0 §4(d)
# makes its NOTICE non-optional for a redistributor, and GRDB, Clipper2 and libxlsxwriter all
# carry notices of their own — libxlsxwriter's arrives with minizip and the FreeBSD macro
# headers. `Docs/Licences/
# LICENSE_EVIDENCE.md` is the audited list and `Docs/Licences/SHIPPED_NOTICES.tsv` its
# machine-readable form; `Scripts/verify-licence-notices.sh` fails this build when the two
# disagree, and `ZenitAboutWindowController` is what shows the texts to a person.
LICENCE_SOURCE="${BUNDLE_SOURCE}/Licenses"
[[ -d "${LICENCE_SOURCE}" ]] || fail "missing licence notices: ${LICENCE_SOURCE}"
cp -R "${LICENCE_SOURCE}" "${RESOURCES_DIR}/"
echo "Licence notices: $(ls -1 "${RESOURCES_DIR}/Licenses" | grep -c '\.txt$') component(s)"

# ---------------------------------------------------------------------------------------------
# 3c. Shortcuts metadata (NL-PLAT-12)
# ---------------------------------------------------------------------------------------------
# Metadata.appintents is what makes Shortcuts list the app's actions. It is generated from the
# executable module's sources and constant values, and the build FAILS without it, so the actions
# can never silently vanish from a release.
section "App Intents metadata"
ls "${SLICE_DIR}/constvalues/"*.swiftconstvalues > "${SLICE_DIR}/constvalues.txt" 2>/dev/null \
    || fail "no .swiftconstvalues for ${EXECUTABLE_NAME}; the compiler did not gather App Intents constants"
find "${APP_PACKAGE}/Sources/${EXECUTABLE_NAME}" -name '*.swift' > "${SLICE_DIR}/intent-sources.txt"
XCODE_BUILD_VERSION="$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')"
xcrun appintentsmetadataprocessor \
    --output "${RESOURCES_DIR}" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name "${EXECUTABLE_NAME}" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "${XCODE_BUILD_VERSION}" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 \
    --source-file-list "${SLICE_DIR}/intent-sources.txt" \
    --swift-const-vals-list "${SLICE_DIR}/constvalues.txt" \
    --force > "${SLICE_DIR}/appintents.log" 2>&1 \
    || { cat "${SLICE_DIR}/appintents.log" >&2; fail "appintentsmetadataprocessor failed"; }
ACTIONS="${RESOURCES_DIR}/Metadata.appintents/extract.actionsdata"
[[ -f "${ACTIONS}" ]] || fail "Metadata.appintents is missing from the bundle; Shortcuts would list no actions"
for intent in ExportQuantityLedgerIntent GetLedgerTotalsIntent OpenDrawingIntent; do
    grep -q "\"${intent}\"" "${ACTIONS}" || fail "Metadata.appintents does not list ${intent}"
done
echo "Metadata.appintents: ExportQuantityLedgerIntent, GetLedgerTotalsIntent, OpenDrawingIntent"

# ---------------------------------------------------------------------------------------------
# 3b. XPC services
# ---------------------------------------------------------------------------------------------
# Each service becomes Contents/XPCServices/<Name>.xpc: a Universal 2 binary, an Info.plist
# declaring CFBundlePackageType XPC!, and (at signing, below) sandbox-only entitlements —
# no network, no user-selected files. Documents reach the services exclusively as inherited
# file descriptors over their NSXPCConnections.

section "XPC services"
XPCSERVICES_DIR="${CONTENTS}/XPCServices"
for service in "${XPC_SERVICES[@]}"; do
    service_bundle="${XPCSERVICES_DIR}/${service}.xpc"
    service_source="${REPO_ROOT}/Apps/${service}"
    [[ -e "${service_source}/Bundle/Info.plist.in" ]] || fail "missing ${service} Info.plist.in"
    [[ -e "${service_source}/Bundle/${service}.entitlements" ]] || fail "missing ${service} entitlements"

    mkdir -p "${service_bundle}/Contents/MacOS"
    lipo -create -output "${service_bundle}/Contents/MacOS/${service}" \
        "${SLICE_DIR}/arm64/${service}" \
        "${SLICE_DIR}/x86_64/${service}"
    chmod +x "${service_bundle}/Contents/MacOS/${service}"
    lipo -info "${service_bundle}/Contents/MacOS/${service}"

    sed -e "s/@SHORT_VERSION@/${SHORT_VERSION}/g" \
        -e "s/@BUILD_VERSION@/${BUILD_VERSION}/g" \
        "${service_source}/Bundle/Info.plist.in" > "${service_bundle}/Contents/Info.plist"
    plutil -lint "${service_bundle}/Contents/Info.plist" >/dev/null \
        || fail "the generated ${service} Info.plist is not a valid plist"
    printf 'XPC!????' > "${service_bundle}/Contents/PkgInfo"
done

# ---------------------------------------------------------------------------------------------
# 3b''. Quick Look thumbnail extension (NL-PLAT-21)
# ---------------------------------------------------------------------------------------------
# Finder's thumbnail of a project: Contents/PlugIns/ZenitQuickLook.appex, a Universal 2 binary
# whose entry point is Foundation's extension main, and (at signing, below) the sandbox and
# nothing else. It draws the picture the app saved in the package, or the drawing's first sheet
# in its own process. Registered by Launch Services when the app is installed.

section "Quick Look extension"
QL_SOURCE="${REPO_ROOT}/Apps/QuickLookThumbnail"
QL_BUNDLE="${CONTENTS}/PlugIns/ZenitQuickLook.appex"
mkdir -p "${QL_BUNDLE}/Contents/MacOS"
lipo -create -output "${QL_BUNDLE}/Contents/MacOS/ZenitQuickLook" \
    "${SLICE_DIR}/arm64/ZenitQuickLook" "${SLICE_DIR}/x86_64/ZenitQuickLook"
chmod +x "${QL_BUNDLE}/Contents/MacOS/ZenitQuickLook"
lipo -info "${QL_BUNDLE}/Contents/MacOS/ZenitQuickLook"
sed -e "s/@SHORT_VERSION@/${SHORT_VERSION}/g" \
    -e "s/@BUILD_VERSION@/${BUILD_VERSION}/g" \
    "${QL_SOURCE}/Bundle/Info.plist.in" > "${QL_BUNDLE}/Contents/Info.plist"
plutil -lint "${QL_BUNDLE}/Contents/Info.plist" >/dev/null || fail "the generated ZenitQuickLook Info.plist is not a valid plist"
printf 'XPC!????' > "${QL_BUNDLE}/Contents/PkgInfo"

# The Space-bar preview (NL-PLAT-21): Contents/PlugIns/ZenitQuickLookPreview.appex, a data-based
# preview extension. It turns the sheet and totals the app saved in the package into one page;
# the same sandbox-only entitlements as the thumbnail extension.
QLP_BUNDLE="${CONTENTS}/PlugIns/ZenitQuickLookPreview.appex"
mkdir -p "${QLP_BUNDLE}/Contents/MacOS"
lipo -create -output "${QLP_BUNDLE}/Contents/MacOS/ZenitQuickLookPreview" \
    "${SLICE_DIR}/arm64/ZenitQuickLookPreview" "${SLICE_DIR}/x86_64/ZenitQuickLookPreview"
chmod +x "${QLP_BUNDLE}/Contents/MacOS/ZenitQuickLookPreview"
lipo -info "${QLP_BUNDLE}/Contents/MacOS/ZenitQuickLookPreview"
sed -e "s/@SHORT_VERSION@/${SHORT_VERSION}/g" \
    -e "s/@BUILD_VERSION@/${BUILD_VERSION}/g" \
    "${QL_SOURCE}/Bundle/Preview-Info.plist.in" > "${QLP_BUNDLE}/Contents/Info.plist"
plutil -lint "${QLP_BUNDLE}/Contents/Info.plist" >/dev/null || fail "the generated ZenitQuickLookPreview Info.plist is not a valid plist"
printf 'XPC!????' > "${QLP_BUNDLE}/Contents/PkgInfo"

# ---------------------------------------------------------------------------------------------
# 3b'. Command-line tool (NL-PLAT-13)
# ---------------------------------------------------------------------------------------------
# `zenit` reads projects without the application: totals, exports, an integrity check. A person
# links it into their PATH once (Settings ▸ Command-Line Tool shows the line); the sandboxed app
# cannot do that for them. It opens every project read-only, on a private copy.

section "Command-line tool"
HELPERS_DIR="${CONTENTS}/Helpers"
mkdir -p "${HELPERS_DIR}"
lipo -create -output "${HELPERS_DIR}/zenit" "${SLICE_DIR}/arm64/zenit" "${SLICE_DIR}/x86_64/zenit"
chmod +x "${HELPERS_DIR}/zenit"
lipo -info "${HELPERS_DIR}/zenit"

# A SwiftPM target with resources produces a sibling .bundle next to the executable. None of the
# app's dependencies declares resources today, but copying any that appear keeps the assembly
# correct rather than silently lossy if one is added later.
shopt -s nullglob
for resource_bundle in "${APP_BIN_PATH}/"*.bundle; do
    cp -R "$resource_bundle" "${RESOURCES_DIR}/"
    echo "Copied resource bundle: $(basename "$resource_bundle")"
done
shopt -u nullglob

# ---------------------------------------------------------------------------------------------
# 4. Sign
# ---------------------------------------------------------------------------------------------

section "Signing"
# How each piece is signed — ad-hoc with a stable designated requirement, or the maintainer's
# self-signed certificate when ZENIT_RELEASE_SIGNING=1 — lives in one shared file (see the header).
# shellcheck source=lib/zenit-codesign.sh
source "${SCRIPT_DIR}/lib/zenit-codesign.sh"
zenit_codesign_prepare || fail "release signing was requested and no signing identity is available"
echo "Signing mode: $(zenit_codesign_mode)"
# Nested code first, outermost last: a signature over a bundle covers whatever is inside it, so
# signing the app before its nested code would seal a hash of unsigned contents.

# Each XPC service is signed with its own entitlements file: sandbox on, and nothing
# else — no network client, no user-selected files, no app group.
for service in "${XPC_SERVICES[@]}"; do
    service_bundle="${CONTENTS}/XPCServices/${service}.xpc"
    [[ -d "$service_bundle" ]] || fail "expected ${service_bundle} before signing"
    echo "Signing nested: ${service}.xpc (sandbox-only entitlements)"
    zenit_sign "$service_bundle" "${REPO_ROOT}/Apps/${service}/Bundle/${service}.entitlements" \
        || fail "could not sign ${service}.xpc"
done

# The Quick Look extension: the sandbox and nothing else (NL-PLAT-21).
echo "Signing nested: PlugIns/ZenitQuickLook.appex (sandbox-only entitlements)"
zenit_sign "${CONTENTS}/PlugIns/ZenitQuickLook.appex" "${REPO_ROOT}/Apps/QuickLookThumbnail/Bundle/QuickLookThumbnail.entitlements" \
    || fail "could not sign ZenitQuickLook.appex"
echo "Signing nested: PlugIns/ZenitQuickLookPreview.appex (sandbox-only entitlements)"
zenit_sign "${CONTENTS}/PlugIns/ZenitQuickLookPreview.appex" "${REPO_ROOT}/Apps/QuickLookThumbnail/Bundle/QuickLookThumbnail.entitlements" \
    || fail "could not sign ZenitQuickLookPreview.appex"

# The command-line tool: Hardened Runtime, no entitlements (it runs in the person's own Terminal
# session, outside any sandbox, and reads only the paths it is given).
echo "Signing nested: Helpers/zenit"
zenit_sign "${CONTENTS}/Helpers/zenit" || fail "could not sign Helpers/zenit"

zenit_sign "${APP_BUNDLE}" "${BUNDLE_SOURCE}/ZenitPDF.entitlements" || fail "could not sign the app"

# The requirement is part of the product (NL-PLAT-01). A sandboxed app's container, and the
# security-scoped bookmarks behind Open Recent, are tied to it, and a copy whose requirement
# differs from the one installed before makes macOS ask "differs from previously opened versions"
# on its first launch.
#
#   * A certificate-signed build (ZENIT_RELEASE_SIGNING=1) must match the pin in
#     Apps/ZenitPDF/Bundle/DesignatedRequirement.txt exactly; change the pin only on purpose.
#   * A normal build is ad-hoc and carries no certificate, so the pin cannot apply. It must still
#     carry the stable ad-hoc requirement, so consecutive local builds keep one identity.
SIGNED_REQUIREMENT="$(zenit_designated_requirement "${APP_BUNDLE}")"
echo "Designated requirement: ${SIGNED_REQUIREMENT}"
if zenit_release_signing; then
    [[ -f "${BUNDLE_SOURCE}/DesignatedRequirement.txt" ]] \
        || fail "ZENIT_RELEASE_SIGNING=1 needs the pin at Apps/ZenitPDF/Bundle/DesignatedRequirement.txt"
    PINNED_REQUIREMENT="$(tr -d '\n' < "${BUNDLE_SOURCE}/DesignatedRequirement.txt")"
    [[ "${SIGNED_REQUIREMENT}" == "${PINNED_REQUIREMENT}" ]] \
        || fail "the signed requirement '${SIGNED_REQUIREMENT}' differs from the pinned '${PINNED_REQUIREMENT}' (Apps/ZenitPDF/Bundle/DesignatedRequirement.txt). Every copy installed from an earlier certificate-signed local build would ask 'differs from previously opened versions'."
    echo "Pinned requirement matched (release signing)."
else
    APP_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "${CONTENTS}/Info.plist")"
    [[ "${SIGNED_REQUIREMENT}" == "identifier \"${APP_IDENTIFIER}\"" ]] \
        || fail "the ad-hoc requirement '${SIGNED_REQUIREMENT}' is not the stable 'identifier \"${APP_IDENTIFIER}\"'"
    echo "Ad-hoc build: the release pin is not checked (ZENIT_RELEASE_SIGNING=1 selects the local certificate mode)."
fi

# ---------------------------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------------------------

if [[ "${RUN_VERIFY}" -eq 1 ]]; then
    section "codesign --verify --deep --strict"
    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

    section "Entitlements actually attached"
    codesign --display --entitlements - --xml "${APP_BUNDLE}" 2>/dev/null \
        | plutil -convert xml1 -o - - \
        | grep -E 'com\.apple\.security|<string>|<true/>' || true

    section "XPC service signatures"
    for service in "${XPC_SERVICES[@]}"; do
        service_bundle="${CONTENTS}/XPCServices/${service}.xpc"
        codesign --verify --deep --strict --verbose=2 "$service_bundle"
        echo "${service}.xpc entitlements:"
        codesign --display --entitlements - --xml "$service_bundle" 2>/dev/null \
            | plutil -convert xml1 -o - - \
            | grep -E 'com\.apple\.security|<true/>' || true
    done

    section "Quick Look extension signature"
    codesign --verify --deep --strict --verbose=2 "${CONTENTS}/PlugIns/ZenitQuickLook.appex"
    codesign --display --entitlements - --xml "${CONTENTS}/PlugIns/ZenitQuickLook.appex" 2>/dev/null \
        | plutil -convert xml1 -o - - \
        | grep -E 'com\.apple\.security|<true/>' || true
    codesign --verify --deep --strict --verbose=2 "${CONTENTS}/PlugIns/ZenitQuickLookPreview.appex"
    codesign --display --entitlements - --xml "${CONTENTS}/PlugIns/ZenitQuickLookPreview.appex" 2>/dev/null \
        | plutil -convert xml1 -o - - \
        | grep -E 'com\.apple\.security|<true/>' || true

    section "spctl --assess"
    # Expected to fail: neither signing mode uses an Apple-issued Developer ID, and the bundle is
    # not notarized (the project has no Apple Developer ID). The verdict is printed rather than
    # suppressed, and it does not fail this script.
    if spctl --assess --type execute --verbose=4 "${APP_BUNDLE}" 2>&1; then
        echo "spctl: accepted"
    else
        echo "spctl: rejected — expected without a Developer ID and notarization; see Docs for the Gatekeeper path"
    fi
fi

section "Done"
echo "${APP_BUNDLE}"
section "licence notices"
# Apache-2.0 §4(d) is not advisory, and the failure mode is silence: a dependency arrives, its
# notice does not, and nothing goes red. This gate is inside the build for that reason.
if ! "${SCRIPT_DIR}/verify-licence-notices.sh" "${APP_BUNDLE}"; then
    echo "FAILED: the assembled bundle does not carry the licence text it must redistribute"
    exit 1
fi

section "competitor names"
# Project policy: no competing product is named anywhere in the program. Inside the build because
# one earlier mention was a string literal frozen into a contract and therefore compiled into the
# shipping binary — invisible to any review of the interface.
# The bundle just assembled, wherever --output put it (T-082): with no argument the gate scanned
# build/ or dist/ — a stale bundle, or none — and never a release build's.
if ! "${SCRIPT_DIR}/verify-no-competitor-names.sh" "${APP_BUNDLE}"; then
    echo "FAILED: a competing product is named in the product"
    exit 1
fi

section "dynamic linkage"
# A bundle that cannot resolve its dynamic libraries is not a build, it is a crash with a size.
# On 2026-08-24 this script reported success on a bundle that died in dyld before main() because
# an embedded framework could not be found; it was discovered from a crash dialog. Never again.
if ! "${SCRIPT_DIR}/verify-bundle-linkage.sh" "${APP_BUNDLE}"; then
    echo "FAILED: the assembled bundle would not launch (see the unresolved dependency above)"
    exit 1
fi

section "no network"
# The application makes no network connection: no entitlement for one, no network API imported,
# no updater, no feed. File inspection only; nothing is launched.
if ! "${SCRIPT_DIR}/verify-no-network.sh" --app "${APP_BUNDLE}"; then
    echo "FAILED: the assembled bundle can reach the network"
    exit 1
fi

du -sh "${APP_BUNDLE}" | awk '{print "Bundle size: " $1}'

# The assembled bundle is a build product, not an installation. LaunchServices registers every
# bundle it notices, so each build used to add a second "Zenit PDF" to Open With, Spotlight and
# the Dock's app list beside the one in /Applications (seen 2026-09-24: three installations).
# Unregister it and keep Spotlight out of the output folder (the default folder is build.noindex,
# see above; the marker file below is kept for older macOS); the installed copy stays the only one.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -u "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi
touch "${OUTPUT_DIR}/.metadata_never_index" 2>/dev/null || true
