# ADR-0028 — Local PDF signatures and visible seals

Status: Accepted; the original copy-only and PKCS #7-only restrictions are superseded by the extensions recorded here.

## Decision and rationale

Sign incrementally: append a signature dictionary, fixed-width byte ranges and signature widget while retaining the source prefix. The writer receives a signing closure and never owns a private key.

The app selects a local keychain identity. PAdES baseline B-B uses CAdES detached data with SHA-256, content-type, message-digest and signing-certificate-v2 attributes. The keychain performs RSA or ECDSA signing. PKCS #7 detached remains available for older readers. A visible seal is a printable widget appearance covered by the signature.

Quick PDF Mode may sign the original only after explicit confirmation and a prefix-identity check; write atomically. Project Mode signs a copy because its source drawing is evidence. The signature inspector reports integrity and later revisions separately from trust.

No RFC 3161 timestamp or online revocation lookup is performed. Trust evaluation disables network fetching. Tests use disposable generated identities. This document-signing feature is separate from app bundle signing described in [Distribution](../../Release/DISTRIBUTION.md).
