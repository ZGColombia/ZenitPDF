#!/usr/bin/env bash
#
# install.sh — the one-line installer for Zenit PDF.
#
#   curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash
#
# .github/workflows/release.yml attaches this file to every GitHub release, so the line above
# always runs the installer published with the newest release. Options go after `bash -s --`:
#
#   curl -fsSL .../install.sh | bash -s -- --version 1.2.0
#
# What it does, in order. Every step stops with a plain-English message when it fails, and
# nothing outside a temporary staging folder (removed again on failure) changes before step 6:
#
#   1. checks that it runs as you (not root), on macOS 14 or later, on Apple silicon or Intel;
#   2. finds the newest release on GitHub (or the one named with --version);
#   3. downloads SHA256SUMS.txt and the disk image over HTTPS and refuses to go on unless the
#      image's SHA-256 matches the published one;
#   4. mounts the image read-only and hidden (-nobrowse: no Finder window), copies the app into
#      a hidden staging folder beside the destination, checks the copy's bundle identifier and
#      code signature, and detaches the image;
#   5. if the copy being replaced is open, asks before quitting it — a normal quit, so Zenit PDF
#      can ask to save changes — and never force-quits it;
#   6. swaps the new copy into place: /Applications by default, your own ~/Applications when you
#      cannot write to /Applications and agree, or the folder given with --dest. The old copy is
#      kept until the new one is in place, and put back if the swap fails (when even that fails,
#      it is kept in the staging folder and its path is printed);
#   7. removes the com.apple.quarantine flag from the installed app only, and registers the app
#      with Launch Services so Finder, Spotlight and "Open With" know it;
#   8. prints where the app went and the one line that uninstalls it.
#
# Why removing the quarantine flag is acceptable here: Zenit PDF is ad-hoc signed and not
# notarized (there is no Apple Developer ID), so a quarantined copy is stopped by Gatekeeper and
# the person has to approve it in System Settings. This script has already checked the download
# against the SHA-256 published with the release, which is the integrity check that approval
# stands in for, so it clears the flag on the one app it installed and on nothing else.
#
# It never runs sudo, sends nothing anywhere (its only network traffic is the downloads from
# GitHub), and writes nothing outside the destination folder and a temporary folder that is
# removed on exit. The whole script is a set of functions called on its last line, so a
# download cut short cannot run half an installer.
#
# Testing without a release: --dmg PATH installs from a local disk image with no network, and
# checks a SHA256SUMS.txt that sits beside it.
#
# Requires: bash 3.2, curl, shasum, hdiutil, ditto, xattr, codesign, plutil — all part of macOS.

set -euo pipefail

# --------------------------------------------------------------------------------------------
# The GitHub repository, in one place. A fork overrides it without editing the file:
#   ZENIT_REPO=someone/ZenitPDF bash install.sh
# The release workflow writes the publishing repository into the copy it attaches.
# --------------------------------------------------------------------------------------------
ZENIT_REPO="${ZENIT_REPO:-ZGColombia/ZenitPDF}"

readonly APP_NAME="Zenit PDF.app"
readonly BUNDLE_ID="com.zenitgroup.zenitpdf"
readonly MIN_MACOS_MAJOR=14
readonly CHECKSUM_FILE="SHA256SUMS.txt"
readonly CHECKSUM_SIGNATURE_FILE="SHA256SUMS.txt.sig"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# How long to wait for an open copy to quit after the person agreed (seconds).
QUIT_TIMEOUT="${ZENIT_INSTALL_QUIT_TIMEOUT:-120}"

# The shared Applications folder. Overridable only so a test can exercise the "not allowed to
# write there" path without touching the real /Applications; nobody else needs to set it.
SYSTEM_APPLICATIONS="${ZENIT_INSTALL_SYSTEM_APPLICATIONS:-/Applications}"

# --------------------------------------------------------------------------------------------
# NL-PLAT-02: the checksum file may be signed with an ECDSA P-256 key the maintainer holds
# (Scripts/checksum-signing-key.sh); stock /usr/bin/openssl (LibreSSL) verifies ECDSA but has
# no Ed25519. The public half is pinned here so a mirror that swaps both the disk image and
# SHA256SUMS.txt is still caught. Empty until the maintainer generates the key: the checksum
# then proves the download is intact, not who published it. Once a key is pinned, a release
# without a valid SHA256SUMS.txt.sig is refused.
# --------------------------------------------------------------------------------------------
readonly CHECKSUM_PUBLIC_KEY_PEM=""

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'Note: %s\n' "$*" >&2; }
die()  { printf '\nZenit PDF was not installed.\n\n%s\n\n' "$*" >&2; exit 1; }
usage_error() { printf 'install.sh: %s\nRun with --help to see the options.\n' "$*" >&2; exit 2; }

