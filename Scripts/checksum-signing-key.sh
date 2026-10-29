#!/bin/bash
#
# checksum-signing-key.sh — the release key that signs SHA256SUMS.txt (NL-PLAT-02).
#
# Why ECDSA P-256: the one-line installer (Scripts/install.sh) runs with nothing but a stock Mac,
# and the stock /usr/bin/openssl (LibreSSL) has no Ed25519 but does verify ECDSA P-256. This key
# signs only the checksum file published with each release; install.sh pins its public half, so a
# mirror that swaps both the disk image and SHA256SUMS.txt is still caught.
#
#   Scripts/checksum-signing-key.sh generate [KEYFILE]   MAINTAINER, once. Writes a P-256 private key
#                                                        (mode 600, refuses to overwrite; default
#                                                        ~/.zenit-release/checksums-p256.pem) and
#                                                        prints the public half to pin in install.sh
#   Scripts/checksum-signing-key.sh public [KEYFILE]     prints the public PEM and its fingerprint
#   Scripts/checksum-signing-key.sh sign SUMS [KEYFILE]  writes SUMS.sig next to SUMS
#   Scripts/checksum-signing-key.sh selftest             throwaway key in a temp dir: proves
#                                                        install.sh accepts a good signature and
#                                                        refuses a tampered file or another key
#
# Keep the private key out of the repository and backed up offline. No part of the build, the
# tests or CI reads it, and this script never touches the keychain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL=/usr/bin/openssl
DEFAULT_KEY="${HOME}/.zenit-release/checksums-p256.pem"

die() { printf 'checksum-signing-key.sh: %s\n' "$*" >&2; exit 1; }

public_pem() { "${OPENSSL}" ec -in "$1" -pubout 2>/dev/null; }
fingerprint() { public_pem "$1" | "${OPENSSL}" pkey -pubin -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}'; }

case "${1:-}" in
    generate)
        key="${2:-${DEFAULT_KEY}}"
        [[ -e "${key}" ]] && die "${key} already exists; refusing to overwrite a release key"
        mkdir -p "$(dirname "${key}")"
        chmod 700 "$(dirname "${key}")"
        ( umask 077 && "${OPENSSL}" ecparam -name prime256v1 -genkey -noout -out "${key}" )
        chmod 600 "${key}"
        printf 'Private key: %s (mode 600). Back it up offline.\n\n' "${key}"
        printf 'Pin this in Scripts/install.sh as CHECKSUM_PUBLIC_KEY_PEM:\n\n'
        public_pem "${key}"
        printf '\nSHA-256 fingerprint for README.md: %s\n' "$(fingerprint "${key}")"
        ;;
    public)
        key="${2:-${DEFAULT_KEY}}"
        [[ -f "${key}" ]] || die "no key at ${key}"
        public_pem "${key}"
        printf 'SHA-256 fingerprint: %s\n' "$(fingerprint "${key}")"
        ;;
    sign)
        sums="${2:-}"; key="${3:-${DEFAULT_KEY}}"
        [[ -f "${sums}" ]] || die "usage: sign SHA256SUMS.txt [KEYFILE]"
        [[ -f "${key}" ]] || die "no key at ${key}"
        "${OPENSSL}" dgst -sha256 -sign "${key}" -out "${sums}.sig" "${sums}"
        "${OPENSSL}" dgst -sha256 -verify <(public_pem "${key}") -signature "${sums}.sig" "${sums}" >/dev/null \
            || die "the signature just written does not verify"
        printf 'Wrote %s.sig — upload it with the release, beside %s.\n' "${sums}" "$(basename "${sums}")"
        ;;
    selftest)
        work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
        # install.sh's own verifier, lifted out of the script so the test runs the shipping code.
        eval "$(sed -n '/^verify_signed_checksums() {/,/^}/p' "${ROOT}/Scripts/install.sh")"
        declare -F verify_signed_checksums >/dev/null || die "install.sh has no verify_signed_checksums()"
        "${OPENSSL}" ecparam -name prime256v1 -genkey -noout -out "${work}/k.pem" 2>/dev/null
        "${OPENSSL}" ecparam -name prime256v1 -genkey -noout -out "${work}/other.pem" 2>/dev/null
        printf 'f40b662c0000000000000000000000000000000000000000000000000000abcd  ZenitPDF-1.0.1-universal.dmg\n' > "${work}/SHA256SUMS.txt"
        "${OPENSSL}" dgst -sha256 -sign "${work}/k.pem" -out "${work}/SHA256SUMS.txt.sig" "${work}/SHA256SUMS.txt"
        pem="$(public_pem "${work}/k.pem")"
        verify_signed_checksums "${pem}" "${work}/SHA256SUMS.txt" "${work}/SHA256SUMS.txt.sig" \
            && echo "  ok: a correctly signed checksum file is accepted" || die "a good signature was refused"
        sed 's/abcd/abce/' "${work}/SHA256SUMS.txt" > "${work}/tampered.txt"
        if verify_signed_checksums "${pem}" "${work}/tampered.txt" "${work}/SHA256SUMS.txt.sig"; then
            die "a tampered checksum file was accepted"
        fi
        echo "  ok: a checksum file edited by one character is REFUSED"
        if verify_signed_checksums "$(public_pem "${work}/other.pem")" "${work}/SHA256SUMS.txt" "${work}/SHA256SUMS.txt.sig"; then
            die "another key's public half accepted the signature"
        fi
        echo "  ok: a signature checked against another key is REFUSED"
        if verify_signed_checksums "" "${work}/SHA256SUMS.txt" "${work}/SHA256SUMS.txt.sig"; then
            die "an empty pinned key verified something"
        fi
        echo "  ok: with no key pinned the verifier refuses rather than passes"
        echo "selftest passed (stock ${OPENSSL}: $("${OPENSSL}" version))"
        ;;
    *)
        sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
