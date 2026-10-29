#!/usr/bin/env bash
#
# make-dmg.sh — build the release disk image, the zip and SHA256SUMS.txt from a built app.
#
#   Scripts/make-dmg.sh <path/to/Zenit PDF.app> [output-directory]
#
# Defaults: the app is looked for at build/Zenit PDF.app and everything is written to dist/.
#
# Output, all in the output directory:
#   ZenitPDF-<version>-<arch>.dmg   the app, an Applications shortcut, and a visible
#                                   "How to open Zenit PDF the first time.rtf" note
#   ZenitPDF-<version>-<arch>.zip   the app alone, for people who prefer a zip
#   SHA256SUMS.txt                  one line per file above, in `shasum -a 256` format;
#                                   Scripts/install.sh refuses an image with no line here
#
# Steps:
#   1. verify the .app exists, is a real bundle, and carries a valid signature
#   2. read the version and architectures out of the bundle
#   3. stage the app, an /Applications symlink and the first-launch note (generated below
#      from plain text in this script; nothing private goes in)
#   4. build a read-write image (optionally arranging the Finder window in it — opt-in, see
#      below), flatten it to a compressed UDZO image
#   5. verify the image, mount it read-only and check exactly what is inside, including the
#      app's signature; zip the app and check the zip the same way
#   6. write SHA256SUMS.txt
#
# Nothing here needs a Finder, a window server or a user session, so it runs the same on a
# headless CI runner. No window opens: every mount is -nobrowse.
#
# This is a maintainer tool, so its output is English like the rest of the contributor
# documentation.
#
# ================================================================================
# Finder window layout — opt-in, never required
# ================================================================================
# The AppleScript layout (icon positions and window size, stored in the image's .DS_Store)
# needs Finder disk scripting, which a CI runner does not have and which timed out with
# AppleEvent -1712 on the build machine.
# So it only runs with SKIP_LAYOUT=0 exactly, and every
# failure in it is a warning. Without it the image opens with Finder's default window
# geometry: a window CONTAINING the app, the Applications shortcut and the note, never a
# laid-out one, and the documentation promises exactly that. There is deliberately no
# background image: without the Finder layout it could never be shown, and the visible note
# carries the instructions instead.
#
# ================================================================================
# The image is not byte-reproducible
# ================================================================================
# hdiutil and ditto bake timestamps in, so the same bundle packaged twice yields different
# SHA-256 values (observed f40b662c… then bb6bae8b… minutes apart on 2026-08-24).
# SHA256SUMS.txt is therefore a transport-integrity check — the file you downloaded is the file
# that was uploaded — NOT a provenance check: nobody can verify a release by rebuilding it and
# comparing hashes. Do not let any document claim otherwise.
#
# Requires: bash, hdiutil, codesign, shasum, plutil, ditto — all present on macOS with the
# Command Line Tools. osascript is optional.

set -euo pipefail

readonly APP_NAME="Zenit PDF.app"
readonly VOLUME_NAME="Zenit PDF"
readonly PRODUCT_SLUG="ZenitPDF"
readonly CHECKSUM_FILE="SHA256SUMS.txt"
readonly NOTE_NAME="How to open Zenit PDF the first time.rtf"

# The repository named in the note's links. The release workflow passes its own.
ZENIT_REPO="${ZENIT_REPO:-ZGColombia/ZenitPDF}"

# The AppleScript layout step is skipped by default (see the header). Only the exact value 0
# attempts it; every other value, including an unset or empty variable and a well-meant
# SKIP_LAYOUT=no, skips. Skipping is the safe direction.
SKIP_LAYOUT="${SKIP_LAYOUT:-1}"

