#!/bin/bash
#
# verify-no-competitor-names.sh — no competing product is named anywhere in the product.
#
# ## Why this is a gate
#
# Project policy: Zenit PDF does not name competing products — not in the interface, the shipped
# documents, a code comment, a string literal or a frozen contract. Behaviour is described on its
# own terms, never by reference to another product that also has it.
#
# Naming a competitor in shipping software is not merely off-brand. Trade-mark law permits
# nominative use — naming another product truthfully in order to identify what yours does — but
# the permission is narrow, it does not extend to comparative marketing, and the line between
# the two is argued after the fact by somebody else. A product that never says the name is never
# on the wrong side of it.
#
# A checklist cannot hold this. The failure mode is a code comment written in a hurry, months
# from now, that reads perfectly well to its author. Four such mentions existed when this gate
# was written — three comments and one string literal frozen into a contract, which means it was
# also inside the shipping binary. So this is a gate, it fails the build, and it runs in
# `Scripts/build-app.sh`.
#
# ## What it checks
#
#   1. **Our own source carries no mention** — every file under `Apps/*/Sources`,
#      `Packages/*/Sources`, `Bridges/*/Sources`, their tests, `Tools/`, the bundles' own
#      resources and the shipped `Resources`, comments included, whatever its extension (V-093):
#      only images and Finder metadata are left out. Comments are in scope because the
#      repository is public: source is part of the product.
#   2. **The frozen contracts carry no mention** — `Docs/Contracts/*.json` is generated from
#      Swift string literals that end up in the binary.
#   3. **The assembled bundle carries no mention** — every file under `Zenit PDF.app`, scanned
#      as binary, so a name compiled into `__cstring` is caught even if the source that produced
#      it has been reworded since. Usage: `verify-no-competitor-names.sh [bundle]`; with a
#      bundle path that one is scanned and must exist (T-082), without one `build/` and `dist/`.
#   4. **The scripts carry no mention** — everything under `Scripts/`, this gate included: its
#      own pattern is stored encoded (S-129).
#   4b. **The public documents carry no mention** — the repository's top-level `*.md` and
#      `LICENSE`, and everything under `.github/` (V-093): the README, the security policy, the
#      contributing guide and the issue and pull-request templates are the first text of the
#      project anyone reads.
#   4c. **The package manifests and documents carry no mention** — every other file under
#      `Apps/`, `Packages/`, `Tools/` and `Bridges/` that pass 1 does not read (W-099): each
#      `Package.swift` (Swift with prose comments), the package READMEs, `VENDORED.md`,
#      `NOTICE-qpdf.md`, `FIXTURES.md`, the licence texts, `Package.resolved`, the shipped
#      `Localization/` string tables and `.swiftpm/` (scanned although .gitignore keeps it out of
#      the repository). All of it, `.swiftpm/` apart, is published with the repository.
#   4d. **The documentation and packaging carry no mention** — every file under `Docs/` that
#      pass 2 does not read (the decision records, design and format documents, the install
#      guide, the known limitations, the legal and licence documents) and everything under
#      `Packaging/` (the Homebrew cask and its README). All of it is published.
#   5. **The scan examined something.** A gate whose file list came back empty passes vacuously,
#      which is the exact shape of failure it exists to prevent, so each pass asserts a floor on
#      the number of files it actually read.
#
# Out of scope, deliberately: `ExternalResearch/` (upstream clones, not our text).

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps Packages
fi

# The names, matched case-insensitively. Stored base64-encoded (S-129): the repository is public,
# so a comment or a literal in this file is as published as one in the source, and the gate used
# to spell both names here, where no pass could see them. The short brand word is bounded so the
# ordinary words that share its letters do not match; the full product name needs no boundary.
# To read or change the pattern locally:  printf '%s' "$PATTERN_BASE64" | base64 --decode
readonly PATTERN_BASE64='Ymx1ZWJlYW18KF58W15BLVphLXpdKXJldnUoW15BLVphLXpdfCQp'
PATTERN="$(printf '%s' "${PATTERN_BASE64}" | base64 --decode)"
readonly PATTERN
if [ -z "${PATTERN}" ]; then
    printf 'FAILED: the name pattern did not decode; the gate cannot run\n'
    exit 1
fi

# Floors. Set below the real counts with room to move, high enough that an empty or badly
# rooted scan cannot pass. Raise them if a pass legitimately shrinks; never lower them to make
# a red gate green.
readonly MINIMUM_SOURCE_FILES=2000
readonly MINIMUM_PUBLIC_DOCUMENT_FILES=8
readonly MINIMUM_CONTRACT_FILES=5
readonly MINIMUM_BUNDLE_FILES=10
readonly MINIMUM_SCRIPT_FILES=30
readonly MINIMUM_PACKAGE_DOCUMENT_FILES=50
readonly MINIMUM_DOCUMENTATION_FILES=50

