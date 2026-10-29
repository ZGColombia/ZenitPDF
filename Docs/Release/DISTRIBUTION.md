# Distribution

Zenit PDF is distributed through GitHub Releases under MIT, copyright ZENIT GROUP S.A.S.
The application has no update feature and makes no network connections. Users install a
new version by downloading a release and replacing the installed app.

## Build and signing modes

Follow [Building](../../BUILDING.md) with a full Xcode 27.1 installation.

By default `Scripts/build-app.sh` produces an ad-hoc-signed universal app without requiring a
certificate, with the explicit designated requirement `identifier "com.zenitgroup.zenitpdf"`
so that consecutive builds keep one code identity. Release certificate checks must not block
this mode.

**Published releases take one path only:** `.github/workflows/release.yml`, which builds in
this default ad-hoc mode (`ZENIT_RELEASE_SIGNING` is `0` in the workflow). A sandboxed app's
container and its security-scoped bookmarks are tied to the designated requirement, so a
release signed in the other mode would change it, and every installed copy would ask once
whether to open a version that "differs from previously opened versions". The two modes are
therefore never mixed in published releases.

The self-signed certificate mode remains a maintainer option for local builds; it is never used
for published releases:

```sh
ZENIT_RELEASE_SIGNING=1 Scripts/build-app.sh --short-version 1.0.0 --build-version 1
```

The version arguments are examples, not a claim that a release exists. This mode signs with the
keychain identity "Zenit PDF Code Signing (self-signed)" that `Scripts/make-signing-identity.sh`
creates, or with `ZENIT_CODESIGN_IDENTITY`, and stops when neither is available. Never publish
its private key. The pin in `Apps/ZenitPDF/Bundle/DesignatedRequirement.txt` is enforced only
with `ZENIT_RELEASE_SIGNING=1`.

Neither signing mode uses Developer ID or notarization. A valid local code signature attaches
entitlements and detects modifications; it does not imply Gatekeeper approval.

## Prepare artifacts

The release workflow builds and packages the published assets itself. These steps produce the
same artifacts locally, to check a release candidate before its tag is pushed:

1. Run the appropriate [package and bundle checks](../../Tests/README.md) on the release
   candidate. Record actual results and any unresolved checks against its source revision.
2. Build the universal application with `Scripts/build-app.sh` in the default ad-hoc mode, as
   the release workflow does; do not set `ZENIT_RELEASE_SIGNING=1`. Do not use `--skip-verify`
   for a release candidate accepted for publication.
3. Package the exact checked app:

   ```sh
   Scripts/make-dmg.sh "build/Zenit PDF.app" dist
   ```

   This writes three files to `dist/`:

   | File | Contents |
   | --- | --- |
   | `ZenitPDF-<version>-universal.dmg` | the app, an Applications shortcut, and the note *How to open Zenit PDF the first time* |
   | `ZenitPDF-<version>-universal.zip` | the app alone |
   | `SHA256SUMS.txt` | one `shasum -a 256` line for each of the two files above |

4. Retain the three files together. Check them against the checksum file from the same
   release, from the directory containing them:

   ```sh
   shasum -a 256 -c SHA256SUMS.txt
   ```

The packaging script checks the app signature, generates the first-launch note from text in the
script, creates a compressed image, mounts it read-only to confirm that it contains exactly the
app, the shortcut and the note and that the app's signature still verifies, zips the app and
verifies the unpacked copy the same way, and writes the checksums. It needs no Finder and opens
no window. Finder window arrangement is optional (`SKIP_LAYOUT=0`) and no custom layout is
promised; there is no background image.
Disk images contain timestamps and are not byte-reproducible. Checksums provide artifact
integrity, not proof of a reproducible build or identity by themselves.

## Publish on GitHub

A release carries five assets with exactly these names, because the one-line installer finds
them by name:

| Asset | Source |
| --- | --- |
| `ZenitPDF-<version>-universal.dmg` | `Scripts/make-dmg.sh` |
| `ZenitPDF-<version>-universal.zip` | `Scripts/make-dmg.sh` |
| `SHA256SUMS.txt` | `Scripts/make-dmg.sh` |
| `install.sh` | `Scripts/install.sh` |
| `uninstall.sh` | `Scripts/uninstall.sh` |

