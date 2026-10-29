#!/usr/bin/env bash
#
# uninstall.sh — remove Zenit PDF and the state it leaves behind.
#
#   curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/uninstall.sh | bash
#
# .github/workflows/release.yml attaches this file to every GitHub release, beside install.sh.
# Options go after `bash -s --`:
#
#   --dry-run, -n   list what would be removed and stop
#   --app PATH      also remove a copy installed somewhere other than /Applications or
#                   ~/Applications (install.sh --dest prints this form for you); the path must
#                   be a Zenit PDF app bundle, checked by its bundle identifier
#   --help, -h      show the options
#
# It removes the app and Zenit PDF's own data only: its sandbox containers, preferences, caches,
# saved window state and logs. It lists every path first, refuses while Zenit PDF is open
# (a copy it is about to remove, by path, or any copy, by bundle identifier through lsappinfo),
# and deletes nothing until DELETE is typed at the keyboard. It never touches your own documents:
# projects, PDFs and exports live wherever you saved them and are never candidates here.
#
# The path list is derived from the bundle identifier and from where macOS places
# per-application state, and was checked against a real, exercised installation. Each embedded
# XPC service gets a sandbox container of its own; both are named explicitly, and a sweep of
# ${BUNDLE_ID}.* containers catches any service or extension a later version embeds. Per-host
# preferences are named ${BUNDLE_ID}.<host UUID>.plist, so they are found by a sweep as well.
#
# A sandbox container under ~/Library/Containers is protected by macOS, not merely by file
# ownership. `rm -rf`, `mv` and Finder scripting all returned
# "Operation not permitted" from a process without Full Disk Access, and sudo does not help
# because the restriction does not turn on the user id. The failure report at the end therefore
# separates container failures from ordinary permission failures and gives each the remedy that
# works.
#
# `--dry-run` lists every path that exists, including containers the sweep finds that no line
# of this script names, and `--app` refuses any bundle whose identifier is not Zenit PDF's.
#
# The whole script is a set of functions called on its last line, so a download cut short
# cannot run half of it.
#
# Requires: bash 3.2, rm, defaults, plutil, lsappinfo — all part of macOS.

set -euo pipefail

# The repository slug, used for the links printed below. Override: ZENIT_REPO=owner/repo.
ZENIT_REPO="${ZENIT_REPO:-ZGColombia/ZenitPDF}"

readonly APP_NAME="Zenit PDF.app"
readonly BUNDLE_ID="com.zenitgroup.zenitpdf"
readonly CONFIRM_WORD="DELETE"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
die()  { printf 'ABORTED: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
Remove Zenit PDF and its own data (settings, caches, sandbox containers).

  curl -fsSL https://github.com/${ZENIT_REPO}/releases/latest/download/uninstall.sh | bash

Options (after "bash -s --" when the script comes from curl):
  --dry-run, -n   list what would be removed and stop
  --app PATH      also remove the Zenit PDF app at PATH
  --help, -h      show this help

Your own projects, PDF drawings and exports are never touched.
USAGE
}

# Note: an empty array cannot be expanded under `set -u` in bash 3.2, which is the bash macOS
# ships. Every array expansion below is either guaranteed non-empty or guarded by a count test.
DRY_RUN="no"
EXTRA_APPS=()

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run|-n) DRY_RUN="yes"; shift ;;
            --app) [ $# -ge 2 ] || die "--app needs the path of the app"
                   add_extra_app "$2"; shift 2 ;;
            --app=*) add_extra_app "${1#*=}"; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "unknown argument: $1  (valid: --dry-run, --app PATH, --help)" ;;
        esac
    done
}

# Only a bundle that identifies itself as Zenit PDF can be named with --app.
add_extra_app() {
    local path="${1%/}" identifier
    case "${path}" in "~/"*) path="${HOME}/${path#\~/}" ;; esac
    case "${path}" in *.app) ;; *) die "--app must name an app bundle (…/${APP_NAME}), not '${1}'" ;; esac
    [ -d "${path}" ] || die "there is no app at ${path}"
    identifier="$(plutil -extract CFBundleIdentifier raw -o - "${path}/Contents/Info.plist" 2>/dev/null || true)"
    [ "${identifier}" = "${BUNDLE_ID}" ] \
        || die "${path} is not Zenit PDF (its bundle identifier is '${identifier:-missing}'); refusing to remove it"
    EXTRA_APPS+=("$(cd "$(dirname "${path}")" && pwd)/$(basename "${path}")")
}

# True when a keyboard can be asked. With `curl | bash` standard input is the script itself, so
# the confirmation is read from /dev/tty, which fails to open when there is no terminal at all.
tty_available() { ( : </dev/tty ) 2>/dev/null; }

# Process ids whose executable lives inside <app>/Contents/MacOS/ (fixed-string match).
running_pids() {
    ps -axww -o pid= -o command= 2>/dev/null | ZENIT_PREFIX="$1/Contents/MacOS/" awk '
        { pid = $1; cmd = $0; sub(/^[ \t]*[0-9]+[ \t]+/, "", cmd)
          if (index(cmd, ENVIRON["ZENIT_PREFIX"]) == 1) print pid }'
}

