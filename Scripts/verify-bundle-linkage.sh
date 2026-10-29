#!/bin/bash
#
# verify-bundle-linkage.sh — refuse a bundle that cannot start.
#
# On 2026-08-24 a built "Zenit PDF.app" was copied to a scratch directory and launched. It died in
# dyld before main():
#
#     Termination Reason: Namespace DYLD, Code 1, Library missing
#     Library not loaded: @rpath/<an embedded framework, since removed>
#
# The build script had already reported success. Every gate was green. The failure was discovered
# by a human seeing a crash dialog, which is the worst way to discover anything.
#
# This script resolves every @rpath/@loader_path/@executable_path dependency of every Mach-O in a
# bundle against that bundle's own LC_RPATH entries, exactly as dyld would, and fails if any of
# them cannot be found inside the bundle or in the system's shared cache. It launches nothing.
#
# Usage:  Scripts/verify-bundle-linkage.sh [path/to/Some.app]
#         defaults to build/Zenit PDF.app
#
# Exit 0 = every dependency resolves. Non-zero = the bundle would fail to launch, with the reason.

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
    "${ROOT}/Scripts/wave-marker.sh" check Apps
fi

readonly BUNDLE="${1:-${ROOT}/build/Zenit PDF.app}"

fail() {
    printf '\n=======================================================================\n'
    printf 'FAILED: %s\n' "$1"
    printf '=======================================================================\n'
    exit 1
}

[ -d "${BUNDLE}" ] || fail "no bundle at ${BUNDLE}"

printf '=== linkage check: %s ===\n' "${BUNDLE##*/}"

# Every Mach-O in the bundle: the main executable, embedded frameworks, XPC services, helpers.
# -perm +111 is not enough (frameworks' binaries are not always +x), so ask `file` instead.
machos=()
while IFS= read -r candidate; do
    case "$(file -b "${candidate}" 2>/dev/null)" in
        *Mach-O*) machos+=("${candidate}") ;;
    esac
done < <(find "${BUNDLE}" -type f -not -path '*/Headers/*' -not -name '*.h' \
             -not -name '*.plist' -not -name '*.nib' -not -name '*.strings' 2>/dev/null)

[ "${#machos[@]}" -gt 0 ] || fail "found no Mach-O binaries inside the bundle — the scan is vacuous"

