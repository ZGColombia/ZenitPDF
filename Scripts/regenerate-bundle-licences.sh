#!/bin/bash
#
# regenerate-bundle-licences.sh — rebuild `Apps/ZenitPDF/Bundle/Licenses/` from the pinned
# upstream clones, and rewrite the machine-readable manifest the shipping gate reads.
#
# ## Why the notice texts are committed rather than generated at build time
#
# `.gitignore` excludes `ExternalResearch/`, so no clone of this repository has the upstream
# licence files. If the bundle's notices were produced from those clones during `build-app.sh`,
# every build outside a maintainer's machine would either fail or ship a bundle with no notices —
# and Apache-2.0 §4(d) does not have an "unless it was inconvenient" clause. The texts are
# therefore **committed**, verbatim, and this script is how they are refreshed when a dependency
# is bumped. It runs on a maintainer's machine that holds the upstream clones, by design.
#
# What the shipping gate (`Scripts/verify-licence-notices.sh`) checks is the committed output and
# the assembled bundle. It never needs the clones, so it runs everywhere.
#
# ## Provenance
#
# Every generated file carries a header naming the component, its pinned revision, the upstream
# path the text came from and that file's SHA-256 — the same digests recorded in
# `Docs/Licences/LICENSE_EVIDENCE.md` and `Docs/Execution/RESEARCH_REPOSITORIES.lock.json`. The
# licence text itself is copied byte for byte below the header. A notice that has been reflowed,
# truncated or "tidied" is not the notice.
#
# ## Licence headers in compiled sources
#
# A few compiled upstream sources carry a licence of their own in their header comment, and no
# upstream licence file reproduces it. qpdf's `libqpdf/MD5_native.cc` is derived from the RSA
# Data Security, Inc. MD5 Message-Digest Algorithm, and its RSA notice must be retained in every
# copy; qpdf's `NOTICE.md` does not mention it. GRDB's `GRDB/Utils/Inflections+English.swift`
# ports the Ruby on Rails Active Support inflection rules and carries the Rails MIT notice, and
# `GRDB/Core/Cursor.swift`, `GRDB/Record/EncodableRecord.swift` and
# `GRDB/Record/FetchableRecord.swift` carry Swift.org notices (Apache License v2.0 with Runtime
# Library Exception; in the two Record files the notice is an indented comment inside a function
# copied from swift-corelibs-foundation). GRDB's LICENSE reproduces none of them.
# `EMBEDDED_HEADERS` below lists each such file. Its licence comment is copied byte for byte
# after the component's licence files, and its SHA-256 is listed in the component's header with
# the others.
#
# ## Zenit PDF's own text
#
# Some notices open with a section headed "notes by Zenit PDF (not upstream text)": what Zenit
# PDF vendors, what it changed and what it excludes (`preface` below). Everything outside such a
# section is upstream text, byte for byte. Because Apache-2.0 §4(a) asks for a copy of the
# licence with the work, the GRDB notice also ends with the full Apache License 2.0 text for its
# Swift.org-derived code (`APPENDED_LICENCES` below), copied from the qpdf clone's unmodified
# `LICENSE.txt`, whose digest is checked against the canonical Apache-2.0 text first.
#
# Usage: Scripts/regenerate-bundle-licences.sh

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CLONES="${ROOT}/ExternalResearch"
readonly OUT="${ROOT}/Apps/ZenitPDF/Bundle/Licenses"
readonly MANIFEST="${ROOT}/Docs/Licences/SHIPPED_NOTICES.tsv"

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF/Bundle Docs/Licences
fi

fail() { printf 'FAILED: %s\n' "$1" >&2; exit 1; }

[ -d "${CLONES}" ] || fail "no ExternalResearch/ here. This script needs the upstream clones under ExternalResearch/; the generated notices are committed for everybody else."

mkdir -p "${OUT}" || fail "mkdir ${OUT}"

# component | clone dir | one or more upstream licence files, in the order they are emitted
COMPONENTS=(
    "GRDB.swift|grdb|LICENSE"
    "qpdf|qpdf|LICENSE.txt NOTICE.md"
    "Clipper2|clipper2|LICENSE"
    "libxlsxwriter|libxlsxwriter|License.txt"
)

