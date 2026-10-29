#!/bin/bash
#
# verify-author-scrub.sh — no real person's name in the repository's content.
#
# No real person's name appears in source, fixtures, mocks, defaults, or documentation; synthetic
# placeholders ("A. Berg", "Test Person") stand in wherever a name is needed. The author string
# shown in the app is always a runtime value (NSFullUserName / the Settings preference), never a
# literal.
#
# ## Where the names come from
#
# The name this gate looks for — the maintainer's personal name — is never written in the
# repository, not even split into parts, because a public script that spells a name out of
# fragments publishes it all the same. It is read at run time from:
#
#   ZENIT_SCRUB_NAMES   one or more names, separated by commas or newlines. In CI this is a
#                       repository secret of the same name; the maintainer sets it locally.
#   ZENIT_SCRUB_SELF=1  opt-in, and only when ZENIT_SCRUB_NAMES is unset: the full name of the
#                       local macOS account running the gate (`id -F`).
#
# Every word of three or more letters in those names is searched for as a case-insensitive
# substring. That is why the account name is opt-in: a contributor called Max or Mark matches
# "maximum" and "markup" all over the tree, so a gate that checked every account by default would
# fail for most people who run it.
#
# When no name is given the gate cannot know what to look for:
#
#   * on a local machine it prints SKIPPED, says how to enable it, and exits 0;
#   * in GitHub Actions (GITHUB_ACTIONS=true) it fails with `::error::` when ZENIT_SCRUB_REQUIRED
#     is `true` — the workflow sets that for pushes and same-repository pull requests on the
#     project's own repository, where the secret must exist — and otherwise (a fork, or a fork's
#     pull request, which receives no repository secrets) prints `::warning::` and exits 0.
#
# ## What it reads
#
# The publishable file set, binary files included (`grep -a`), so a name in a PNG text chunk or a
# compiled resource is caught as well. Inside a git work tree that is
# `git ls-files --cached --others --exclude-standard`: what is tracked, plus what would be added
# because nothing ignores it. Outside one (an exported tarball, say) it is every file under the
# project folders, `Packaging/` included, and the files at the top level, minus build products.
#
# A match anywhere fails the gate, inside an absolute path included: a home-folder path such as
# `/Users/<account>/...` can carry the maintainer's surname, and that is the most likely way for
# one to slip into a log or a comment. Offenders are reported as `file:line` only, so a CI log
# never prints the name it was asked to keep out.
#
# A gate that scans zero files must fail, and this one does.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Who holds the tree ---------------------------------------------------------------------
#
# Two builds sharing one working tree and one `.build` interfere with each other, and nothing
# else records that the other one is there. `wave-marker.sh check` prints a warning when another
# run's fresh marker is present, and **always exits 0**: a marker is a convention, never a lock,
# and a leftover one must not be able to redden or wedge a gate. Stale markers expire.
if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps Packages Docs
fi

cd "${ROOT}"

# --- The names, from the environment or, on request, the account -----------------------------
names="${ZENIT_SCRUB_NAMES:-}"
in_actions=0
[ "${GITHUB_ACTIONS:-}" = "true" ] && in_actions=1

if [ -z "${names}" ] && [ "${in_actions}" -eq 0 ] && [ "${ZENIT_SCRUB_SELF:-}" = "1" ]; then
    names="$(id -F 2>/dev/null || true)"
    if [ -z "${names}" ]; then
        echo "FAIL: ZENIT_SCRUB_SELF=1 is set, but this account has no full name; set ZENIT_SCRUB_NAMES."
        exit 1
    fi
fi

if [ -z "${names}" ]; then
    if [ "${in_actions}" -eq 1 ]; then
        if [ "${ZENIT_SCRUB_REQUIRED:-}" = "true" ]; then
            echo "::error title=Author scrub has no names::The ZENIT_SCRUB_NAMES repository secret is missing, so the author scrub would scan for nothing. Create the secret."
            exit 1
        fi
        echo "::warning title=Author scrub skipped::No ZENIT_SCRUB_NAMES secret in this context (a fork, or a fork's pull request, receives no repository secrets)."
        exit 0
    fi
    echo "SKIPPED: no names to look for. Set ZENIT_SCRUB_NAMES=\"First Last\" (comma- or newline-separated),"
    echo "         or ZENIT_SCRUB_SELF=1 to check this account's full name."
    exit 0