failures=0

fail() {
    printf 'FAILED: %s\n' "$1"
    failures=$(( failures + 1 ))
}

# --- 1 and 2: our source, and the frozen contracts ----------------------------------------
#
# `find -print0` into `while read -d ''`, never `xargs`: this repository lives under a path
# containing spaces, and `xargs` splits on them silently, which yields an empty file list and a
# gate that passes having read nothing.
scan_tree() {
    local label="$1" floor="$2"; shift 2
    local scanned=0 hits=0 file

    while IFS= read -r -d '' file; do
        scanned=$(( scanned + 1 ))
        if LC_ALL=C grep -ainE "${PATTERN}" "${file}" >/dev/null 2>&1; then
            hits=$(( hits + 1 ))
            printf '  %s\n' "${file#"${ROOT}/"}"
            # Text files show the offending line; a matched binary shows a count and the
            # matched word only. A compiled binary has no lines, so printing the "line" dumps
            # the whole __cstring section over the terminal, which buries the finding it is
            # meant to report.
            if LC_ALL=C grep -qI . "${file}" 2>/dev/null; then
                LC_ALL=C grep -ainE "${PATTERN}" "${file}" | head -5 | sed 's/^/      /'
            else
                printf '      binary: %s occurrence(s) of %s\n' \
                    "$(LC_ALL=C grep -aoiE "${PATTERN}" "${file}" | wc -l | tr -d ' ')" \
                    "$(LC_ALL=C grep -aoiE "${PATTERN}" "${file}" | sort -u | tr -d ' ' | tr '\n' ' ')"
            fi
        fi
    done < <("$@" -print0)

    printf -- '--- %s: %d files scanned, %d with a mention ---\n' "${label}" "${scanned}" "${hits}"

    if [ "${scanned}" -lt "${floor}" ]; then
        fail "${label}: only ${scanned} files scanned, below the floor of ${floor}; the scan did not reach the tree"
    fi
    [ "${hits}" -eq 0 ] || fail "${label}: ${hits} file(s) name a competing product"
}

