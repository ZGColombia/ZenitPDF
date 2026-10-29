#!/bin/bash
#
# make-signing-identity.sh — the MAINTAINER runs this once, by hand, to create Zenit PDF's own
# self-signed code-signing identity for local certificate-signed builds (NL-PLAT-01). Published
# releases never use it: .github/workflows/release.yml signs them ad-hoc.
#
# Nothing in the build or in any test runs this script, and nobody else needs it: a normal
# Scripts/build-app.sh run is ad-hoc signed and reads no keychain. It is the only script in the
# repository that writes to a keychain, and it writes to the maintainer's login keychain only when
# run without --dry-run.
#
# Why it exists. Since macOS 14 a sandboxed app's container belongs to the code signature that
# created it. A plain ad-hoc signature is a per-build hash, so each new version looks like a
# different app. Scripts/build-app.sh already fixes that by default with an explicit ad-hoc
# requirement, `designated => identifier "com.zenitgroup.zenitpdf"` — stable, but any ad-hoc app
# that claims the identifier satisfies it. A self-signed certificate closes that gap: the
# requirement then names the certificate, and only whoever holds its private key can satisfy it.
# Gatekeeper treats the app exactly as before (the certificate is not Apple-issued). The bundle
# embeds no library, so Library Validation needs no exception either way.
#
# Usage:
#   Scripts/make-signing-identity.sh --dry-run        make the certificate in a temporary folder,
#                                                     print what would be imported, touch nothing
#   Scripts/make-signing-identity.sh                  create it and import it into the login keychain
#
# Afterwards (the script prints these with the real values):
#   1. write the printed requirement into Apps/ZenitPDF/Bundle/DesignatedRequirement.txt
#   2. build on this Mac with certificate signing on — build-app.sh then finds this identity
#      in the keychain by its name and fails unless the signed bundle matches the pin:
#        ZENIT_RELEASE_SIGNING=1 Scripts/build-app.sh --short-version X.Y.Z --scratch-path .build-release
#      (ZENIT_CODESIGN_IDENTITY=<SHA-1> names the identity explicitly instead of by name.)
#      The CI release job has no access to the key and builds ad-hoc without the pin.
#   3. back up the identity: Keychain Access ▸ the certificate ▸ Export… as .p12 with a
#      passphrase, stored offline. Losing it means a locally certificate-signed copy changes
#      identity and asks once.
#
# Published releases stay ad-hoc and are never mixed with certificate-signed builds: switching
# mode is itself a "differs from previously opened versions" event for every installed copy.

set -euo pipefail

COMMON_NAME="Zenit PDF Code Signing (self-signed)"
DAYS=7300   # twenty years: expiry does not invalidate an existing signature, but keep it long
DRY_RUN=0
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "make-signing-identity.sh: unknown argument ${arg}" >&2; exit 2 ;;
    esac
done

OPENSSL=/usr/bin/openssl
[[ -x "${OPENSSL}" ]] || { echo "no ${OPENSSL}" >&2; exit 1; }

WORK="$(mktemp -d)"
chmod 700 "${WORK}"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${COMMON_NAME}
O = ZENIT GROUP S.A.S.
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "== Creating the certificate (RSA 3072, codeSigning, ${DAYS} days)"
( umask 077
  "${OPENSSL}" req -x509 -newkey rsa:3072 -nodes -sha256 -days "${DAYS}" \
      -config "${WORK}/cert.cnf" -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null )
"${OPENSSL}" x509 -in "${WORK}/cert.pem" -noout -subject -enddate -ext extendedKeyUsage 2>/dev/null \
    || "${OPENSSL}" x509 -in "${WORK}/cert.pem" -noout -subject -enddate
SHA1="$("${OPENSSL}" x509 -in "${WORK}/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "SHA-1: ${SHA1}"

