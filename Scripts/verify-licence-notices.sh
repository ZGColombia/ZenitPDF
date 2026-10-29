#!/bin/bash
#
# verify-licence-notices.sh — every component whose code is in the binary must have its licence
# text inside the bundle.
#
# ## Why this is a gate and not a checklist
#
# On 2026-08-26 `Zenit PDF.app/Contents/Resources` held four things: `AppIcon.icns`,
# `ProjectDocument.icns`, `GRDB_GRDB.bundle` and `en.lproj`. Not one line of licence text, and
# the About item was `orderFrontStandardAboutPanel(_:)` — the panel that shows a version number
# and offers no route to any notice.
#
# That is a compliance failure, not untidiness. qpdf ships under Apache-2.0 and §4(d) obliges a
# redistributor to carry the upstream `NOTICE`; qpdf's is substantive, offering a pre-v7
# Artistic-2.0 alternative, covering the bundled `qtest`, and crediting the Rijndael and sphlib
# implementations behind its AES and SHA-2 support; qpdf's compiled `MD5_native.cc` also carries
# an RSA Data Security notice that must be retained in every copy. libxlsxwriter's FreeBSD
# notice carries minizip and the FreeBSD `queue.h`/`tree.h` macros. Clipper2 is Boost-1.0 and
# GRDB is MIT. `Docs/Licences/LICENSE_EVIDENCE.md` is the audited list of all of it.
#
# A checklist cannot hold this, because the failure mode is silence: a dependency is added, the
# notice is not, and nothing anywhere goes red. So this is a gate, it runs inside
# `Scripts/build-app.sh`, and it fails the build.
#
# ## What it checks
#
#   1. **The manifest is real.** `Docs/Licences/SHIPPED_NOTICES.tsv` must exist and name at
#      least `MINIMUM_COMPONENTS` components. A manifest that shrank is the exact shape of the
#      failure being guarded against, so the floor is a hard number rather than "more than one".
#   2. **Every listed component has text in the source tree**, non-empty, and with the SHA-256
#      the manifest records. A digest rather than a byte count, because a notice can be
#      truncated to a plausible length.
#   3. **Every listed component has that same text in the assembled bundle**, at
#      `Contents/Resources/Licenses/<file>` — the copy that actually reaches a user.
#   4. **Nothing unlisted is in either place.** An unaccounted notice means the manifest and the
#      product disagree, and a disagreement in this direction is how a stale notice for a
#      component we no longer ship survives — which is the mirror image of the omission and
#      just as wrong (THIRD-PARTY-NOTICES.md named PDFium as shipped and OpenCV as conditional
#      when neither is in the build at all).
#   5. **The About surface still reads them.** Every previous version of a fix in this
#      repository has at some point been built and then not called; a notice nothing displays
#      discharges nothing. The scan asserts `ZenitAboutWindowController` reads the directory
#      this gate checks and that the application menu's About item targets it.
#
# ## Non-vacuity
#
# Non-vacuity. Three floors, because each one has a way of passing while measuring nothing:
# the manifest must carry at least `MINIMUM_COMPONENTS` rows, every row must be checked (the
# count of verified rows is compared against the row count, not merely reported), and the total
# verified notice text must exceed `MINIMUM_TOTAL_BYTES` — a directory of six empty files
# satisfies "a file exists per component" and satisfies nothing else.
#
# Usage:
#   Scripts/verify-licence-notices.sh [path/to/Zenit PDF.app]
#
# With no argument it uses `build/Zenit PDF.app`. When no bundle exists at all the gate fails
# and says to run `Scripts/build-app.sh` — it does not quietly check half of itself, because
# the half it would skip is the half a user receives.

set -u
set -o pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MANIFEST="${ROOT}/Docs/Licences/SHIPPED_NOTICES.tsv"
readonly EVIDENCE="${ROOT}/Docs/Licences/LICENSE_EVIDENCE.md"
readonly SOURCE_DIR="${ROOT}/Apps/ZenitPDF/Bundle/Licenses"
readonly APP_BUNDLE="${1:-${ROOT}/build/Zenit PDF.app}"
readonly RESOURCE_SUBDIR="Contents/Resources/Licenses"
readonly ABOUT="${ROOT}/Apps/ZenitPDF/Sources/ZenitPDFAppKit/App/ZenitAboutWindowController.swift"
readonly MENU="${ROOT}/Apps/ZenitPDF/Sources/ZenitPDFAppKit/Menu/ZenitMenuBar.swift"