The public one-liner is
`curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash`.
GitHub serves `releases/latest/download/<name>` from the newest release that is not a
pre-release, so that release must carry `install.sh`; the installer then reads
`SHA256SUMS.txt` from the same tag, picks the `ZenitPDF-<version>-universal.dmg` line for that
tag (falling back to the first `-universal.dmg` line), and refuses a disk image whose SHA-256
differs.

**The release workflow (ad-hoc signed).** Pushing a `vX.Y.Z` tag runs
`.github/workflows/release.yml`. It validates the tag, requires a line that reads exactly
`## X.Y.Z` in `CHANGELOG.md` (suffix included for a pre-release, `## 1.2.0-beta.1`), builds with the pinned Xcode and `--short-version X.Y.Z`, checks
that the bundle's `CFBundleShortVersionString` equals the tag and that the app is Universal 2,
packages, installs the new disk image with `install.sh --dmg` into a temporary folder
(signature and quarantine checked), proves a tampered checksum list is refused, attests
provenance of the disk image and the zip, and publishes the five assets with installation
notes that link `CHANGELOG.md` and `Docs/KNOWN_LIMITATIONS.md` at the tag. The attached
`install.sh` and `uninstall.sh` name the publishing repository. A tag with
a suffix (`v1.2.0-beta.1`) becomes a pre-release, whose notes point the one-liner at that tag
with `--version`. A manual run (`workflow_dispatch`) does everything except the changelog check,
the attestation and publishing. The release workflow uses no repository secrets; the CI
workflow reads one. Before the first push, create the `ZENIT_SCRUB_NAMES` repository secret (Settings > Secrets and
variables > Actions) holding the names the author scrub must keep out of the repository; on
ZGColombia/ZenitPDF the CI author-scrub job fails without it. If Dependabot is ever enabled, its
runs skip that check.

This workflow is the only way a release is published. Do not create a release for a version
tag by hand: the workflow publishes to that tag itself with `gh release create`, which fails
when a release for the tag already exists, and a hand-built certificate-signed app would change
the designated requirement for every installed copy.

The release notes link `CHANGELOG.md` and `Docs/KNOWN_LIMITATIONS.md` as they are at the tag,
so describe changes and known limitations there before tagging. Include the license and all
required upstream notices in the distributed bundle. Consult
[Third-party notices](../../THIRD-PARTY-NOTICES.md) and the
[shipped inventory](../Licences/SHIPPED_NOTICES.tsv).

Confirm the uploaded assets correspond to the checked bundle and the published checksum.
Keep previous release artifacts available so users can select a known version
(`install.sh --version X.Y.Z`); project schema migrations may prevent an older version from
opening a newer save, so recommend backups.

### Homebrew

`Packaging/homebrew/zenit-pdf.rb` is a cask template and `Scripts/update-cask.sh X.Y.Z` fills
in its version and checksum. No tap is published, so no user-facing document mentions Homebrew
as a way to install; [Packaging/homebrew/README.md](../../Packaging/homebrew/README.md) lists the
steps that change that.

### Verifiable only after the first public release

The repository was not public when this pipeline was written, so these have not run:
the release workflow on GitHub, the one-liner against `releases/latest/download/install.sh`,
`install.sh --version` and `--dry-run` against a real release, the `releases/latest` redirect the
installer reads the newest tag from, `gh attestation verify`, and the tap. The installer itself,
the disk image, the zip and the checksums were exercised locally against a built app
(2026-10-27).

## First-launch instructions

[Installing Zenit PDF](../INSTALL.md) is the user-facing guide, and the disk image's note and
the release notes repeat its steps. Explain neutrally that the app is not notarized. On macOS 15
and macOS 26, the first attempt is refused ("Zenit PDF" Not Opened, then **Done**), and
**System Settings > Privacy & Security > Open Anyway** followed by a confirmation opens it;
Control-click > Open no longer bypasses this. On macOS 14, Control-click > **Open** and then
**Open** in the confirmation works, with **Open Anyway** as the fallback. The one-line installer
avoids the prompt by clearing the quarantine flag after its checksum check. Do not ask users to
disable Gatekeeper globally. Updates are manual: run the installer again or download a new disk
image from GitHub Releases.