info()  { printf '==> %s\n' "$*"; }
warn()  { printf 'warning: %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------------
# Cleanup. A mounted image must be detached before its staging directory can go.
# --------------------------------------------------------------------------------
STAGING_DIR=""
MOUNT_POINT=""
RW_IMAGE=""

detach() {
    hdiutil detach "$1" -quiet >/dev/null 2>&1 || hdiutil detach "$1" -force -quiet >/dev/null 2>&1
}

cleanup() {
    if [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ]; then
        detach "${MOUNT_POINT}" || true
    fi
    if [ -n "${RW_IMAGE}" ] && [ -f "${RW_IMAGE}" ]; then
        rm -f "${RW_IMAGE}"
    fi
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------------
# The first-launch note, as RTF so a double-click opens it in TextEdit and the
# space bar previews it in Finder. Plain text only; the wording matches
# Docs/INSTALL.md. Keep it ASCII apart from the RTF quote control words, and escape
# any backslash or brace added to it.
# --------------------------------------------------------------------------------
write_first_launch_note() {
    cat > "$1" <<RTF
{\rtf1\ansi\ansicpg1252\deff0
{\fonttbl{\f0\fswiss\fcharset0 Helvetica;}{\f1\fmodern\fcharset0 Menlo-Regular;}}
\paperw11905\paperh16837\margl1134\margr1134\margt1134\margb1134\vieww11000\viewh13000
\pard\sa240\f0\fs36\b How to open Zenit PDF the first time\b0\par
\pard\sa160\fs24 {\b First}, drag {\b Zenit PDF} onto the {\b Applications} folder in this window.\par
Zenit PDF is free, open-source software. It is not signed with an Apple Developer ID and not notarized by Apple, so macOS asks you to confirm the first time you open it. You only do this once. To see which macOS you have, choose {\b Apple menu > About This Mac}.\par
\pard\sb200\sa120\fs28\b macOS 15 Sequoia and macOS 26 Tahoe\b0\fs24\par
\pard\sa120 1.  Open the {\b Applications} folder and double-click {\b Zenit PDF}. macOS says \ldblquote Zenit PDF\rdblquote  Not Opened. Click {\b Done} (not Move to Trash).\par
2.  Choose {\b Apple menu > System Settings}, then click {\b Privacy & Security} in the sidebar.\par
3.  Scroll down to {\b Security}. Next to \ldblquote Zenit PDF\rdblquote  was blocked to protect your Mac, click {\b Open Anyway}.\par
4.  macOS asks once more: click {\b Open Anyway}, then enter your Mac login password or use Touch ID.\par
\pard\sa160 Zenit PDF opens. The Open Anyway button appears for about an hour after step 1; if you do not see it, do step 1 again.\par
\pard\sb200\sa120\fs28\b macOS 14 Sonoma\b0\fs24\par
\pard\sa120 1.  Open the {\b Applications} folder. Hold down the Control key and click {\b Zenit PDF} (or right-click it), then choose {\b Open}.\par
2.  macOS asks if you are sure you want to open it. Click {\b Open}.\par
\pard\sa160 If there is no Open button, use {\b System Settings > Privacy & Security > Open Anyway}, as described for macOS 15.\par
\pard\sb200\sa120\fs28\b Prefer to skip all this?\b0\fs24\par
\pard\sa120 The one-line installer downloads Zenit PDF, checks it, and installs it so that macOS does not ask. Open the {\b Terminal} app, paste this line and press Return:\par
\pard\sa160\f1\fs20 curl -fsSL https://github.com/${ZENIT_REPO}/releases/latest/download/install.sh | bash\f0\fs24\par
\pard\sa120 More help, including what to do if macOS says the app is damaged: https://github.com/${ZENIT_REPO}/blob/main/Docs/INSTALL.md\par
}
RTF
}

# --------------------------------------------------------------------------------
# Arguments.
# --------------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${ROOT}/build/${APP_NAME}}"
OUT_DIR="${2:-${ROOT}/dist}"

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS."

for tool in hdiutil codesign shasum plutil ditto; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

# --------------------------------------------------------------------------------
# 1. Verify the app bundle.
# --------------------------------------------------------------------------------
info "Checking ${APP_PATH}"

[ -d "${APP_PATH}" ] || die "no application bundle at: ${APP_PATH}
       Pass the path explicitly:  Scripts/make-dmg.sh \"path/to/${APP_NAME}\""

case "${APP_PATH}" in
    *.app|*.app/) ;;
    *) die "not an .app bundle: ${APP_PATH}" ;;
esac
APP_PATH="${APP_PATH%/}"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[ -f "${INFO_PLIST}" ] || die "missing Contents/Info.plist — this is not an app bundle."

