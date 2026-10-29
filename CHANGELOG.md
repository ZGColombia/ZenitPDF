# Changelog

## 1.0.0

Initial public release of Zenit PDF for macOS 14 and later, under the MIT license.
Copyright ZENIT GROUP S.A.S.

### Features

- PDF construction takeoff with calibrated scales, scale regions, vector and markup snapping,
  linear/area/volume/count tools, sloped quantities, and measurement history.
- Quantity Ledger grouping, formulas, custom columns, estimating fields, assemblies,
  spreadsheet reconciliation, and CSV, XLSX, JSON, and PDF report exports.
- Markups, stamps, layers, tool presets, photo attachments, and folder-based review.
- Multi-drawing projects, revision comparison and overlay, local OCR/search, image and DXF intake.
- Annotated, marked, layered, and clean PDF outputs, plus PNG snippets.
- Project packages, Quick Look thumbnails/previews, Shortcuts actions, and a read-only CLI.
- Universal Apple silicon and Intel app assembly; certificate-free ad-hoc builds.

### Installation

- One-line installer, attached to every release as `install.sh`:
  `curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash`.
  It checks macOS 14 or later, verifies the disk image's SHA-256 against the release's
  `SHA256SUMS.txt` and refuses a mismatch, installs into Applications (or the user's own
  Applications folder when the account may not write there), asks before quitting an open copy,
  and clears the quarantine flag on the installed app only. `--version`, `--dest`, `--dmg`,
  `--dry-run`.
- The disk image carries a *How to open Zenit PDF the first time* note with the Gatekeeper steps
  for macOS 14 and for macOS 15 and 26. Each release also ships a zip of the app, and
  `SHA256SUMS.txt` covers both.
- `uninstall.sh` is attached to every release, refuses while the app is open, and removes a copy
  in another folder with `--app`. See [Installing Zenit PDF](Docs/INSTALL.md).

### Limitations

Recognition requires review. Stamp artwork has limited vector-color fidelity and bounded raster-mosaic
limits. Signatures have no RFC 3161 timestamp. Photo attachments survive markup deletion.
The interface is English only. There is no iPad app, Homebrew cask, or EPUB support.
The app is not notarized. See [Known limitations](Docs/KNOWN_LIMITATIONS.md).

The application has no update feature or network connections. New versions are installed
from GitHub Releases, by running the one-line installer again or downloading the new disk image.