# True when Launch Services lists a running app with Zenit PDF's bundle identifier, wherever
# it was opened from: the mounted disk image, a translocated copy in Downloads, or a folder
# this script does not look in. lsappinfo prints an ASN line per match and a blank line for
# none; without lsappinfo, only the path check in refuse_if_running applies.
running_by_bundle_id() {
    local found=""
    [ -x /usr/bin/lsappinfo ] || return 1
    found="$(/usr/bin/lsappinfo find "bundleid=${BUNDLE_ID}" 2>/dev/null || true)"
    case "${found}" in
        *ASN:*) return 0 ;;
        *) return 1 ;;
    esac
}

CANDIDATES=()
EXISTING=()

collect_candidates() {
    CANDIDATES=(
        # Application bundle
        "/Applications/${APP_NAME}"
        "${HOME}/Applications/${APP_NAME}"

        # Sandbox container — holds the app's whole Library when sandboxed: settings, tool
        # presets, templates, export profiles and recovery copies
        "${HOME}/Library/Containers/${BUNDLE_ID}"
        "${HOME}/Library/Group Containers/group.${BUNDLE_ID}"

        # XPC service containers — each embedded, sandboxed XPC service gets a container of its
        # own the first time it runs. Both were observed on a real installation.
        "${HOME}/Library/Containers/${BUNDLE_ID}.GeometryService"
        "${HOME}/Library/Containers/${BUNDLE_ID}.RepairService"

        # Preferences (per-host files carry the host UUID in their name; swept below)
        "${HOME}/Library/Preferences/${BUNDLE_ID}.plist"

        # Application support and caches (a non-sandboxed development build writes these)
        "${HOME}/Library/Application Support/${BUNDLE_ID}"
        "${HOME}/Library/Application Support/Zenit PDF"
        "${HOME}/Library/Caches/${BUNDLE_ID}"
        "${HOME}/Library/HTTPStorages/${BUNDLE_ID}"
        "${HOME}/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
        "${HOME}/Library/WebKit/${BUNDLE_ID}"

        # Window and document restoration
        "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"

        # Logs written by the app itself
        "${HOME}/Library/Logs/${BUNDLE_ID}"
        "${HOME}/Library/Logs/Zenit PDF"
    )
    if [ "${#EXTRA_APPS[@]}" -gt 0 ]; then
        CANDIDATES+=("${EXTRA_APPS[@]}")
    fi

    # Any XPC service container a future version adds, and the per-host preference files
    # (${BUNDLE_ID}.<host UUID>.plist). A non-matching glob stays literal in bash, which the -e
    # test rejects.
    local match candidate known path
    for match in "${HOME}/Library/Containers/${BUNDLE_ID}."* \
                 "${HOME}/Library/Preferences/ByHost/${BUNDLE_ID}."*.plist; do
        [ -e "${match}" ] || continue
        known="no"
        for candidate in "${CANDIDATES[@]}"; do
            if [ "${candidate}" = "${match}" ]; then
                known="yes"
                break
            fi
        done
        if [ "${known}" = "no" ]; then
            CANDIDATES+=("${match}")
        fi
    done

    for path in "${CANDIDATES[@]}"; do
        if [ -e "${path}" ] || [ -L "${path}" ]; then
            EXISTING+=("${path}")
        fi
    done
}

# Stops while Zenit PDF is open: any copy that is about to be removed, found by its path, or
# any running copy at all, found by its bundle identifier. Never quits it for you.
refuse_if_running() {
    local path pids=""
    for path in "${EXISTING[@]}"; do
        case "${path}" in
            *.app) pids="${pids}$(running_pids "${path}")" ;;
        esac
    done
    if [ -z "${pids}" ] && running_by_bundle_id; then
        pids="running"
    fi
    [ -n "${pids}" ] || return 0
    if [ "${DRY_RUN}" = "yes" ]; then
        say "Zenit PDF is open right now; a real run would ask you to quit it first."
        say ""
        return 0
    fi
    die "Zenit PDF is open. Save your work, quit it (Zenit PDF menu > Quit Zenit PDF), and run
       this again. Nothing was removed."
}

remove_all() {
    # The preference daemon caches defaults in memory and can rewrite a plist after it is
    # deleted, so the domain is dropped through `defaults` first.
    step "Clearing the preferences domain ${BUNDLE_ID}..."
    defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    defaults -currentHost delete "${BUNDLE_ID}" >/dev/null 2>&1 || true

    local path
    FAILED=()
    REMOVED=()
    for path in "${EXISTING[@]}"; do
        case "${path}" in
            *.app)
                # Forget the app in Launch Services before it disappears, so Finder's
                # "Open With" list does not keep a dead entry.
                if [ -x "${LSREGISTER}" ]; then
                    "${LSREGISTER}" -u "${path}" </dev/null >/dev/null 2>&1 || true
                fi
                ;;
        esac
        step "Removing ${path}"
        if rm -rf "${path}" 2>/dev/null; then
            REMOVED+=("${path}")
            case "${path}" in *.app) APP_REMOVED="yes" ;; esac
        else
            FAILED+=("${path}")
        fi
    done
}