# --------------------------------------------------------------------------------
# Signature. Zenit PDF ships ad-hoc signed: there is no Developer ID certificate
# and no notarization (see Docs/Release/DISTRIBUTION.md). An ad-hoc signature buys
# no Gatekeeper trust, but it does make the bundle tamper-evident locally and it
# is required on Apple Silicon for the binary to run at all. An unsigned bundle is
# refused here rather than shipped.
# --------------------------------------------------------------------------------
info "Verifying the code signature"

codesign --verify --deep --strict "${APP_PATH}" 2>/dev/null \
    || die "the bundle is unsigned or its signature is invalid.
       Build it with Scripts/build-app.sh, which signs it ad-hoc with its entitlements."

SIGN_INFO="$(codesign -dvv "${APP_PATH}" 2>&1 || true)"

# Pattern matching, not `printf | grep -q`: under pipefail an early-exiting grep -q kills the
# writer with SIGPIPE and turns a match into a failure (measured here, 2026-10-27).
case "${SIGN_INFO}" in
    *"Signature=adhoc"*)
        SIGNATURE_KIND="ad-hoc" ;;
    *"Authority="*)
        SIGNATURE_KIND="$(sed -n 's/^Authority=\(.*\)$/\1/p' <<<"${SIGN_INFO}" | head -n 1 || true)"
        info "Signed with the identity: ${SIGNATURE_KIND}" ;;
    *)
        SIGNATURE_KIND="unknown"
        warn "could not determine the signature kind; continuing." ;;
esac

info "Signature: ${SIGNATURE_KIND}"

# --------------------------------------------------------------------------------
# 2. Version and architectures.
# --------------------------------------------------------------------------------
read_plist() {
    # read_plist <key> — empty string when the key is absent
    plutil -extract "$1" raw -o - "${INFO_PLIST}" 2>/dev/null || printf ''
}

VERSION="$(read_plist CFBundleShortVersionString)"
[ -n "${VERSION}" ] || die "CFBundleShortVersionString is missing from Info.plist."

EXECUTABLE_NAME="$(read_plist CFBundleExecutable)"
[ -n "${EXECUTABLE_NAME}" ] || die "CFBundleExecutable is missing from Info.plist."

EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
ARCH_SUFFIX="unknown"
if [ -f "${EXECUTABLE_PATH}" ] && command -v lipo >/dev/null 2>&1; then
    ARCHS="$(lipo -archs "${EXECUTABLE_PATH}" 2>/dev/null || printf '')"
    case "${ARCHS}" in
        *arm64*x86_64*|*x86_64*arm64*) ARCH_SUFFIX="universal" ;;
        *arm64*)                       ARCH_SUFFIX="arm64" ;;
        *x86_64*)                      ARCH_SUFFIX="x86_64" ;;
    esac
    info "Architectures: ${ARCHS:-unknown}"
fi

if [ "${ARCH_SUFFIX}" != "universal" ]; then
    warn "this build is not Universal 2 (${ARCH_SUFFIX}). Release builds should be."
fi

DMG_NAME="${PRODUCT_SLUG}-${VERSION}-${ARCH_SUFFIX}.dmg"
ZIP_NAME="${PRODUCT_SLUG}-${VERSION}-${ARCH_SUFFIX}.zip"

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"

info "Building ${DMG_NAME} and ${ZIP_NAME}"

# --------------------------------------------------------------------------------
# 3. Stage: the app, a symlink to /Applications and the note, and nothing else.
# --------------------------------------------------------------------------------
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zenitpdf-dmg.XXXXXXXX")"
STAGE="${STAGING_DIR}/stage"
mkdir -p "${STAGE}"

info "Staging the bundle, the Applications shortcut and the first-launch note"
ditto "${APP_PATH}" "${STAGE}/${APP_NAME}" || die "could not copy the app bundle."
ln -s /Applications "${STAGE}/Applications" || die "could not create the /Applications symlink."
write_first_launch_note "${STAGE}/${NOTE_NAME}"