# Compiled upstream sources whose header comment carries a licence that no upstream licence file
# reproduces (see "Licence headers in compiled sources" above). The emitted text is the
# contiguous (possibly indented) `//` comment block of the file that contains the marker, byte
# for byte.
# component | file in the clone | marker in its header | short title | what the file is
EMBEDDED_HEADERS=(
    "qpdf|libqpdf/MD5_native.cc|RSA Data Security, Inc.|RSA Data Security MD5|derived from the RSA Data Security, Inc. MD5 Message-Digest Algorithm"
    "GRDB.swift|GRDB/Utils/Inflections+English.swift|David Heinemeier Hansson|Ruby on Rails Active Support inflections (MIT)|whose English inflection rules are ported from Ruby on Rails Active Support"
    "GRDB.swift|GRDB/Core/Cursor.swift|Swift.org open source project|Swift.org (Apache-2.0 with Runtime Library Exception)|parts of which are derived from the Swift.org open source project"
    "GRDB.swift|GRDB/Record/EncodableRecord.swift|Apple Inc. and the Swift project authors|swift-corelibs-foundation (Apache-2.0 with Runtime Library Exception)|whose _convertToSnakeCase function is copied from swift-corelibs-foundation"
    "GRDB.swift|GRDB/Record/FetchableRecord.swift|Apple Inc. and the Swift project authors|swift-corelibs-foundation (Apache-2.0 with Runtime Library Exception)|whose _convertFromSnakeCase function is copied from swift-corelibs-foundation"
)

# Full licence texts appended to a component's notice from another clone, because code under
# that licence is compiled in and the component ships no copy of it.
# component | clone dir | file in that clone | required SHA-256 | section title
readonly APACHE_2_0_SHA256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
APPENDED_LICENCES=(
    "GRDB.swift|qpdf|LICENSE.txt|${APACHE_2_0_SHA256}|Apache License 2.0, for the Swift.org-derived code above"
)

# preface <component> — Zenit PDF's own notes for a component, or nothing.
preface() {
    case "$1" in
    "GRDB.swift") cat <<'EOF'
GRDB.swift is resolved by Swift Package Manager at the revision above, a
development snapshot 2 commits after the v7.11.1 tag, and compiled into Zenit
PDF unmodified. Besides GRDB's own licence, four compiled GRDB files carry
licence notices of their own, reproduced below: the Ruby on Rails Active
Support MIT notice in GRDB/Utils/Inflections+English.swift, and Swift.org
notices (Apache License v2.0 with Runtime Library Exception, Apple Inc. and
the Swift project authors) in GRDB/Core/Cursor.swift,
GRDB/Record/EncodableRecord.swift and GRDB/Record/FetchableRecord.swift.
The full Apache License 2.0 text is reproduced at the end of this notice. The
Swift project's licence adds the Runtime Library Exception, published with
that licence at https://swift.org/LICENSE.txt.
EOF
        ;;
    "qpdf") cat <<'EOF'
Zenit PDF vendors a subset of qpdf: 210 files from the revision above, which
declares version 12.4.1 in include/qpdf/DLL.h and is a development snapshot 26
commits after the v12.4.0 tag, plus one header written for Zenit PDF
(libqpdf/qpdf/qpdf-config.h, below). The file list and digests are recorded in
Bridges/QPDFBridge/VENDORED.md in the Zenit PDF source repository.

Changes made by Zenit PDF:
- libqpdf/QPDF_Stream.cc is modified: the DCTDecode (JPEG) filter include and
  its /DCTDecode and /DCT registrations are compiled out with
  ZPDF_QPDF_NO_DCT, because this build links no libjpeg (see VENDORED.md
  section 3). Pl_DCT.cc is not included, so this build does not decode DCT
  (JPEG) streams.
- libqpdf/qpdf/qpdf-config.h is written for Zenit PDF in place of the header
  that qpdf's CMake build generates.
All other vendored files are unmodified. The build uses qpdf's native crypto
provider and links no libjpeg, GnuTLS or OpenSSL; the command-line job layer
is not included.

The compiled sphlib SHA-2 files (libqpdf/sha2.c, libqpdf/sha2big.c,
sphinclude/sph/sph_sha2.h, sph_types.h and md_helper.c) state
"Copyright (c) 2007-2010  Projet RNRT SAPHIR" in their own headers; qpdf's
NOTICE.md below reproduces the same MIT licence with the years 2007-2011.
EOF
        ;;
    "Clipper2") cat <<'EOF'
The upstream LICENSE below names no copyright holder. The vendored Clipper2
source headers state "Copyright :  Angus Johnson" with year ranges from
2010-2023 to 2010-2026 (2010-2026 in clipper.engine.cpp and
clipper.triangulation.cpp). Zenit PDF vendors twelve files of Clipper2's C++
library unmodified from the revision above, which declares version 2.0.1 in
clipper.version.h and is a development snapshot 16 commits after the
Clipper2_2.0.1 tag.
EOF
        ;;
    "libxlsxwriter") cat <<'EOF'