# The requirement codesign will derive from this certificate: identifier plus the certificate's
# own hash (for a self-signed certificate the leaf is the root).
REQUIREMENT="identifier \"com.zenitgroup.zenitpdf\" and certificate root = H\"$(echo "${SHA1}" | tr 'A-F' 'a-f')\""

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo
    echo "Dry run: nothing was imported. A real run would import this identity into"
    echo "  $(security default-keychain -d user | tr -d ' "')"
    echo "allowing /usr/bin/codesign to use it, and print:"
    echo "  SHA-1 (for ZENIT_CODESIGN_IDENTITY, optional): ${SHA1}"
    echo "  expected requirement: ${REQUIREMENT}"
    exit 0
fi

echo "== Importing into the login keychain (you may be asked for your login password)"
# `tr < /dev/urandom | head` dies of SIGPIPE when head has enough, and under `set -o pipefail` that
# failed pipeline silently ended the script right here, before anything was imported (2026-09-26).
PASS="$("${OPENSSL}" rand -hex 24)"
( umask 077
  "${OPENSSL}" pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
      -name "${COMMON_NAME}" -passout "pass:${PASS}" -out "${WORK}/identity.p12" )
security import "${WORK}/identity.p12" -P "${PASS}" -T /usr/bin/codesign
unset PASS

# Without a key partition list macOS asks for permission every time codesign uses the key, and when
# nobody can answer (a locked screen during a long build) signing fails with errSecInternalComponent
# (2026-09-26). Allowing Apple's own tools and codesign once removes the prompt. `security` asks for the
# login-keychain password itself on this terminal; it is never stored or echoed by this script.
echo "== Allowing codesign to use the key without a prompt (enter your login password when asked)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "${COMMON_NAME}" -t private \
    "$(security default-keychain -d user | tr -d ' "')" >/dev/null

echo "== Self-test: sign two throwaway bundles with the new identity"
printf 'int main(void){return 0;}\n' > "${WORK}/probe.c"
xcrun clang -o "${WORK}/probe" "${WORK}/probe.c"
for n in 1 2; do
    app="${WORK}/t${n}/Zenit PDF.app"
    mkdir -p "${app}/Contents/MacOS"
    cp "${WORK}/probe" "${app}/Contents/MacOS/ZenitPDF"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.zenitgroup.zenitpdf" \
        -c "Add :CFBundleExecutable string ZenitPDF" -c "Add :CFBundleVersion string ${n}" \
        "${app}/Contents/Info.plist" >/dev/null
    codesign --force --sign "${SHA1}" --options runtime --timestamp=none "${app}" || {
        echo "FAILED: codesign would not use the new identity." >&2
        echo "If it reported CSSMERR_TP_NOT_TRUSTED, open Keychain Access, double-click" >&2
        echo "'${COMMON_NAME}', set Trust ▸ Code Signing to Always Trust, and run the self-test" >&2
        echo "again with: codesign --force --sign ${SHA1} <any .app>" >&2
        exit 1
    }
done
REQ1="$(codesign -d -r- "${WORK}/t1/Zenit PDF.app" 2>/dev/null | sed -n 's/^# //; s/^designated => //p')"
REQ2="$(codesign -d -r- "${WORK}/t2/Zenit PDF.app" 2>/dev/null | sed -n 's/^# //; s/^designated => //p')"
echo "build 1: designated => ${REQ1}"
echo "build 2: designated => ${REQ2}"
[[ -n "${REQ1}" && "${REQ1}" == "${REQ2}" ]] || { echo "FAILED: the two requirements differ" >&2; exit 1; }
codesign --verify --strict -R="${REQ1}" "${WORK}/t2/Zenit PDF.app"
echo "ok: build 2 satisfies build 1's requirement"

cat <<EOF

Done. Next, by hand:
  1. printf '%s\n' '${REQ1}' > Apps/ZenitPDF/Bundle/DesignatedRequirement.txt
  2. build locally with certificate signing on (never for a published release):
       ZENIT_RELEASE_SIGNING=1 Scripts/build-app.sh --short-version X.Y.Z --scratch-path .build-release
     (the identity is found by its name; ZENIT_CODESIGN_IDENTITY=${SHA1} names it explicitly)
  3. export a .p12 backup from Keychain Access and store it offline
EOF