# Verifies <signature> over <file> with the pinned PEM public key, using only the stock
# /usr/bin/openssl. Returns non-zero on any failure. Scripts/checksum-signing-key.sh selftest
# lifts this function out of this file by its first and last line, so keep both as they are.
verify_signed_checksums() {
    local public_pem="$1" sums="$2" signature="$3" scratch
    [ -n "${public_pem}" ] || return 2
    scratch="$(mktemp -d)" || return 2
    printf '%s\n' "${public_pem}" > "${scratch}/checksums-public.pem"
    if /usr/bin/openssl dgst -sha256 -verify "${scratch}/checksums-public.pem" \
            -signature "${signature}" "${sums}" >/dev/null 2>&1; then
        rm -rf "${scratch}"
        return 0
    fi
    rm -rf "${scratch}"
    return 1
}

usage() {
    cat <<USAGE
Install Zenit PDF from GitHub.

  curl -fsSL https://github.com/${ZENIT_REPO}/releases/latest/download/install.sh | bash

Options (put them after "bash -s --" when the script comes from curl):
  --version X.Y.Z   install that release instead of the newest one
  --dest DIR        install into DIR instead of /Applications
  --dmg PATH        install from a disk image already on this Mac, with no network;
                    a SHA256SUMS.txt beside it is checked when present
  --yes, -y         answer yes to the questions (quit an open copy normally; use
                    ~/Applications when /Applications is not writable)
  --dry-run, -n     show what would happen and change nothing
  --help, -h        show this help

Example:
  curl -fsSL https://github.com/${ZENIT_REPO}/releases/latest/download/install.sh | bash -s -- --version 1.0.0
USAGE
}

# --------------------------------------------------------------------------------------------
# State, and the cleanup that runs on every exit.
# --------------------------------------------------------------------------------------------
WANT_VERSION=""
DEST_DIR=""
LOCAL_DMG=""
ASSUME_YES="no"
DRY_RUN="no"

WORK_DIR=""
MOUNT_POINT=""
STAGE_PARENT=""
STAGED_APP=""
OLD_BACKUP=""
TARGET=""

detach_image() {
    hdiutil detach "$1" -quiet </dev/null >/dev/null 2>&1 \
        || hdiutil detach "$1" -force -quiet </dev/null >/dev/null 2>&1
}

cleanup() {
    local rc=$?
    if [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ]; then
        detach_image "${MOUNT_POINT}" || printf 'Note: could not detach the disk image at %s; eject it in Finder.\n' "${MOUNT_POINT}" >&2
    fi
    # Stopped between moving the old copy aside and moving the new one in: put it back when its
    # place is free; otherwise keep it, and say where it is.
    if [ -n "${OLD_BACKUP}" ] && [ -e "${OLD_BACKUP}" ]; then
        if [ -n "${TARGET}" ] && [ ! -e "${TARGET}" ] && [ ! -L "${TARGET}" ] \
                && mv "${OLD_BACKUP}" "${TARGET}" 2>/dev/null; then
            printf 'Note: the previous copy was put back at %s.\n' "${TARGET}" >&2
        else
            printf 'Note: the previous copy is kept at %s; move it back to %s.\n' "${OLD_BACKUP}" "${TARGET}" >&2
        fi
    fi
    if [ -n "${STAGE_PARENT}" ] && [ -d "${STAGE_PARENT}" ]; then
        if [ -z "${OLD_BACKUP}" ] || [ ! -e "${OLD_BACKUP}" ]; then
            rm -rf "${STAGE_PARENT}" 2>/dev/null || true
        else
            # The previous copy is still in there, so only the unused new copy goes.
            rm -rf "${STAGE_PARENT}/new.noindex" 2>/dev/null || true
        fi
    fi
    if [ "${rc}" -ne 0 ] && [ "${DEST_CREATED}" = "yes" ]; then
        remove_created_destination
    fi
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" 2>/dev/null || true
    fi
    return "${rc}"
}

# --------------------------------------------------------------------------------------------
# Small helpers.
# --------------------------------------------------------------------------------------------

# True when a keyboard can be asked. With `curl | bash` standard input is the script itself, so
# questions are read from /dev/tty, which fails to open when there is no terminal at all.
tty_available() { ( : </dev/tty ) 2>/dev/null; }

# confirm <question> <default yes|no> — 0 for yes.
confirm() {
    local question="$1" default="$2" hint="[y/N]" answer=""
    [ "${default}" = "yes" ] && hint="[Y/n]"
    if [ "${ASSUME_YES}" = "yes" ]; then
        say "${question} ${hint} yes (--yes)"
        return 0
    fi
    if ! tty_available; then
        say "${question} ${hint} — no keyboard to ask, so the answer is ${default}."
        [ "${default}" = "yes" ]
        return
    fi
    printf '%s %s ' "${question}" "${hint}" >&2
    IFS= read -r answer </dev/tty || answer=""
    case "${answer}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        "") [ "${default}" = "yes" ] ;;
        *) return 1 ;;
    esac
}

free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }

# need_space <folder> <kilobytes> — stops with a friendly message when the disk is too full.
need_space() {
    local free
    free="$(free_kb "$1")"
    case "${free}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "${free}" -lt "$2" ]; then
        die "There is not enough free disk space.
  Needed:    about $(( $2 / 1024 + 1 )) MB
  Available: $(( free / 1024 )) MB on the disk that holds ${1}

Empty the Trash or delete files you no longer need, then run the installer again.
Nothing was changed."
    fi
}

plist_value() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# Process ids whose executable lives inside <app>/Contents/MacOS/. Fixed-string match, read
# from the environment so the pattern never appears on a command line of its own.
running_pids() {
    ps -axww -o pid= -o command= 2>/dev/null | ZENIT_PREFIX="$1/Contents/MacOS/" awk '
        { pid = $1; cmd = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", cmd)
          if (index(cmd, ENVIRON["ZENIT_PREFIX"]) == 1) print pid }'
}

# --------------------------------------------------------------------------------------------
# Network. Every download is HTTPS-only, including redirects.
# --------------------------------------------------------------------------------------------
CURL_BASE=(--proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --retry 3 --retry-delay 2)

network_failure() {
    local rc="$1" what="$2" url="$3"
    case "${rc}" in
        6)  die "Could not find GitHub on the internet while downloading ${what}.
Check that this Mac is connected to the internet (open any website to test), then run the
installer again. Nothing was changed." ;;
        7|28|52|55|56)
            die "The connection to GitHub failed or timed out while downloading ${what}.
Check your internet connection and try again in a few minutes. Nothing was changed." ;;
        22) die "GitHub could not provide ${what} (HTTP ${4:-error}):
  ${url}
The release may not exist, or GitHub may be having trouble. All releases are listed at
  https://github.com/${ZENIT_REPO}/releases
Nothing was changed." ;;
        23) local free; free="$(free_kb "${WORK_DIR:-${TMPDIR:-/tmp}}")"
            die "The download of ${what} could not be saved; the disk is probably full
($(( ${free:-0} / 1024 )) MB free). Free some space and run the installer again.
Nothing was changed." ;;
        35|51|53|54|58|59|60|77|80|82|83|90|91)
            die "A secure connection to GitHub could not be confirmed while downloading ${what}.
This usually means the Mac's date and time are wrong, or a network filter or proxy is in the
way. Check the date and time, try another network, and run the installer again.
Nothing was changed." ;;
        *)  die "Downloading ${what} failed (curl error ${rc}).
Check your internet connection and run the installer again. Nothing was changed." ;;
    esac
}

# download <url> <file> <what> [progress] [range]. The HTTP status decides, not curl's exit code:
# curl reports an HTTP error under different codes depending on the protocol version.
download() {
    local rc=0 code="" mode="--silent"
    [ "${4:-}" = "progress" ] && [ -t 2 ] && mode="--progress-bar"
    if [ "${5:-}" = "range" ]; then
        code="$(curl "${CURL_BASE[@]}" --location "${mode}" --show-error -r 0-0 -o "$2" -w '%{http_code}' "$1" </dev/null)" || rc=$?
    else
        code="$(curl "${CURL_BASE[@]}" --location "${mode}" --show-error -o "$2" -w '%{http_code}' "$1" </dev/null)" || rc=$?
    fi
    case "${code}" in
        200|206) [ "${rc}" -eq 0 ] || network_failure "${rc}" "$3" "$1" ;;
        4??|5??) rm -f "$2"; network_failure 22 "$3" "$1" "${code}" ;;
        *)       network_failure "$(( rc == 0 ? 1 : rc ))" "$3" "$1" ;;
    esac
}