# The note must be a document TextEdit can read; textutil parses it without a window.
if command -v textutil >/dev/null 2>&1; then
    NOTE_TEXT="$(textutil -convert txt -stdout "${STAGE}/${NOTE_NAME}" 2>/dev/null || true)"
    case "${NOTE_TEXT}" in
        *"Open Anyway"*"releases/latest/download/install.sh"*) ;;
        *) die "the generated first-launch note is not readable RTF." ;;
    esac
fi

# A stale .DS_Store from the source tree would override the layout below.
find "${STAGE}" -name '.DS_Store' -type f -delete 2>/dev/null || true

STAGE_MB="$(du -sm "${STAGE}" | awk '{print $1}')"
IMAGE_MB=$(( STAGE_MB + 64 ))

# --------------------------------------------------------------------------------
# 4a. Read-write image.
# --------------------------------------------------------------------------------
RW_IMAGE="${STAGING_DIR}/rw.dmg"

info "Creating a temporary read-write image (${IMAGE_MB} MB)"
hdiutil create \
    -srcfolder "${STAGE}" \
    -volname "${VOLUME_NAME}" \
    -fs "HFS+" \
    -format UDRW \
    -size "${IMAGE_MB}m" \
    -quiet \
    "${RW_IMAGE}" \
    || die "hdiutil create failed."

# --------------------------------------------------------------------------------
# 4b. Window layout. OPT-IN (SKIP_LAYOUT=0); every failure here is a warning.
# --------------------------------------------------------------------------------
arrange_window() {
    if [ "${SKIP_LAYOUT}" != "0" ]; then
        info "Window layout skipped (default — set SKIP_LAYOUT=0 to attempt the Finder layout)"
        return 0
    fi
    if ! command -v osascript >/dev/null 2>&1; then
        warn "osascript not found; shipping the image with Finder's default layout."
        return 0
    fi
    if ! pgrep -x Finder >/dev/null 2>&1; then
        warn "Finder is not running (headless session?); using the default layout."
        return 0
    fi

    info "Arranging the Finder window (SKIP_LAYOUT=0)"

    # The failure branch is a bare assignment so that the heredoc body starts on the very next
    # line; a multi-line `|| { ... }` here would be swallowed by the heredoc instead.
    local layout_failed=0
    osascript <<APPLESCRIPT >/dev/null 2>&1 || layout_failed=1
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, 860, 620}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        set position of item "${APP_NAME}" of container window to {160, 170}
        set position of item "Applications" of container window to {480, 170}
        set position of item "${NOTE_NAME}" of container window to {320, 340}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

    if [ "${layout_failed}" -ne 0 ]; then
        warn "the AppleScript window layout did not run.
         Usual causes: no Automation permission for the calling process, no user
         session, or Finder refusing to script a freshly mounted volume.
         The disk image is still valid; only its window geometry is Finder's default."
    fi
    return 0
}

MOUNT_POINT="${STAGING_DIR}/mnt"
mkdir -p "${MOUNT_POINT}"

info "Mounting the read-write image"
hdiutil attach "${RW_IMAGE}" -mountpoint "${MOUNT_POINT}" -nobrowse -noautoopen -quiet \
    || die "could not mount the temporary image."

arrange_window

sync 2>/dev/null || true

info "Detaching"
detach "${MOUNT_POINT}" || die "could not detach the temporary image."
MOUNT_POINT=""

# --------------------------------------------------------------------------------
# 4c. Flatten to a compressed read-only image.
# --------------------------------------------------------------------------------
info "Converting to compressed UDZO"
rm -f "${DMG_PATH}"
hdiutil convert "${RW_IMAGE}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}" \
    -quiet \
    || die "hdiutil convert failed."

rm -f "${RW_IMAGE}"
RW_IMAGE=""

# --------------------------------------------------------------------------------
# 5. Verify the image and what is inside it; zip the app and verify the zip.
# --------------------------------------------------------------------------------
info "Verifying the image"
hdiutil verify "${DMG_PATH}" -quiet || die "hdiutil verify failed on ${DMG_PATH}."