What this build contains: Zenit PDF compiles libxlsxwriter with
USE_STANDARD_TMPFILE and USE_NO_MD5 and without USE_DTOA_LIBRARY, so
tmpfileplus (MPL-2.0), the md5 code and emyg_dtoa, which the upstream licence
page below names, are not vendored, compiled or linked into this
application. Compiled in are:
- libxlsxwriter itself; one file, src/utility.c, is modified by Zenit PDF so
  that it builds without the tmpfileplus header;
- the writer half of minizip (zlib licence; Copyright (C) 1998-2010 Gilles
  Vollant, Zip64 support Copyright (C) 2009-2010 Mathias Svensson). Its
  ioapi.h, zip.h and zip.c are altered source versions, not the original
  MiniZip software, and are marked as such at the top of each file; ioapi.c
  is unaltered. The alterations are recorded in
  Bridges/LibXlsxWriterBridge/VENDORED.md in the Zenit PDF source repository;
- the FreeBSD queue.h (Copyright (c) 1991, 1993 The Regents of the University
  of California) and tree.h (Copyright 2002 Niels Provos) macro headers.
zlib itself is the macOS system library. The upstream licence page is
reproduced whole because it is upstream's licence file.
EOF
        ;;
    esac
}

# header_comment <file> <marker> — prints the contiguous (possibly indented) `//` comment block
# containing the marker, unchanged, and fails when no block contains it.
header_comment() {
    awk -v marker="$2" '
        /^[ \t]*\/\// { block = block $0 "\n"; if (index($0, marker)) hit = 1; next }
        hit     { printf "%s", block; found = 1; exit }
                { block = ""; hit = 0 }
        END     { if (hit && !found) { printf "%s", block; found = 1 }; exit (found ? 0 : 1) }
    ' "$1"
}

emit() {
    local component="$1" clone="$2" files="$3"
    local dir="${CLONES}/${clone}"
    [ -d "${dir}" ] || fail "no clone at ${dir}"
    local revision
    revision="$(git -C "${dir}" rev-parse --short=8 HEAD 2>/dev/null)" \
        || fail "no git metadata in ${dir}"
    local target="${OUT}/${component}.txt"

    # This component's embedded licence headers, read before anything is written so a missing
    # file or marker fails the run instead of leaving a partial notice behind.
    local embedded=() row owner path marker title identity
    for row in "${EMBEDDED_HEADERS[@]}"; do
        IFS='|' read -r owner path marker title identity <<< "${row}"
        [ "${owner}" = "${component}" ] || continue
        [ -f "${dir}/${path}" ] || fail "${component}: no ${path} in ${dir}"
        header_comment "${dir}/${path}" "${marker}" > /dev/null \
            || fail "${component}: no header comment in ${path} contains \"${marker}\""
        embedded+=("${row}")
    done
    local appended=() aclone afile asha atitle
    for row in ${APPENDED_LICENCES[@]+"${APPENDED_LICENCES[@]}"}; do
        IFS='|' read -r owner aclone afile asha atitle <<< "${row}"
        [ "${owner}" = "${component}" ] || continue
        [ -f "${CLONES}/${aclone}/${afile}" ] || fail "${component}: no ${aclone}/${afile}"
        [ "$(shasum -a 256 "${CLONES}/${aclone}/${afile}" | cut -d' ' -f1)" = "${asha}" ] \
            || fail "${component}: ${aclone}/${afile} is not the expected licence text (sha256 ${asha})"
        appended+=("${row}")
    done
    local notes
    notes="$(preface "${component}")"

    {
        printf '%s\n' "================================================================================"
        printf '%s\n' "${component}"
        printf '%s\n' "================================================================================"
        printf 'Pinned revision: %s\n' "${revision}"
        printf 'This notice ships inside Zenit PDF.app/Contents/Resources/Licenses and is shown\n'
        printf "in the About window's Acknowledgements section (Help ▸ Licences). This header,\n"
        printf 'the section headings, the short lead-in before each embedded licence comment\n'
        printf 'and the sections headed "notes by Zenit PDF" are Zenit PDF'"'"'s own text.\n'
        printf 'Everything else is reproduced verbatim from the upstream files listed below;\n'
        printf 'each SHA-256 is reproducible with `shasum -a 256 <file>` against the clone at\n'
        printf 'the revision above, or at the revision named on the line.\n'
        local file
        for file in ${files}; do
            [ -f "${dir}/${file}" ] || fail "${component}: no ${file} in ${dir}"
            printf '  %s  sha256 %s\n' "${file}" "$(shasum -a 256 "${dir}/${file}" | cut -d' ' -f1)"
        done
        for row in ${embedded[@]+"${embedded[@]}"}; do
            IFS='|' read -r owner path marker title identity <<< "${row}"
            printf '  %s  sha256 %s  (licence comment only)\n' "${path}" \
                "$(shasum -a 256 "${dir}/${path}" | cut -d' ' -f1)"
        done
        for row in ${appended[@]+"${appended[@]}"}; do
            IFS='|' read -r owner aclone afile asha atitle <<< "${row}"
            printf '  %s  sha256 %s  (from the %s clone at %s)\n' "${afile}" "${asha}" \
                "${aclone}" "$(git -C "${CLONES}/${aclone}" rev-parse --short=8 HEAD)"
        done
        if [ -n "${notes}" ]; then
            printf '\n--------------------------------------------------------------------------------\n'
            printf '%s — notes by Zenit PDF (not upstream text)\n' "${component}"
            printf -- '--------------------------------------------------------------------------------\n\n'
            printf '%s\n' "${notes}"
        fi
        for file in ${files}; do
            printf '\n--------------------------------------------------------------------------------\n'
            printf '%s — %s\n' "${component}" "${file}"
            printf -- '--------------------------------------------------------------------------------\n\n'
            cat "${dir}/${file}"
        done
        for row in ${embedded[@]+"${embedded[@]}"}; do
            IFS='|' read -r owner path marker title identity <<< "${row}"
            printf '\n--------------------------------------------------------------------------------\n'
            printf '%s — embedded: %s (%s)\n' "${component}" "${title}" "${path}"
            printf -- '--------------------------------------------------------------------------------\n\n'
            printf 'Compiled into Zenit PDF: %s,\n' "${path}"
            printf '%s.\n' "${identity}"
            printf 'Its licence comment, reproduced verbatim from that file:\n\n'
            header_comment "${dir}/${path}" "${marker}"
        done
        for row in ${appended[@]+"${appended[@]}"}; do
            IFS='|' read -r owner aclone afile asha atitle <<< "${row}"
            printf '\n--------------------------------------------------------------------------------\n'
            printf '%s — %s\n' "${component}" "${atitle}"
            printf -- '--------------------------------------------------------------------------------\n\n'
            cat "${CLONES}/${aclone}/${afile}"
        done
    } > "${target}" || fail "writing ${target}"
    printf '  %-16s %-10s %6s bytes  %s\n' "${component}" "${revision}" \
        "$(wc -c < "${target}" | tr -d ' ')" "${component}.txt"
}