# Here-strings, not `printf | grep -q`: under pipefail an early-exiting grep -q can kill the
# writer with SIGPIPE and turn a match into a failure.
valid_tag() { grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' <<<"$1"; }

# Sets TAG: from --version, else from the redirect GitHub answers for /releases/latest (no API
# rate limit), else from the releases API.
TAG=""
resolve_tag() {
    if [ -n "${WANT_VERSION}" ]; then
        TAG="v${WANT_VERSION#v}"
        valid_tag "${TAG}" || usage_error "'${WANT_VERSION}' is not a version number like 1.2.0"
        return 0
    fi
    step "Finding the newest release of Zenit PDF..."
    local location="" rc=0 json
    location="$(curl "${CURL_BASE[@]}" --silent --show-error -o /dev/null -w '%{redirect_url}' \
        "https://github.com/${ZENIT_REPO}/releases/latest" </dev/null)" || rc=$?
    [ "${rc}" -eq 0 ] || network_failure "${rc}" "the list of releases" "https://github.com/${ZENIT_REPO}/releases/latest"
    case "${location}" in
        */releases/tag/*) TAG="${location##*/releases/tag/}"; TAG="${TAG%%[?#]*}" ;;
    esac
    if [ -z "${TAG}" ]; then
        json="${WORK_DIR}/latest.json"
        if curl "${CURL_BASE[@]}" --fail --silent -H "Accept: application/vnd.github+json" \
                -o "${json}" "https://api.github.com/repos/${ZENIT_REPO}/releases/latest" </dev/null; then
            TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${json}" | head -n 1 || true)"
        fi
    fi
    [ -n "${TAG}" ] || die "No published release of Zenit PDF was found at
  https://github.com/${ZENIT_REPO}/releases
If that page lists a release, wait a minute and try again. Nothing was changed."
    valid_tag "${TAG}" || die "GitHub reported an unexpected release name ('${TAG}'). Nothing was changed."
}

# expected_sum <sums file> <asset name> — the hex digest on the line for exactly that name.
expected_sum() {
    awk -v want="$2" '{ name = $2; sub(/^\*/, "", name); if (name == want) { print tolower($1); exit } }' "$1"
}

# pick_dmg <sums file> <arch> [version] — ZenitPDF-<version>-universal.dmg when a version is
# given and listed, else the first universal image, then one for this processor, then any
# image; names are limited to safe characters. One awk pass, so no pipe can break early.
pick_dmg() {
    local exact=""
    [ -n "${3:-}" ] && exact="ZenitPDF-${3}-universal.dmg"
    awk -v arch="$2" -v exact="${exact}" '
        { name = $2; sub(/^\*/, "", name)
          if (name !~ /^[A-Za-z0-9._-]+\.dmg$/) next
          if (exact != "" && name == exact) wanted = name
          if (universal == "" && name ~ /-universal\.dmg$/) universal = name
          if (native == "" && index(name, "-" arch ".dmg") > 0) native = name
          if (any == "") any = name }
        END { if (wanted != "") print wanted; else if (universal != "") print universal; else if (native != "") print native; else if (any != "") print any }' "$1"
}

# check_signature <sums file> <signature file or empty>
check_signature() {
    if [ -z "${CHECKSUM_PUBLIC_KEY_PEM}" ]; then
        return 0
    fi
    [ -n "$2" ] && [ -f "$2" ] || die "This release has no ${CHECKSUM_SIGNATURE_FILE}, and this installer only installs
a release whose checksum list is signed by the Zenit PDF release key.
Please report it at https://github.com/${ZENIT_REPO}/issues. Nothing was changed."
    verify_signed_checksums "${CHECKSUM_PUBLIC_KEY_PEM}" "$1" "$2" \
        || die "The signature on ${CHECKSUM_FILE} does not match the Zenit PDF release key, so the
download cannot be trusted. Please report it at https://github.com/${ZENIT_REPO}/issues.
Nothing was changed."
    note "${CHECKSUM_FILE} is signed by the Zenit PDF release key"
}

# verify_checksum <file> <sums file> <asset name>
verify_checksum() {
    local expected actual
    expected="$(expected_sum "$2" "$3")"
    grep -Eq '^[0-9a-f]{64}$' <<<"${expected}" \
        || die "${CHECKSUM_FILE} has no valid line for ${3}, so the download cannot be checked.
Nothing was changed."
    actual="$(shasum -a 256 "$1" | awk '{ print $1 }')"
    if [ "${expected}" != "${actual}" ]; then
        die "The downloaded file does not match its published checksum, so it was NOT installed.
  File:     ${3}
  Expected: ${expected}
  Actual:   ${actual}

The file may be incomplete or may have been changed. Run the installer again; if this
message comes back, report it at https://github.com/${ZENIT_REPO}/issues.
Nothing was changed."
    fi
    note "SHA-256 matches: ${actual}"
}

# --------------------------------------------------------------------------------------------
# Steps.
# --------------------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --version)   [ $# -ge 2 ] || usage_error "--version needs a number, for example --version 1.2.0"
                         WANT_VERSION="$2"; shift 2 ;;
            --version=*) WANT_VERSION="${1#*=}"; shift ;;
            --dest)      [ $# -ge 2 ] || usage_error "--dest needs a folder"
                         DEST_DIR="$2"; shift 2 ;;
            --dest=*)    DEST_DIR="${1#*=}"; shift ;;
            --dmg)       [ $# -ge 2 ] || usage_error "--dmg needs the path of a disk image"
                         LOCAL_DMG="$2"; shift 2 ;;
            --dmg=*)     LOCAL_DMG="${1#*=}"; shift ;;
            --yes|-y)    ASSUME_YES="yes"; shift ;;
            --dry-run|-n) DRY_RUN="yes"; shift ;;
            --help|-h)   usage; exit 0 ;;
            *)           usage_error "unknown option: $1" ;;
        esac
    done
    if [ -n "${WANT_VERSION}" ] && ! valid_tag "v${WANT_VERSION#v}"; then
        usage_error "'${WANT_VERSION}' is not a version number like 1.2.0"
    fi
    if [ -n "${LOCAL_DMG}" ] && [ -n "${WANT_VERSION}" ]; then
        usage_error "use either --dmg or --version, not both"
    fi
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"${ZENIT_REPO}" \
        || usage_error "ZENIT_REPO must look like owner/repository, not '${ZENIT_REPO}'"
}