MOUNT_POINT="${STAGING_DIR}/check"
mkdir -p "${MOUNT_POINT}"
hdiutil attach "${DMG_PATH}" -readonly -nobrowse -noautoopen -mountpoint "${MOUNT_POINT}" -quiet \
    || die "could not mount ${DMG_NAME} read-only to check it."
# Visible items only: hidden file-system bookkeeping (.fseventsd and the like) is not content.
CONTENTS="$(cd "${MOUNT_POINT}" && ls -1 | sort | tr '\n' '|')"
EXPECTED="$(printf '%s\n' "${APP_NAME}" "Applications" "${NOTE_NAME}" | sort | tr '\n' '|')"
[ "${CONTENTS}" = "${EXPECTED}" ] || die "the image contains '${CONTENTS}', expected '${EXPECTED}'."
[ "$(readlink "${MOUNT_POINT}/Applications")" = "/Applications" ] \
    || die "the Applications shortcut in the image does not point at /Applications."
codesign --verify --deep --strict "${MOUNT_POINT}/${APP_NAME}" 2>/dev/null \
    || die "the app inside the image does not pass codesign --verify."
info "Image contents: ${APP_NAME}, Applications -> /Applications, ${NOTE_NAME}; signature valid"
detach "${MOUNT_POINT}" || die "could not detach the checked image."
MOUNT_POINT=""

info "Zipping the app"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}" || die "ditto could not create ${ZIP_NAME}."
mkdir -p "${STAGING_DIR}/unzip"
ditto -x -k "${ZIP_PATH}" "${STAGING_DIR}/unzip" || die "${ZIP_NAME} does not unpack."
codesign --verify --deep --strict "${STAGING_DIR}/unzip/${APP_NAME}" 2>/dev/null \
    || die "the app unpacked from ${ZIP_NAME} does not pass codesign --verify."
info "Zip contents: ${APP_NAME}; signature valid after unpacking"

# --------------------------------------------------------------------------------
# 6. Checksums. The file is written from scratch on every run and lists exactly
# the two files above. Lines from an earlier version packaged into the same output
# directory are not carried over: Scripts/install.sh reads the published file to
# choose the disk image it downloads, so a stale line must not survive.
# --------------------------------------------------------------------------------
info "Writing ${CHECKSUM_FILE}"
SUMS_PATH="${OUT_DIR}/${CHECKSUM_FILE}"

( cd "${OUT_DIR}" && shasum -a 256 "${DMG_NAME}" "${ZIP_NAME}" > "${CHECKSUM_FILE}" )
( cd "${OUT_DIR}" && shasum -a 256 -c "${CHECKSUM_FILE}" >/dev/null ) \
    || die "${CHECKSUM_FILE} does not verify right after writing it."

sum_of() {
    awk -v want="$1" '{ name = $2; sub(/^\*/, "", name); if (name == want) { print $1; exit } }' "${SUMS_PATH}"
}

printf '\n'
printf 'Built:      %s\n' "${DMG_PATH}"
printf '            %s\n' "${ZIP_PATH}"
printf 'Version:    %s\n' "${VERSION}"
printf 'Arch:       %s\n' "${ARCH_SUFFIX}"
printf 'Signature:  %s\n' "${SIGNATURE_KIND}"
printf 'Size:       %s (dmg), %s (zip)\n' "$(du -h "${DMG_PATH}" | awk '{print $1}')" "$(du -h "${ZIP_PATH}" | awk '{print $1}')"
printf 'SHA-256:    %s  %s\n' "$(sum_of "${DMG_NAME}")" "${DMG_NAME}"
printf '            %s  %s\n' "$(sum_of "${ZIP_NAME}")" "${ZIP_NAME}"
printf 'Checksums:  %s\n' "${SUMS_PATH}"
printf '\n'
printf 'Verify from the output directory with:\n'
printf '  shasum -a 256 -c %s\n' "${CHECKSUM_FILE}"
printf '\n'
printf 'A release carries %s, %s, %s, Scripts/install.sh and Scripts/uninstall.sh.\n' \
    "${DMG_NAME}" "${ZIP_NAME}" "${CHECKSUM_FILE}"
printf 'Scripts/install.sh refuses to install a downloaded image that has no checksum line.\n'
printf '\n'

exit 0