report_failures() {
    local path
    say ""
    say "Could NOT be removed (${#FAILED[@]}):"
    for path in "${FAILED[@]}"; do
        say "  ${path}"
    done
    # Two different causes need two different remedies. A sandbox container is protected by
    # macOS itself: `rm` returns "Operation not permitted" and sudo does NOT help. An app bundle
    # owned by another user is an ordinary permission problem, where sudo is the answer.
    local container_failures=() other_failures=()
    for path in "${FAILED[@]}"; do
        case "${path}" in
            "${HOME}/Library/Containers/"*|"${HOME}/Library/Group Containers/"*)
                container_failures+=("${path}") ;;
            *)
                other_failures+=("${path}") ;;
        esac
    done

    if [ "${#container_failures[@]}" -gt 0 ]; then
        say ""
        say "Sandbox containers macOS would not let this script delete:"
        say ""
        for path in "${container_failures[@]}"; do
            say "  ${path}"
        done
        say ""
        say "macOS protects these folders, and \"Operation not permitted\" here is"
        say "that protection, not a file-ownership problem. sudo does NOT get past"
        say "it. Two things that do work:"
        say ""
        say "  1. Delete them in Finder. Press shift-command-G, paste the path"
        say "     above, press enter, then move the folder to the Trash."
        say "  2. Or give your terminal Full Disk Access in System Settings >"
        say "     Privacy & Security > Full Disk Access, quit and reopen the"
        say "     terminal, and run this script again."
    fi

    if [ "${#other_failures[@]}" -gt 0 ]; then
        say ""
        say "Paths that could not be removed for an ordinary permission reason:"
        say ""
        for path in "${other_failures[@]}"; do
            say "  ${path}"
        done
        say ""
        say "The usual cause is an app in /Applications installed by another user."
        say "Remove it by hand in Finder, or run this yourself:"
        say ""
        for path in "${other_failures[@]}"; do
            say "  sudo rm -rf \"${path}\""
        done
    fi

    say ""
    say "This script never runs sudo for you."
}

main() {
    parse_args "$@"

    if [ "$(id -u)" -eq 0 ]; then
        die "do not run this script as root or with sudo.
       It removes files in your own home folder and must run as you."
    fi
    [ "$(uname -s)" = "Darwin" ] || die "this script is for macOS."

    collect_candidates

    say ""
    say "Zenit PDF — uninstall"
    say ""

    if [ "${#EXISTING[@]}" -eq 0 ]; then
        say "Nothing found to remove. Zenit PDF does not appear to be installed"
        say "for this user."
        say ""
        say "Paths checked:"
        local path
        for path in "${CANDIDATES[@]}"; do
            say "  ${path}"
        done
        say ""
        say "If you installed it into another folder, pass that copy with --app PATH."
        say ""
        exit 0
    fi

    say "The following will be permanently deleted:"
    say ""
    for path in "${EXISTING[@]}"; do
        if [ -d "${path}" ]; then
            say "  [dir]  ${path}"
        else
            say "  [file] ${path}"
        fi
    done
    say ""
    say "This removes Zenit PDF's own settings, tool presets and caches. It does NOT"
    say "touch your own files: projects, PDF drawings and exports stay where you saved"
    say "them."
    say ""

    refuse_if_running

    if [ "${DRY_RUN}" = "yes" ]; then
        say "--dry-run was given. Nothing was removed."
        exit 0
    fi

    # Explicit typed confirmation, read from the keyboard. Without a terminal there is no way
    # to obtain informed consent, and the script refuses rather than assuming it.
    if ! tty_available; then
        die "cannot read a confirmation from the keyboard.
       Run this in a Terminal window:
         curl -fsSL https://github.com/${ZENIT_REPO}/releases/latest/download/uninstall.sh | bash"
    fi

    printf 'Type %s and press return to delete everything listed above: ' "${CONFIRM_WORD}"
    local answer=""
    IFS= read -r answer </dev/tty || true

    if [ "${answer}" != "${CONFIRM_WORD}" ]; then
        say ""
        say "Nothing was removed. (You did not type ${CONFIRM_WORD}.)"
        exit 1
    fi

    say ""
    remove_all

    say ""
    say "Done."
    say ""
    say "Removed (${#REMOVED[@]}):"
    if [ "${#REMOVED[@]}" -gt 0 ]; then
        for path in "${REMOVED[@]}"; do
            say "  ${path}"
        done
    fi

    if [ "${#FAILED[@]}" -gt 0 ]; then
        report_failures
        exit 1
    fi

    say ""
    if [ "${APP_REMOVED}" = "yes" ]; then
        say "Zenit PDF has been removed. Your own projects and PDF files are untouched."
    else
        say "Zenit PDF's own data has been removed, but no copy of the app was in the list. If the"
        say "app is in another folder, run this again with --app PATH to remove it. Your own"
        say "projects and PDF files are untouched."
    fi
    say ""
    exit 0
}

FAILED=()
REMOVED=()
APP_REMOVED="no"
main "$@"