checked=0
resolved=0
for macho in "${machos[@]}"; do
    # This binary's own search paths, in order.
    rpaths=()
    while IFS= read -r rp; do
        [ -n "${rp}" ] && rpaths+=("${rp}")
    done < <(otool -l "${macho}" 2>/dev/null \
             | sed -n '/LC_RPATH/,/^ *path /p' \
             | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p')

    # A dylib's own install name (LC_ID_DYLIB) is the first tab-indented line of `otool -L`, so a
    # framework appears to "depend on itself". Read it separately and skip it — otherwise every
    # embedded framework fails the check for existing.
    install_name="$(otool -D "${macho}" 2>/dev/null | grep -v '(architecture' | grep -v ':$' \
                    | sed -E 's/^[[:space:]]+//' | head -1)"

    while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        [ "${dep}" = "${install_name}" ] && continue
        checked=$((checked + 1))

        # Absolute paths and the shared cache resolve without our help.
        case "${dep}" in
            /usr/lib/*|/System/*)
                resolved=$((resolved + 1))
                continue
                ;;
        esac

        found=""
        for rp in ${rpaths[@]+"${rpaths[@]}"}; do
            candidate="${dep}"
            expanded="${rp}"
            # dyld expands these relative to the binary being loaded.
            expanded="${expanded//@executable_path/${BUNDLE}/Contents/MacOS}"
            expanded="${expanded//@loader_path/$(dirname "${macho}")}"
            candidate="${candidate//@rpath/${expanded}}"
            candidate="${candidate//@executable_path/${BUNDLE}/Contents/MacOS}"
            candidate="${candidate//@loader_path/$(dirname "${macho}")}"
            if [ -f "${candidate}" ]; then
                found="${candidate}"
                break
            fi
        done

        # A dependency that is not @rpath-relative may still be @loader_path/@executable_path based.
        if [ -z "${found}" ]; then
            direct="${dep}"
            direct="${direct//@executable_path/${BUNDLE}/Contents/MacOS}"
            direct="${direct//@loader_path/$(dirname "${macho}")}"
            [ -f "${direct}" ] && found="${direct}"
        fi

        if [ -z "${found}" ]; then
            printf '\n  UNRESOLVED  %s\n' "${dep}"
            printf '  required by %s\n' "${macho#${BUNDLE}/}"
            if [ "${#rpaths[@]}" -eq 0 ]; then
                printf '  that binary declares NO LC_RPATH at all\n'
            else
                printf '  searched:\n'
                printf '    %s\n' ${rpaths[@]+"${rpaths[@]}"}
            fi
            fail "the bundle would die in dyld before main() — this is exactly the 2026-08-24 crash"
        fi
        resolved=$((resolved + 1))
    # Do NOT use awk $1 here: dependency paths contain spaces whenever the checkout lives under a
    # folder whose name has one, and splitting on whitespace silently truncates them —
    # the same trap that made two earlier gates pass vacuously.
    # A universal binary makes otool print one "<path> (architecture arm64):" header PER SLICE, so
    # `tail -n +2` strips only the first and the next header is read as a dependency. Dependencies
    # are tab-indented and headers are not — select on that instead.
    done < <(otool -L "${macho}" 2>/dev/null | grep $'^\t' \
             | sed -E 's/^[[:space:]]+//; s/ \(compatibility version .*$//' | sort -u)
done

printf -- '--- %d Mach-O binaries, %d dependencies, %d resolved ---\n' \
    "${#machos[@]}" "${checked}" "${resolved}"

# Resolving a path is not the same as being allowed to load it. Under Hardened Runtime, Library
# Validation refuses any code whose Team ID differs from the main executable's, and an ad-hoc
# signature has NO Team ID — so an ad-hoc app loading an ad-hoc framework dies in dyld with
# "mapping process and mapped file (non-platform) have different Team IDs". The path check above
# passes happily on such a bundle, which is how this defect reached a green build twice.
#
# Library Validation concerns code *loaded into a process*: dynamic libraries, frameworks and
# loadable bundles. The XPC services, the Quick Look extensions and the command-line tool are
# separate executables, each its own process with its own signature, so they are not checked
# against the main executable's team. Today the bundle embeds no library at all, every dependency
# resolves to the operating system, and the app carries no disable-library-validation entitlement.
section_lv() { printf '\n=== library validation ===\n'; }
section_lv

main_exe="${BUNDLE}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "${BUNDLE}/Contents/Info.plist" 2>/dev/null)"
[ -f "${main_exe}" ] || fail "cannot find the main executable named by Info.plist"

main_flags="$(codesign -dv "${main_exe}" 2>&1 | sed -n 's/.*flags=[^(]*(\(.*\)).*/\1/p')"
main_team="$(codesign -dv "${main_exe}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
has_runtime=0
case "${main_flags}" in *runtime*) has_runtime=1 ;; esac
lv_disabled=0
codesign -d --entitlements - --xml "${BUNDLE}" 2>/dev/null \
    | grep -q 'disable-library-validation' && lv_disabled=1

printf 'main executable: flags=%s team=%s\n' "${main_flags:-none}" "${main_team:-not set}"
printf 'hardened runtime: %s · library validation disabled by entitlement: %s\n' \
    "$([ "${has_runtime}" -eq 1 ] && echo yes || echo no)" \
    "$([ "${lv_disabled}" -eq 1 ] && echo yes || echo no)"

# Every loadable library in the bundle: a Mach-O dylib or bundle, wherever it sits.
libraries=()
for macho in "${machos[@]}"; do
    case "$(file -b "${macho}" 2>/dev/null)" in
        *"dynamically linked shared library"*|*"Mach-O"*" bundle"*) libraries+=("${macho}") ;;
    esac
done
printf 'embedded loadable libraries: %d\n' "${#libraries[@]}"

if [ "${has_runtime}" -eq 1 ] && [ "${lv_disabled}" -eq 0 ]; then
    for library in ${libraries[@]+"${libraries[@]}"}; do
        team="$(codesign -dv "${library}" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
        if [ "${team:-not set}" != "${main_team:-not set}" ] || [ "${main_team:-not set}" = "not set" ]; then
            printf '\n  LIBRARY VALIDATION WILL REFUSE  %s\n' "${library#${BUNDLE}/}"
            printf '  its team: %s · main executable team: %s\n' "${team:-not set}" "${main_team:-not set}"
            fail "Hardened Runtime is on with Library Validation in force, and an embedded library is not signed by the main executable's Team ID — the process will die in dyld before main(). Sign everything with one Developer ID, or embed no library."
        fi
    done
    printf 'library validation is in force; all %d embedded libraries share the main executable team identity\n' "${#libraries[@]}"
else
    printf 'library validation is not enforced for this bundle; team identities need not match\n'
fi

[ "${checked}" -gt 0 ] || fail "no dependencies were examined; a gate that scans nothing must fail"

printf '\n=======================================================================\n'
printf 'Every dynamic dependency resolves inside the bundle. It can start.\n'
printf '=======================================================================\n'
exit 0