MACOS_VERSION=""
ARCH=""
check_platform() {
    if [ "$(id -u)" -eq 0 ]; then
        die "Please run the installer as yourself, without sudo.
Installed as root, the app would belong to root and later updates would fail."
    fi
    [ "$(uname -s)" = "Darwin" ] || die "Zenit PDF runs on macOS only."

    MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
    local major="${MACOS_VERSION%%.*}"
    case "${major}" in ''|*[!0-9]*) die "Could not read the macOS version of this Mac." ;; esac
    if [ "${major}" -lt "${MIN_MACOS_MAJOR}" ]; then
        die "Zenit PDF needs macOS 14 Sonoma or later; this Mac runs macOS ${MACOS_VERSION}.
Update macOS in System Settings > General > Software Update, then run the installer again."
    fi

    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
        ARCH="arm64"
    else
        case "$(uname -m)" in
            x86_64) ARCH="x86_64" ;;
            *) die "This Mac's processor ($(uname -m)) is not one Zenit PDF supports." ;;
        esac
    fi

    local tool
    for tool in curl shasum hdiutil ditto xattr codesign plutil awk; do
        command -v "${tool}" >/dev/null 2>&1 \
            || die "The command '${tool}' is missing. It is normally part of macOS."
    done
}

# Sets DMG_FILE, ASSET_NAME, CHECKSUM_STATE (and DMG_URL for a download).
DMG_FILE=""
DMG_URL=""
ASSET_NAME=""
CHECKSUM_STATE=""
obtain_image() {
    local sums sig_file=""
    if [ -n "${LOCAL_DMG}" ]; then
        [ -f "${LOCAL_DMG}" ] || die "There is no file at ${LOCAL_DMG}."
        case "${LOCAL_DMG}" in *.dmg) ;; *) die "${LOCAL_DMG} is not a disk image (.dmg)." ;; esac
        DMG_FILE="$(cd "$(dirname "${LOCAL_DMG}")" && pwd)/$(basename "${LOCAL_DMG}")"
        ASSET_NAME="$(basename "${DMG_FILE}")"
        sums="$(dirname "${DMG_FILE}")/${CHECKSUM_FILE}"
        step "Checking ${ASSET_NAME}..."
        if [ -f "${sums}" ]; then
            [ -f "${sums}.sig" ] && sig_file="${sums}.sig"
            check_signature "${sums}" "${sig_file}"
            verify_checksum "${DMG_FILE}" "${sums}" "${ASSET_NAME}"
            CHECKSUM_STATE="SHA-256 matches ${CHECKSUM_FILE} beside the disk image"
        else
            warn "there is no ${CHECKSUM_FILE} beside ${ASSET_NAME}, so its checksum cannot be checked.
      It is installed anyway because you chose this file yourself."
            CHECKSUM_STATE="not checked (no ${CHECKSUM_FILE} beside the disk image)"
        fi
        return 0
    fi

    resolve_tag
    local base="https://github.com/${ZENIT_REPO}/releases/download/${TAG}"
    note "Release: ${TAG}"
    sums="${WORK_DIR}/${CHECKSUM_FILE}"
    download "${base}/${CHECKSUM_FILE}" "${sums}" "the checksum list of release ${TAG}"
    ASSET_NAME="$(pick_dmg "${sums}" "${ARCH}" "${TAG#v}")"
    [ -n "${ASSET_NAME}" ] || die "Release ${TAG} lists no disk image in its ${CHECKSUM_FILE}.
Please report it at https://github.com/${ZENIT_REPO}/issues. Nothing was changed."
    DMG_URL="${base}/${ASSET_NAME}"

    if [ -n "${CHECKSUM_PUBLIC_KEY_PEM}" ]; then
        sig_file="${WORK_DIR}/${CHECKSUM_SIGNATURE_FILE}"
        download "${base}/${CHECKSUM_SIGNATURE_FILE}" "${sig_file}" "the checksum signature of release ${TAG}"
    fi
    check_signature "${sums}" "${sig_file}"

    if [ "${DRY_RUN}" = "yes" ]; then
        # Prove the image is there without downloading it: ask for its first byte.
        download "${DMG_URL}" "${WORK_DIR}/first-byte" "${ASSET_NAME}" quiet range
        note "Disk image: ${DMG_URL} (reachable; not downloaded in a dry run)"
        CHECKSUM_STATE="would be checked against $(expected_sum "${sums}" "${ASSET_NAME}")"
        return 0
    fi

    need_space "${WORK_DIR}" $(( 200 * 1024 ))
    DMG_FILE="${WORK_DIR}/${ASSET_NAME}"
    step "Downloading ${ASSET_NAME}..."
    download "${DMG_URL}" "${DMG_FILE}" "${ASSET_NAME}" progress
    step "Checking the download..."
    verify_checksum "${DMG_FILE}" "${sums}" "${ASSET_NAME}"
    CHECKSUM_STATE="SHA-256 matches ${CHECKSUM_FILE} of release ${TAG}"
}