printf '=== regenerating bundle licence notices ===\n'

# Zenit PDF's own licence, so the acknowledgements surface opens with what the reader is
# actually running before it lists what that is built on.
[ -f "${ROOT}/LICENSE" ] || fail "no LICENSE at the repository root"
{
    printf '%s\n' "================================================================================"
    printf '%s\n' "Zenit PDF"
    printf '%s\n' "================================================================================"
    printf 'Zenit PDF is open source. This is its own licence; the notices that follow in the\n'
    printf 'Acknowledgements list belong to the components it is built on.\n\n'
    printf -- '--------------------------------------------------------------------------------\n\n'
    cat "${ROOT}/LICENSE"
} > "${OUT}/Zenit PDF.txt" || fail "writing the product licence"
printf '  %-16s %-10s %6s bytes  %s\n' "Zenit PDF" "(this repo)" \
    "$(wc -c < "${OUT}/Zenit PDF.txt" | tr -d ' ')" "Zenit PDF.txt"

for row in "${COMPONENTS[@]}"; do
    IFS='|' read -r component clone files <<< "${row}"
    emit "${component}" "${clone}" "${files}"
done

# --- The manifest the shipping gate reads -----------------------------------------------------
#
# Tab-separated, three columns: component, the file name inside Contents/Resources/Licenses, and
# the SHA-256 of that file. The gate fails when a listed component has no file, when a digest
# disagrees, or when the directory holds a file no row names.
{
    printf '# Shipped licence notices — generated by Scripts/regenerate-bundle-licences.sh\n'
    printf '# Read by Scripts/verify-licence-notices.sh, which fails the build when the bundle\n'
    printf '# and this list disagree. One row per component whose code is inside the binary\n'
    printf '# and whose licence requires a notice there.\n'
    printf '# component\tresource file\tsha256\n'
    for name in "Zenit PDF" "GRDB.swift" "qpdf" "Clipper2" "libxlsxwriter"; do
        printf '%s\t%s.txt\t%s\n' "${name}" "${name}" \
            "$(shasum -a 256 "${OUT}/${name}.txt" | cut -d' ' -f1)"
    done
} > "${MANIFEST}" || fail "writing ${MANIFEST}"

printf '\nmanifest: %s\n' "${MANIFEST}"
printf 'Now run Scripts/verify-licence-notices.sh; it is the gate, this is only the generator.\n'
exit 0