# The five components whose code is in the binary, as of 2026-10-27: the product itself plus
# GRDB.swift, qpdf, Clipper2 and libxlsxwriter. A manifest with fewer has lost one. (Six until
# the update framework was removed with the auto-update feature on 2026-10-27.)
readonly MINIMUM_COMPONENTS=5
# The five shipped notices total 56 735 bytes as measured on 2026-10-29 (33 262 on 2026-10-28,
# before the GRDB embedded notices, its Apache-2.0 appendix and the Zenit PDF prefaces were
# added); qpdf's Apache-2.0 text alone is 11 kB, and the smallest notice is under 1.5 kB. The
# floor stays at 29 500, well below that total: losing
# the qpdf or the libxlsxwriter notice takes the total under it, and regenerating a notice with
# a different header does not redden the gate. A lost small notice is caught by the row count
# and the digests instead.
readonly MINIMUM_TOTAL_BYTES=29500

if [ -x "${ROOT}/Scripts/wave-marker.sh" ]; then
    "${ROOT}/Scripts/wave-marker.sh" check Apps/ZenitPDF/Bundle Docs/Licences
fi

failures=0
note()  { printf '%s\n' "$1"; }
bad()   { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

printf '=== licence notices : every shipped component carries its text ===\n'

# --- 1. The manifest --------------------------------------------------------------------------

[ -f "${MANIFEST}" ] || {
    printf 'FAIL: no manifest at %s.\n' "${MANIFEST}" >&2
    printf '      Regenerate it with Scripts/regenerate-bundle-licences.sh (needs the upstream clones).\n' >&2
    exit 1
}
[ -f "${EVIDENCE}" ] || {
    printf 'FAIL: no licence evidence at %s. The manifest is derived from it.\n' "${EVIDENCE}" >&2
    exit 1
}

rows="$(grep -v '^#' "${MANIFEST}" | grep -v '^[[:space:]]*$' || true)"
row_count="$(printf '%s\n' "${rows}" | grep -c . || true)"
note "manifest: ${row_count} component(s) listed in $(basename "${MANIFEST}")"

if [ "${row_count}" -lt "${MINIMUM_COMPONENTS}" ]; then
    printf 'FAIL: the manifest lists %s component(s); the floor is %s.\n' \
        "${row_count}" "${MINIMUM_COMPONENTS}" >&2
    printf '      A shrinking manifest is precisely the failure this gate exists to catch.\n' >&2
    exit 1
fi

# The manifest is a generated convenience; the **evidence file** is the audited authority, and
# the task is stated in terms of it: a component named there as shipping must have text in
# `Contents/Resources`. `LICENSE_EVIDENCE.md` carries a fenced `zenit-shipped-components` block
# for exactly this, and the two lists must agree in both directions — otherwise adding a
# dependency to the audit without regenerating the notices would pass, which is the original
# defect with an extra step.
evidence_list="$(awk '
    /^```zenit-shipped-components$/ { inside = 1; next }
    /^```$/ { inside = 0 }
    inside && NF { print }
' "${EVIDENCE}")"
evidence_count="$(printf '%s\n' "${evidence_list}" | grep -c . || true)"

if [ "${evidence_count}" -lt "${MINIMUM_COMPONENTS}" ]; then
    printf 'FAIL: %s has no usable zenit-shipped-components block (%s row(s) read).\n' \
        "$(basename "${EVIDENCE}")" "${evidence_count}" >&2
    printf '      That block is the audited authority this gate is written against. Without it\n' >&2
    printf '      the gate would be checking a generated file against itself.\n' >&2
    exit 1
fi

manifest_components="$(printf '%s\n' "${rows}" | cut -f1 | sort)"
if [ "$(printf '%s\n' "${evidence_list}" | sort)" != "${manifest_components}" ]; then
    printf 'FAIL: the audited shipped set and the notice manifest name different components.\n' >&2
    printf '  only in %s:\n' "$(basename "${EVIDENCE}")" >&2
    comm -23 <(printf '%s\n' "${evidence_list}" | sort) <(printf '%s\n' "${manifest_components}") \
        | sed 's/^/    · /' >&2
    printf '  only in %s:\n' "$(basename "${MANIFEST}")" >&2
    comm -13 <(printf '%s\n' "${evidence_list}" | sort) <(printf '%s\n' "${manifest_components}") \
        | sed 's/^/    · /' >&2
    printf '      Run Scripts/regenerate-bundle-licences.sh, or correct the audit.\n' >&2
    exit 1
fi
note "audited shipped set: ${evidence_count} component(s), matching the manifest exactly"

# --- 2 & 3. Source tree and assembled bundle ---------------------------------------------------

bundle_present=1
if [ ! -d "${APP_BUNDLE}" ]; then
    bundle_present=0
fi

verified=0
total_bytes=0
listed_files=""

while IFS=$'\t' read -r component file digest; do
    [ -n "${component}" ] || continue
    listed_files="${listed_files}${file}"$'\n'

    src="${SOURCE_DIR}/${file}"
    if [ ! -s "${src}" ]; then
        bad "${component}: no notice text at ${src}"
        continue
    fi
    actual="$(shasum -a 256 "${src}" | cut -d' ' -f1)"
    if [ "${actual}" != "${digest}" ]; then
        bad "${component}: ${file} does not match the manifest digest
        manifest ${digest}
        on disk  ${actual}
        A notice that has been edited is no longer the notice. Re-run
        Scripts/regenerate-bundle-licences.sh if the dependency was bumped on purpose."
        continue
    fi

    if [ "${bundle_present}" -eq 1 ]; then
        shipped="${APP_BUNDLE}/${RESOURCE_SUBDIR}/${file}"
        if [ ! -s "${shipped}" ]; then
            bad "${component}: the assembled bundle carries no ${RESOURCE_SUBDIR}/${file}"
            continue
        fi
        shipped_digest="$(shasum -a 256 "${shipped}" | cut -d' ' -f1)"
        if [ "${shipped_digest}" != "${digest}" ]; then
            bad "${component}: the bundle's copy of ${file} differs from the manifest digest"
            continue
        fi
    fi

    bytes="$(wc -c < "${src}" | tr -d ' ')"
    total_bytes=$((total_bytes + bytes))
    verified=$((verified + 1))
    printf '  %-16s %7s bytes  %s…\n' "${component}" "${bytes}" "${digest:0:12}"
done <<< "${rows}"

# --- 4. Nothing unlisted ------------------------------------------------------------------------

check_orphans() {
    local dir="$1" label="$2" name
    [ -d "${dir}" ] || return 0
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        case "${name}" in *.txt) ;; *) bad "${label}: ${name} is not a .txt notice"; continue ;; esac
        if ! printf '%s' "${listed_files}" | grep -qxF "${name}"; then
            bad "${label}: ${name} is present but no manifest row names it.
        An unaccounted notice is how a stale one survives a dependency being dropped —
        THIRD-PARTY-NOTICES.md named PDFium as shipped and OpenCV as conditional when
        neither is in the build. Remove it, or add the row that explains it."
        fi
    done < <(ls -1 "${dir}" 2>/dev/null)
}