fi

# Words of three or more letters, lowercased, de-duplicated; initials and particles are dropped.
words="$(printf '%s\n' "${names}" | tr ',' '\n' | tr -s '[:space:]' '\n' \
    | tr '[:upper:]' '[:lower:]' | awk 'length($0) >= 3' | sort -u)"
if [ -z "${words}" ]; then
    echo "FAIL: the names given contain no word of three or more letters to look for."
    exit 1
fi

# --- The publishable file set ---------------------------------------------------------------
readonly FALLBACK_DIRS=(Apps Packages Bridges Docs Fixtures Packaging Resources Scripts Tests Tools .github)

FILE_LIST="$(mktemp -t zenit-author-scrub)"
readonly FILE_LIST
trap 'rm -f "${FILE_LIST}"' EXIT

if git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    source_of_list="git ls-files --cached --others --exclude-standard"
    git -C "${ROOT}" ls-files -z --cached --others --exclude-standard >"${FILE_LIST}" 2>/dev/null || {
        echo "FAIL: git ls-files could not list the publishable files."
        exit 1
    }
else
    source_of_list="the project folders and the top-level files"
    existing_dirs=()
    for dir in "${FALLBACK_DIRS[@]}"; do
        [ -d "${dir}" ] && existing_dirs+=("${dir}")
    done
    # Build products (including the private `--scratch-path .build-<name>` directories parallel
    # builds use), Xcode's per-user state, vendored checkouts and Finder metadata are not
    # published, so they are not read.
    {
        if [ "${#existing_dirs[@]}" -gt 0 ]; then
            find "${existing_dirs[@]}" -type f \
                -not -path '*/.build/*' \
                -not -path '*/.build-*/*' \
                -not -path '*/.swiftpm/*' \
                -not -path '*/xcuserdata/*' \
                -not -path '*/.git/*' \
                -not -path '*/checkouts/*' \
                -not -name '.DS_Store' \
                -print0 2>/dev/null
        fi
        find . -maxdepth 1 -type f -not -name '.DS_Store' -print0 2>/dev/null
    } >"${FILE_LIST}"
fi

file_count="$(tr -cd '\0' <"${FILE_LIST}" | wc -c | tr -d ' ')"
if [ "${file_count}" -eq 0 ]; then
    echo "FAIL: the gate scanned zero files."
    exit 1
fi

grep_args=()
while IFS= read -r word; do
    [ -n "${word}" ] && grep_args+=(-e "${word}")
done <<< "${words}"

# A file whose path carries a name leaks it as surely as its content does. Only a count is
# printed, because the matching paths would print the name.
path_hits="$(tr '\0' '\n' <"${FILE_LIST}" | grep -ciF "${grep_args[@]}" || true)"
if [ "${path_hits:-0}" -gt 0 ]; then
    echo "FAIL: ${path_hits} file path(s) in the repository contain a name the gate was given (not printed)."
    exit 1
fi

# One grep over the whole list. `-a` reads binary files as text; `-o` prints only the matched
# word rather than the whole line, which keeps a binary "line" from flooding the pipe, and `cut`
# then drops that word so only `file:line` is ever printed.
offenders="$(xargs -0 grep -HnoaiF "${grep_args[@]}" <"${FILE_LIST}" 2>/dev/null \
    | cut -d: -f1,2 | sort -u)"

if [ -n "${offenders}" ]; then
    echo "FAIL: a name the gate was given appears in the repository at:"
    printf '%s\n' "${offenders}"
    exit 1
fi

echo "PASS: scanned ${file_count} files (${source_of_list}); none of the given names appears in a path or in content."
exit 0
