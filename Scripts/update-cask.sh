#!/usr/bin/env bash
#
# update-cask.sh — set `version` and `sha256` in the Homebrew cask for a published release.
#
#   Scripts/update-cask.sh VERSION [--sums FILE] [--cask FILE]
#
#   VERSION       the release, X.Y.Z (a leading v is accepted). Pre-releases are refused: a cask
#                 offers what `brew upgrade` installs, which is the newest stable release.
#   --sums FILE   read the checksum list from FILE (for example dist/SHA256SUMS.txt) instead of
#                 downloading it from https://github.com/<repo>/releases/download/vVERSION/
#   --cask FILE   the cask to rewrite. Default: Packaging/homebrew/zenit-pdf.rb. Point it at a
#                 checkout of the tap (…/homebrew-tap/Casks/zenit-pdf.rb) to update the tap.
#
# The sha256 is the one SHA256SUMS.txt lists for ZenitPDF-<version>-universal.dmg, the file the
# cask's url names. Only the cask file is written; nothing is committed or pushed. See
# Packaging/homebrew/README.md for publishing the tap.
#
# Requires: bash, awk, curl (only without --sums); ruby is used for a syntax check when present.

set -euo pipefail

ZENIT_REPO="${ZENIT_REPO:-ZGColombia/ZenitPDF}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf 'update-cask.sh: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

VERSION=""
SUMS=""
CASK="${ROOT}/Packaging/homebrew/zenit-pdf.rb"

while [ $# -gt 0 ]; do
    case "$1" in
        --sums) [ $# -ge 2 ] || die "--sums needs a file"; SUMS="$2"; shift 2 ;;
        --cask) [ $# -ge 2 ] || die "--cask needs a file"; CASK="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [ -z "${VERSION}" ] || die "one version only"; VERSION="${1#v}"; shift ;;
    esac
done

[ -n "${VERSION}" ] || { usage; exit 2; }
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"${VERSION}" \
    || die "'${VERSION}' is not a stable version like 1.2.0 (pre-releases do not go into the cask)"
[ -f "${CASK}" ] || die "no cask at ${CASK}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if [ -z "${SUMS}" ]; then
    URL="https://github.com/${ZENIT_REPO}/releases/download/v${VERSION}/SHA256SUMS.txt"
    SUMS="${WORK}/SHA256SUMS.txt"
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --silent --show-error \
        -o "${SUMS}" "${URL}" || die "could not download ${URL} (is v${VERSION} published?)"
fi
[ -f "${SUMS}" ] || die "no checksum list at ${SUMS}"

ASSET="ZenitPDF-${VERSION}-universal.dmg"
SHA="$(awk -v want="${ASSET}" '{ name = $2; sub(/^\*/, "", name); if (name == want) { print tolower($1); exit } }' "${SUMS}")"
grep -Eq '^[0-9a-f]{64}$' <<<"${SHA}" || die "${SUMS} has no valid line for ${ASSET}"

[ "$(grep -c '^  version "' "${CASK}")" = "1" ] || die "${CASK} must have exactly one '  version \"…\"' line"
[ "$(grep -c '^  sha256 "' "${CASK}")" = "1" ] || die "${CASK} must have exactly one '  sha256 \"…\"' line"

awk -v version="${VERSION}" -v sha="${SHA}" '
    /^  version "/ { print "  version \"" version "\""; next }
    /^  sha256 "/  { print "  sha256 \"" sha "\""; next }
    { print }' "${CASK}" > "${WORK}/cask.rb"

if command -v ruby >/dev/null 2>&1; then
    ruby -c "${WORK}/cask.rb" >/dev/null || die "the rewritten cask is not valid Ruby; ${CASK} was left as it was"
fi
cat "${WORK}/cask.rb" > "${CASK}"

printf 'Updated %s\n' "${CASK}"
grep -E '^  (version|sha256) "' "${CASK}" | sed 's/^/  /'
printf 'Download it names: https://github.com/%s/releases/download/v%s/%s\n' "${ZENIT_REPO}" "${VERSION}" "${ASSET}"