check_orphans "${SOURCE_DIR}" "Apps/ZenitPDF/Bundle/Licenses"
[ "${bundle_present}" -eq 1 ] && check_orphans "${APP_BUNDLE}/${RESOURCE_SUBDIR}" "${RESOURCE_SUBDIR}"

# --- 5. The surface that shows them --------------------------------------------------------------

if [ ! -f "${ABOUT}" ]; then
    bad "no acknowledgements surface at ${ABOUT}; the notices ship but nothing displays them"
else
    grep -q 'resourceDirectoryName = "Licenses"' "${ABOUT}" \
        || bad "${ABOUT##*/} no longer reads Contents/Resources/Licenses, so the shipped notices are unreachable"
fi

if [ ! -f "${MENU}" ]; then
    bad "no menu bar at ${MENU}"
else
    # Code, not prose: the comment above the About item names the selector it replaced, and a
    # gate that cannot tell an explanation from a regression teaches people to delete the
    # explanation.
    if grep -vE '^[[:space:]]*(//|///|\*)' "${MENU}" | grep -q 'orderFrontStandardAboutPanel'; then
        bad "the application menu is back on orderFrontStandardAboutPanel(_:), which shows no
        licence text and offers no route to any. That was the state this gate was written for."
    fi
    grep -q 'ZenitAboutWindowController.showAbout' "${MENU}" \
        || bad "the application menu's About item no longer targets ZenitAboutWindowController"
fi

# --- Non-vacuity ---------------------------------------------------------------------------------

printf '\n=== non-vacuity ===\n'
printf 'rows listed %s · rows verified %s · notice bytes %s\n' \
    "${row_count}" "${verified}" "${total_bytes}"

if [ "${verified}" -ne "${row_count}" ] && [ "${failures}" -eq 0 ]; then
    bad "verified ${verified} of ${row_count} rows with no failure recorded; the loop skipped work"
fi
if [ "${failures}" -eq 0 ] && [ "${total_bytes}" -lt "${MINIMUM_TOTAL_BYTES}" ]; then
    bad "the verified notices total ${total_bytes} bytes against a floor of ${MINIMUM_TOTAL_BYTES}.
        Empty files satisfy 'a file per component' and satisfy nothing else."
fi

if [ "${bundle_present}" -eq 0 ]; then
    printf '\nFAIL: no assembled bundle at %s, so the copy a user receives was not checked.\n' \
        "${APP_BUNDLE}" >&2
    printf '      Run Scripts/build-app.sh first, or pass the bundle path as the first argument.\n' >&2
    printf '      A gate that cannot see the artefact does not pass on the source tree alone.\n' >&2
    exit 1
fi

if [ "${failures}" -gt 0 ]; then
    printf '\nFAILED: %s licence-notice problem(s). Apache-2.0 section 4(d) is not advisory.\n' \
        "${failures}" >&2
    exit 1
fi

printf '\n%s component(s), %s bytes of licence text, present in the source tree and in\n' \
    "${verified}" "${total_bytes}"
printf '%s, and reachable from the application menu.\n' "${APP_BUNDLE}/${RESOURCE_SUBDIR}"
exit 0