# A destination folder that does not exist yet is created only when the app is copied, so a
# refused download leaves no empty folder behind. If a later step stops the run, the folder
# and any parents created for it are removed again while they are still empty.
DEST_NEEDS_CREATE="no"
DEST_CREATED="no"
DEST_EXISTING_PARENT=""
missing_destination() {
    local parent="${DEST_DIR}"
    while [ ! -d "${parent}" ]; do parent="$(dirname "${parent}")"; done
    [ -w "${parent}" ] || die "The folder ${DEST_DIR} cannot be created: you cannot write to ${parent}.
Choose another folder. Nothing was changed."
    DEST_NEEDS_CREATE="yes"
    DEST_EXISTING_PARENT="${parent}"
    note "${DEST_DIR} does not exist yet and will be created"
}

# Removes DEST_DIR and the parents created for it, deepest first, up to the folder that
# already existed. rmdir removes only an empty folder, so it stops at the first one in use.
remove_created_destination() {
    local dir="${DEST_DIR}"
    while [ -n "${dir}" ] && [ "${dir}" != "${DEST_EXISTING_PARENT}" ] \
            && [ "${dir}" != "/" ] && [ "${dir}" != "." ]; do
        if [ -d "${dir}" ]; then
            rmdir "${dir}" 2>/dev/null || return 0
        fi
        dir="$(dirname "${dir}")"
    done
}

