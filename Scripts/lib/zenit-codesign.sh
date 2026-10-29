# zenit-codesign.sh — the one place that decides how a piece of Zenit PDF is code-signed.
#
# Sourced (never executed) by Scripts/build-app.sh, so every piece of the bundle is signed the same
# way. Call `zenit_codesign_prepare` once after sourcing and before the first `zenit_sign`.
#
# ---------------------------------------------------------------------------------------------
# Two modes, chosen by the environment, never by editing this file
# ---------------------------------------------------------------------------------------------
#
#   default (ZENIT_RELEASE_SIGNING unset or not 1)
#       Ad-hoc (`codesign --sign -`) with an EXPLICIT designated requirement,
#       `designated => identifier "<bundle id>"`. Needs no certificate and no keychain, so anyone
#       can build: a contributor, CI, a person building from source. Every published release is
#       signed this way, by .github/workflows/release.yml. ZENIT_CODESIGN_IDENTITY is ignored and
#       the keychain is never read. Honest cost: any ad-hoc app that claims the same identifier
#       satisfies the requirement.
#
#   ZENIT_RELEASE_SIGNING=1  (a maintainer option for local builds; never a published release)
#       Signs with ZENIT_CODESIGN_IDENTITY when it is set (a SHA-1 or a name), otherwise with the
#       keychain identity whose common name is exactly "Zenit PDF Code Signing (self-signed)" —
#       the certificate Scripts/make-signing-identity.sh creates once. The lookup is a read-only
#       `security find-identity`; nothing is created, imported or trusted here, and codesign asks
#       the keychain for the private key itself. When no identity can be found the build stops:
#       this mode never falls back to ad-hoc. codesign derives the requirement from the
#       certificate, so only the holder of that private key can satisfy it, and build-app.sh then
#       enforces the pin in Apps/ZenitPDF/Bundle/DesignatedRequirement.txt.
#
# ---------------------------------------------------------------------------------------------
# Why the designated requirement is written out (NL-PLAT-01)
# ---------------------------------------------------------------------------------------------
# A plain ad-hoc signature gets a *synthesised* designated requirement: `cdhash H"…" or cdhash
# H"…"`, one hash per architecture. It names one build and nothing else, so build B never
# satisfies build A's requirement. Since macOS 14 the App Sandbox ties a container to the code
# signature of the app that created it and asks the person — "“Zenit PDF” differs from previously
# opened versions" — when an app that does not satisfy the recorded requirement opens it.
# Security-scoped bookmarks (Open Recent, remembered drops) are resolved against the same
# identity. An explicit `identifier` requirement keeps consecutive ad-hoc builds one identity.
#
# Switching between the two modes changes the requirement, and that change is itself the event
# that raises the dialog once. Published releases therefore stay in the default mode and are never
# mixed with certificate-signed builds.

ZENIT_CODESIGN_COMMON_NAME="Zenit PDF Code Signing (self-signed)"

# True when the maintainer asked for release signing.
zenit_release_signing() {
    [[ "${ZENIT_RELEASE_SIGNING:-0}" == "1" ]]
}

# The SHA-1 of the first code-signing identity whose common name is exactly
# ZENIT_CODESIGN_COMMON_NAME, or nothing. Called only in release mode.
zenit_find_keychain_identity() {
    security find-identity -p codesigning 2>/dev/null \
        | awk -v cn="\"${ZENIT_CODESIGN_COMMON_NAME}\"" 'index($0, cn) && $2 ~ /^[0-9A-F]{40}$/ { print $2; exit }'
}