# Tests included since 2026-08-27: a review found a mention living in a test comment that had
# survived precisely because this list stopped at Sources. Tests are published with the
# repository; they are source.
#
# Tools/ and the app bundles' own resources since R-203: the `zenit` CLI is built into the
# bundle (build-app.sh), and Apps/*/Bundle holds the scripting dictionary (.sdef), the
# Info.plist template (.in), the licence texts and the localized strings the user reads.
source_dirs=()
for dir in "${ROOT}"/Apps/*/Sources "${ROOT}"/Packages/*/Sources "${ROOT}"/Bridges/*/Sources \
           "${ROOT}"/Apps/*/Tests "${ROOT}"/Packages/*/Tests "${ROOT}"/Bridges/*/Tests \
           "${ROOT}"/Tools/*/Sources "${ROOT}"/Tools/*/Tests "${ROOT}"/Apps/*/Bundle \
           "${ROOT}/Tests" "${ROOT}/Resources"; do
    [ -d "${dir}" ] && source_dirs+=("${dir}")
done
[ "${#source_dirs[@]}" -gt 0 ] || fail "source scan: no source directory found at all"

# Every file, not a list of extensions (V-093). The list stopped at a dozen and missed the
# project-authored C++ shim (`.cc`), the vendored headers (`.hh`), the four `.entitlements` in
# the bundles and the one `.svg`; the next new extension would have been missed the same way.
# Only images and Finder metadata are left out — compressed pixels are not text anybody wrote,
# and scanning them only invites a chance byte match; the bundle pass still reads every image
# as it ships.
if [ "${#source_dirs[@]}" -gt 0 ]; then
    scan_tree "product source" "${MINIMUM_SOURCE_FILES}" \
        find "${source_dirs[@]}" -type f \
            -not -name '*.png' -not -name '*.icns' -not -name '*.jpg' -not -name '*.jpeg' \
            -not -name '*.gif' -not -name '*.tif' -not -name '*.tiff' -not -name '*.heic' \
            -not -name '.DS_Store' \
            -not -path '*/.build/*' -not -path '*/.build-*/*'
fi

scan_tree "frozen contracts" "${MINIMUM_CONTRACT_FILES}" \
    find "${ROOT}/Docs/Contracts" -type f -name '*.json'

# Scripts/ since S-129: the gates and build scripts are published with the repository, and this
# gate carried the names itself, in a comment and a literal, while no pass read Scripts/.
scan_tree "scripts" "${MINIMUM_SCRIPT_FILES}" \
    find "${ROOT}/Scripts" -type f -not -path '*/.build/*' -not -path '*/.build-*/*'

# The public documents since V-093: the top-level Markdown and licence, and `.github/`. The
# pull-request template named the benchmark product in its checklist while no pass read it.
# Two finds behind one command, because `scan_tree` appends `-print0` to the command it runs.
public_documents() {
    [ -d "${ROOT}/.github" ] && find "${ROOT}/.github" -type f "$@"
    find "${ROOT}" -maxdepth 1 -type f \( -name '*.md' -o -name 'LICENSE*' \) "$@"
}
scan_tree "public documents" "${MINIMUM_PUBLIC_DOCUMENT_FILES}" public_documents

# The package manifests and documents since W-099. Pass 1 reads the Sources, Tests and Bundle
# directories; everything else under the four product roots went unread — 39 `Package.swift`
# manifests, a dozen READMEs, the vendoring and notice documents, the fixture catalogue, the
# shipped `Localization/` string tables — although all of it is published. The complement of
# pass 1, not a list of names, so the next document added beside a package is read too: the
# directories pass 1 already covers are pruned, and so are build products.
package_documents() {
    local prune=( -name .build -o -name '.build-*' ) dir
    for dir in "${source_dirs[@]}"; do
        prune+=( -o -path "${dir}" )
    done
    find "${ROOT}/Apps" "${ROOT}/Packages" "${ROOT}/Tools" "${ROOT}/Bridges" \
        \( "${prune[@]}" \) -prune -o -type f \
        -not -name '*.png' -not -name '*.icns' -not -name '*.jpg' -not -name '*.jpeg' \
        -not -name '*.gif' -not -name '*.tif' -not -name '*.tiff' -not -name '*.heic' \
        -not -name '.DS_Store' "$@"
}
scan_tree "package manifests and documents" "${MINIMUM_PACKAGE_DOCUMENT_FILES}" package_documents

# The documentation and packaging (4d). `Docs/` and `Packaging/` are published with the
# repository like everything above, and they hold the text a person reads before installing: the
# install guide, the known limitations, the decision records and the Homebrew cask. The JSON
# contracts pass 2 already reads are left out here rather than counted twice.
documentation_and_packaging() {
    local roots=() dir
    for dir in "${ROOT}/Docs" "${ROOT}/Packaging"; do
        [ -d "${dir}" ] && roots+=("${dir}")
    done
    [ "${#roots[@]}" -gt 0 ] || return 0
    find "${roots[@]}" -type f \
        -not \( -path "${ROOT}/Docs/Contracts/*" -name '*.json' \) \
        -not -name '*.png' -not -name '*.icns' -not -name '*.jpg' -not -name '*.jpeg' \
        -not -name '*.gif' -not -name '*.tif' -not -name '*.tiff' -not -name '*.heic' \
        -not -name '.DS_Store' "$@"
}
scan_tree "documentation and packaging" "${MINIMUM_DOCUMENTATION_FILES}" documentation_and_packaging

# --- 3: the assembled bundle ---------------------------------------------------------------
#
# The bundle is the copy a user receives. Scanned as binary (`grep -a`) so a name in a
# `__cstring` section is found even when no source file still holds it.
#
# T-082: the bundle to scan is the first argument when one is given — `build-app.sh` passes the
# bundle it just assembled, wherever `--output` put it, so a release bundle (CI builds into
# `build/`, a local build may use any `--output`) is the one scanned rather than a
# stale `build/` bundle or none. A bundle that was named and is not there is a failure: the pass
# that was asked for did not run. With no argument the two default locations are looked in, as
# before, and a missing bundle is only a note.
bundle=""
if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    if [ -d "$1" ]; then
        bundle="$(cd "$1" && pwd -P)"
    else
        fail "assembled bundle: ${1} was named and is not there, so the bundle pass could not run"
    fi
else
    for candidate in "${ROOT}/build/Zenit PDF.app" "${ROOT}/dist/Zenit PDF.app"; do
        [ -d "${candidate}" ] && bundle="${candidate}" && break
    done
    if [ -z "${bundle}" ]; then
        printf -- '--- assembled bundle: not present; run Scripts/build-app.sh first ---\n'
        printf 'NOTE: the source and contract passes above ran. The bundle pass did not.\n'
    fi
fi

if [ -n "${bundle}" ]; then
    scan_tree "assembled bundle" "${MINIMUM_BUNDLE_FILES}" \
        find "${bundle}" -type f
fi

printf '\n=======================================================================\n'
if [ "${failures}" -eq 0 ]; then
    printf 'No competing product is named in the product source, the frozen contracts,\n'
    printf 'the scripts, the public documents, the package manifests and documents, the\n'
    printf 'documentation and packaging, or the assembled bundle.\n'
    printf '=======================================================================\n'
    exit 0
fi
printf '%d check(s) failed. A competing product must never be named in the program.\n' "${failures}"
printf 'Reword to describe the behaviour, not the product that also has it.\n'
printf '=======================================================================\n'
exit 1