# Sets DEST_DIR and TARGET.
choose_destination() {
    if [ -n "${DEST_DIR}" ]; then
        case "${DEST_DIR}" in "~") DEST_DIR="${HOME}" ;; "~/"*) DEST_DIR="${HOME}/${DEST_DIR#\~/}" ;; esac
        case "${DEST_DIR}" in *.app|*.app/) usage_error "--dest takes the folder to install into, not an app" ;; esac
        case "${DEST_DIR}" in /*) ;; *) DEST_DIR="$(pwd)/${DEST_DIR}" ;; esac
        if [ -d "${DEST_DIR}" ]; then
            DEST_DIR="$(cd "${DEST_DIR}" && pwd)"
            [ -w "${DEST_DIR}" ] || die "You cannot write to ${DEST_DIR}. Choose another folder. Nothing was changed."
        else
            missing_destination
        fi
        TARGET="${DEST_DIR}/${APP_NAME}"
        return 0
    fi

    DEST_DIR="${SYSTEM_APPLICATIONS}"
    # Updating a copy that an earlier run put in ~/Applications: replace it where it is.
    if [ ! -e "${SYSTEM_APPLICATIONS}/${APP_NAME}" ] && [ -d "${HOME}/Applications/${APP_NAME}" ]; then
        DEST_DIR="${HOME}/Applications"
        note "Found Zenit PDF in ${DEST_DIR}; updating it there."
    fi
    TARGET="${DEST_DIR}/${APP_NAME}"

    local reason=""
    if [ ! -w "${DEST_DIR}" ]; then
        reason="Your user account cannot add apps to ${DEST_DIR} (it needs an administrator)."
    elif [ -e "${TARGET}" ] && [ -n "$(find "${TARGET}" ! -user "$(id -u)" -print 2>/dev/null | head -n 1 || true)" ]; then
        reason="The Zenit PDF already in ${DEST_DIR} was installed by another user account, so
this account cannot replace it."
    fi
    if [ -n "${reason}" ]; then
        say "${reason}"
        if confirm "Install Zenit PDF just for you, in your own Applications folder (~/Applications)?" yes; then
            DEST_DIR="${HOME}/Applications"
            TARGET="${DEST_DIR}/${APP_NAME}"
            [ -d "${DEST_DIR}" ] || missing_destination
        else
            die "Nothing was changed. Ask an administrator of this Mac to run the installer, or run it
again and answer yes to install into ~/Applications."
        fi
    fi
}

# Refuses to replace something that is not Zenit PDF; reports what will be replaced.
EXISTING_VERSION=""
inspect_target() {
    [ -e "${TARGET}" ] || [ -L "${TARGET}" ] || return 0
    local existing_id
    existing_id="$(plist_value "${TARGET}" CFBundleIdentifier)"
    if [ -n "${existing_id}" ] && [ "${existing_id}" != "${BUNDLE_ID}" ]; then
        die "${TARGET} already exists but is not Zenit PDF (it identifies itself as ${existing_id}).
Move it somewhere else, then run the installer again. Nothing was changed."
    fi
    # A folder with this name but no readable bundle identifier is not provably Zenit PDF, so it
    # is never replaced (and later deleted). A symbolic link is: only the link itself is moved.
    if [ -z "${existing_id}" ] && [ ! -L "${TARGET}" ]; then
        die "${TARGET} already exists, but it has no readable bundle identifier, so it cannot be
confirmed to be Zenit PDF. Move it somewhere else, then run the installer again. Nothing was changed."
    fi
    EXISTING_VERSION="$(plist_value "${TARGET}" CFBundleShortVersionString)"
    note "Replaces Zenit PDF ${EXISTING_VERSION:-(unknown version)} at ${TARGET}"
}

# Asks before quitting an open copy at TARGET, quits it normally, and waits.
quit_running_copy() {
    local pids pid waited=0
    pids="$(running_pids "${TARGET}")"
    [ -n "${pids}" ] || return 0
    say ""
    say "Zenit PDF is open. It has to be closed before the new version can replace it."
    if [ "${DRY_RUN}" = "yes" ]; then
        note "A real run would ask before quitting it."
        return 0
    fi
    if ! confirm "Quit Zenit PDF now? It will ask you to save any unsaved changes first." no; then
        die "Zenit PDF is still open, so nothing was changed. Save your work, quit Zenit PDF
(Zenit PDF menu > Quit Zenit PDF) and run the installer again."
    fi
    for pid in ${pids}; do
        # A normal quit request to that one process (NSRunningApplication -terminate), never a
        # kill: the app can still ask to save, and the person can still cancel.
        osascript -l JavaScript -e '
            function run(argv) {
                ObjC.import("AppKit");
                var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(argv[0], 10));
                if (app && !app.isNil()) { app.terminate; return "asked"; }
                return "not found";
            }' "${pid}" </dev/null >/dev/null 2>&1 || true
    done
    while [ -n "$(running_pids "${TARGET}")" ]; do
        if [ "${waited}" -ge "${QUIT_TIMEOUT}" ]; then
            die "Zenit PDF did not quit (it may be waiting for an answer, or Cancel was chosen).
Nothing was changed. Quit Zenit PDF yourself and run the installer again."
        fi
        if [ "${waited}" -eq 2 ]; then
            say "Waiting for Zenit PDF to quit. If it asks whether to save your changes, answer it."
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    note "Zenit PDF has quit."
}

INSTALLED_VERSION=""
install_app() {
    MOUNT_POINT="${WORK_DIR}/mount"
    mkdir -p "${MOUNT_POINT}"
    step "Opening the disk image (read-only, no Finder window)..."
    if ! hdiutil attach "${DMG_FILE}" -readonly -nobrowse -noautoopen -mountpoint "${MOUNT_POINT}" -quiet </dev/null >/dev/null 2>&1; then
        MOUNT_POINT=""
        die "The disk image ${ASSET_NAME} could not be opened. It may be damaged; run the
installer again to download a fresh copy. Nothing was changed."
    fi
    local source_app="${MOUNT_POINT}/${APP_NAME}" size_kb
    [ -d "${source_app}" ] || die "The disk image does not contain ${APP_NAME}. Nothing was changed."

    if [ "${DEST_NEEDS_CREATE}" = "yes" ]; then
        DEST_CREATED="yes"
        mkdir -p "${DEST_DIR}" 2>/dev/null || die "Could not create the folder ${DEST_DIR}. Nothing was changed."
    fi
    size_kb="$(du -sk "${source_app}" | awk '{ print $1 }')"
    need_space "${DEST_DIR}" $(( size_kb + 20 * 1024 ))

    # Stage beside the destination, on the same disk, so the final step is a rename.
    STAGE_PARENT="$(mktemp -d "${DEST_DIR}/.zenitpdf-install.XXXXXX")" \
        || die "Could not write to ${DEST_DIR}. Nothing was changed."
    # The .noindex folder keeps Spotlight from listing the half-copied app.
    mkdir -p "${STAGE_PARENT}/new.noindex"
    STAGED_APP="${STAGE_PARENT}/new.noindex/${APP_NAME}"
    step "Copying Zenit PDF..."
    if ! ditto "${source_app}" "${STAGED_APP}" </dev/null 2>/dev/null; then
        rm -rf "${STAGED_APP}"
        local free; free="$(free_kb "${DEST_DIR}")"
        die "Copying the app into ${DEST_DIR} failed ($(( ${free:-0} / 1024 )) MB free there).
If the disk is full, free some space and run the installer again. Nothing was changed."
    fi
    detach_image "${MOUNT_POINT}" || warn "could not detach the disk image; eject it in Finder."
    MOUNT_POINT=""

    [ "$(plist_value "${STAGED_APP}" CFBundleIdentifier)" = "${BUNDLE_ID}" ] \
        || die "The app in the disk image is not Zenit PDF (wrong bundle identifier). Nothing was changed."
    codesign --verify --deep --strict "${STAGED_APP}" >/dev/null 2>&1 \
        || die "The app's code signature does not verify, so it may be damaged or altered.
Run the installer again; if this comes back, report it at
https://github.com/${ZENIT_REPO}/issues. Nothing was changed."
    INSTALLED_VERSION="$(plist_value "${STAGED_APP}" CFBundleShortVersionString)"
    if [ -n "${TAG}" ] && [ -n "${INSTALLED_VERSION}" ] && [ "v${INSTALLED_VERSION}" != "${TAG}" ]; then
        warn "the app reports version ${INSTALLED_VERSION}, release ${TAG}."
    fi
    note "Code signature valid, version ${INSTALLED_VERSION:-unknown}"

    # The installed app only; no other file's flag is touched.
    xattr -dr com.apple.quarantine "${STAGED_APP}" 2>/dev/null || true

    quit_running_copy

    step "Installing into ${DEST_DIR}..."
    if [ -e "${TARGET}" ] || [ -L "${TARGET}" ]; then
        mkdir -p "${STAGE_PARENT}/previous.noindex"
        OLD_BACKUP="${STAGE_PARENT}/previous.noindex/${APP_NAME}"
        mv "${TARGET}" "${OLD_BACKUP}" 2>/dev/null || {
            OLD_BACKUP=""
            die "The existing copy at ${TARGET} could not be moved aside, so it was left as it was.
If Zenit PDF is open, quit it; then run the installer again."
        }
        if ! mv "${STAGED_APP}" "${TARGET}" 2>/dev/null; then
            if mv "${OLD_BACKUP}" "${TARGET}" 2>/dev/null; then
                OLD_BACKUP=""
                die "The new copy could not be moved into ${DEST_DIR}; the previous version was put back."
            fi
            # OLD_BACKUP stays set, so cleanup keeps the previous copy and says where it is.
            die "The new copy could not be moved into ${DEST_DIR}, and the previous version could not
be put back either. It is kept at
  ${OLD_BACKUP}
Move it back to ${TARGET}, then run the installer again."
        fi
        # The new copy is in place, so the swap is finished: cleared first, so that a stop during the
        # delete removes the staging folder instead of offering a half-deleted copy back.
        local previous="${OLD_BACKUP}"
        OLD_BACKUP=""
        rm -rf "${previous}" 2>/dev/null || warn "the previous copy could not be removed from ${previous%/*}."
    else
        mv "${STAGED_APP}" "${TARGET}" 2>/dev/null \
            || die "The app could not be moved into ${DEST_DIR}. Nothing was changed."
    fi
    STAGED_APP=""
    rm -rf "${STAGE_PARENT}" 2>/dev/null || true
    STAGE_PARENT=""

    xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true
    if [ -x "${LSREGISTER}" ]; then
        "${LSREGISTER}" -f "${TARGET}" </dev/null >/dev/null 2>&1 \
            || warn "Launch Services did not register the app; it still works, Finder may take a moment to list it."
    fi
}

uninstall_line() {
    local line="curl -fsSL https://github.com/${ZENIT_REPO}/releases/latest/download/uninstall.sh | bash"
    case "${TARGET}" in
        "/Applications/${APP_NAME}"|"${HOME}/Applications/${APP_NAME}") printf '%s\n' "${line}" ;;  # uninstall.sh looks there
        *) printf '%s -s -- --app "%s"\n' "${line}" "${TARGET}" ;;
    esac
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    check_platform
    say ""
    say "Zenit PDF installer"
    note "macOS ${MACOS_VERSION}, $( [ "${ARCH}" = arm64 ] && echo "Apple silicon" || echo "Intel" )"
    [ "${DRY_RUN}" = "yes" ] && note "Dry run: nothing on this Mac will be changed."
    say ""

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zenitpdf-install.XXXXXXXX")"
    # Where it goes first, so a folder that cannot be written, or something else already named
    # Zenit PDF.app, is reported before anything is downloaded.
    if [ -n "${LOCAL_DMG}" ] && [ ! -f "${LOCAL_DMG}" ]; then
        die "There is no file at ${LOCAL_DMG}."
    fi
    choose_destination
    inspect_target
    obtain_image

    if [ "${DRY_RUN}" = "yes" ]; then
        if [ -e "${TARGET}" ]; then quit_running_copy; fi
        say ""
        say "Dry run complete. A real run would:"
        say "  - install ${ASSET_NAME} into ${TARGET}"
        say "  - checksum: ${CHECKSUM_STATE}"
        say "  - remove the download flag from that app and register it with Launch Services"
        say "Nothing was changed."
        exit 0
    fi

    install_app

    say ""
    say "Zenit PDF ${INSTALLED_VERSION} is installed."
    say "  Location: ${TARGET}"
    say "  Checked:  ${CHECKSUM_STATE}; code signature valid"
    say ""
    say "Open it from the Applications folder or Spotlight. No security warning should appear:"
    say "this installer checked the download and cleared its download flag for you."
    say ""
    say "To uninstall later, run the line below. It removes every copy of Zenit PDF it finds,"
    say "this one included, and Zenit PDF's own settings; it lists them and asks first."
    say "  $(uninstall_line)"
    say ""
}

main "$@"