# Resolves the signing identity. Returns non-zero, with the reason on stderr, when release signing
# was asked for and no identity exists.
zenit_codesign_prepare() {
    if ! zenit_release_signing; then
        if [[ -n "${ZENIT_CODESIGN_IDENTITY:-}" ]]; then
            echo "zenit-codesign: ZENIT_CODESIGN_IDENTITY is ignored without ZENIT_RELEASE_SIGNING=1; signing ad-hoc" >&2
        fi
        return 0
    fi
    if [[ -n "${ZENIT_CODESIGN_IDENTITY:-}" ]]; then
        echo "zenit-codesign: release signing with ZENIT_CODESIGN_IDENTITY (${ZENIT_CODESIGN_IDENTITY})" >&2
        return 0
    fi
    local found
    found="$(zenit_find_keychain_identity)"
    if [[ -z "${found}" ]]; then
        echo "zenit-codesign: ZENIT_RELEASE_SIGNING=1, but ZENIT_CODESIGN_IDENTITY is not set and the keychain holds no code-signing identity named \"${ZENIT_CODESIGN_COMMON_NAME}\" (Scripts/make-signing-identity.sh creates it). A release is never signed ad-hoc by accident; unset ZENIT_RELEASE_SIGNING for a normal build." >&2
        return 1
    fi
    export ZENIT_CODESIGN_IDENTITY="${found}"
    echo "zenit-codesign: release signing with the keychain identity \"${ZENIT_CODESIGN_COMMON_NAME}\" (${found})" >&2
}

# The signing identity codesign is given: "-" (ad-hoc) unless release signing is on.
zenit_codesign_identity() {
    if zenit_release_signing && [[ -n "${ZENIT_CODESIGN_IDENTITY:-}" ]]; then
        printf '%s' "${ZENIT_CODESIGN_IDENTITY}"
    else
        printf '%s' "-"
    fi
}

# "release" or "adhoc-stable" — printed by the build so a log says which mode shipped.
zenit_codesign_mode() {
    if zenit_release_signing; then printf 'release'; else printf 'adhoc-stable'; fi
}

# The code-signing identifier a piece of code carries. A bundle's is its CFBundleIdentifier. A bare
# executable keeps the identifier it already has (the linker's ad-hoc signature names it after the
# file), because codesign's ad-hoc default for a file with no Info.plist is "<name>-<hash of the
# code>", and the hash half would change with every build.
zenit_code_identifier() {
    local target="$1"
    local plist=""
    if [[ -f "${target}/Contents/Info.plist" ]]; then
        plist="${target}/Contents/Info.plist"
    elif [[ -f "${target}/Resources/Info.plist" ]]; then
        plist="${target}/Resources/Info.plist"   # a framework's version directory
    fi
    if [[ -n "${plist}" ]]; then
        plutil -extract CFBundleIdentifier raw -o - "${plist}" 2>/dev/null && return 0
    fi
    codesign -dv "${target}" 2>&1 | sed -n 's/^Identifier=//p' | head -n 1
}

# zenit_sign <path> [entitlements-file]
#
# Signs one piece with Hardened Runtime and no timestamp, plus the stable requirement in ad-hoc
# mode. Innermost-first ordering stays the caller's job.
zenit_sign() {
    local target="$1"
    local entitlements="${2:-}"
    if zenit_release_signing && [[ -z "${ZENIT_CODESIGN_IDENTITY:-}" ]]; then
        echo "zenit_sign: release signing has no identity; call zenit_codesign_prepare first" >&2
        return 1
    fi
    local identity
    identity="$(zenit_codesign_identity)"
    local args=(--force --sign "${identity}" --options runtime --timestamp=none)
    if [[ -n "${entitlements}" ]]; then
        args+=(--entitlements "${entitlements}")
    fi
    if [[ "${identity}" == "-" ]]; then
        local identifier
        identifier="$(zenit_code_identifier "${target}")"
        if [[ -z "${identifier}" ]]; then
            echo "zenit_sign: cannot determine the code identifier of ${target}" >&2
            return 1
        fi
        args+=(--identifier "${identifier}" "-r=designated => identifier \"${identifier}\"")
    fi
    codesign "${args[@]}" "${target}"
}

# The designated requirement of a signed bundle, without the "designated => " prefix and without
# the "# " codesign prints in front of a synthesised (implicit) one.
zenit_designated_requirement() {
    codesign -d -r- "$1" 2>/dev/null | sed -n 's/^# //; s/^designated => //p' | head -n 1
}
