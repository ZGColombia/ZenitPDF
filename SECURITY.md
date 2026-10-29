# Security

## Report a vulnerability

Email [info@zenitgroup.com.co](mailto:info@zenitgroup.com.co) with “Zenit PDF security” in the
subject. Include the affected version, a concise impact description, and reproducible steps
using synthetic files where possible. Do not publish exploit details or private drawings in a
public issue. Coordinate disclosure through the same address; no fixed response time is promised.

Security fixes are developed against the current code and published in new GitHub releases.
There is no automatic update mechanism; users download and install a newer release themselves.

## Processing boundaries

The app processes data locally, makes no network connections, and collects no telemetry.
Shared Review uses files in a user-chosen folder. A separate sync or file-sharing service may
transport that folder's contents under the user's configuration; Zenit PDF provides no server.
See [Privacy](Docs/Legal/PRIVACY.md).

PDFKit/Core Graphics open, render, and extract text from PDFs in the application process.
They are not isolated behind the geometry service. The bundled GeometryService handles
vector extraction, DXF conversion, and revision comparison through XPC. RepairService runs
qpdf work in a separate process. Source-only development paths can differ from the assembled
bundle. See the [architecture map](Docs/Architecture/README.md) and
[security boundary report](Docs/Execution/FINAL_SECURITY_REPORT.md).

The app, its two XPC services and its two Quick Look extensions are code-signed with Hardened
Runtime and run in the App Sandbox. The optional `zenit` command-line tool
(`Contents/Helpers/zenit`) is code-signed with Hardened Runtime and no entitlements, and runs
unsandboxed in the user's own Terminal session, on the paths it is given; it reads a project
through a private working copy and leaves the source package unchanged. Sandboxing and signing
reduce exposure; they are not proof that a hostile document is harmless. Resource limits and
malformed-input checks remain necessary. PDF JavaScript and launch actions are not executed by
application features.

## Distribution

Published releases are built from a version tag by `.github/workflows/release.yml` and are
ad-hoc signed, without a certificate, with the designated requirement
`identifier "com.zenitgroup.zenitpdf"`. A build from source is signed the same way. Any
ad-hoc-signed app that claims that identifier satisfies the requirement, so the signature does
not identify who built a copy; the release workflow records a build provenance attestation for
the disk image and the zip, which `gh attestation verify --repo` checks against this
repository; its output names the workflow and tag that produced them. A self-signed
certificate mode (`ZENIT_RELEASE_SIGNING=1`) remains a maintainer option for local builds and is
never used for published releases: switching modes changes the designated requirement, and
every installed copy then asks once whether to open a version that "differs from previously
opened versions".

Neither mode uses Developer ID or notarization, so Gatekeeper asks for confirmation on first
launch. On macOS 15 and later, right-click → Open no longer bypasses the block: try to open the
app once, then use System Settings → Privacy & Security → Open Anyway. On macOS 14, right-click
→ Open still works. [Installing](Docs/INSTALL.md#opening-zenit-pdf-the-first-time) gives the
exact steps for each version.

[Distribution](Docs/Release/DISTRIBUTION.md) describes release checks and checksums.
Checksums detect a changed download; they do not establish reproducible-build provenance.
