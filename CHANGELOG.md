# Changelog

## 1.0.2

### Fixes

- Zenit PDF no longer quits unexpectedly at launch or when File ▸ Open Recent opens. When two
  recent files shared a name, the app adjusted the spacing of their rows while macOS was still
  updating them, and the app crashed — on macOS 26 a few seconds after launch, where the system
  reads the menus without anyone opening them. The rows are now adjusted only while the menu
  bar is open, after macOS has finished with them.

### Development

- `Scripts/verify-app-launches.sh` unregisters the build product from LaunchServices when it
  ends, so a development build no longer shows up as a second Zenit PDF in Open With.

## 1.0.1

### Fixes

- Text recognition falls back when macOS cannot run accurate recognition. On macOS versions
  where Vision's accurate text recogniser fails, Read Text from Scanned Pages, Process PDF Files,
  sheet naming from scanned title blocks, and region reads try the previous accurate recogniser
  and then the fast one, instead of reading nothing. On a Mac where accurate recognition works,
  nothing changes. Each failed attempt is logged with its error domain and code, never with page
  text or file names.
- A page macOS could not read is shown as such. Read Text from Scanned Pages marks it
  *Could not be read* instead of *No text found*, counts such pages in its summary, says so in
  its closing line, keeps any text an earlier run recognised on them, and Process PDF Files
  retries the file on the next run. A page skipped because it already has text is labelled
  *Skipped — already has text* instead of *No text found*.
- An inserted image no longer stays a coarse mosaic. When the canvas redrew while it was still
  reading the picture's pixels, it treated the interrupted read as "no pixels" and drew the
  image as its low-resolution preview until the window was reopened; stamp and count-mark
  artwork could likewise stay a fallback glyph. The next redraw now reads it again.
- Dragging a revision overlay's opacity slider no longer asks for the same composite twice.
  On a busy Mac a delayed update could repeat the value just sent, so the overlay redrew more
  often than once per interval.

### Development

- The app and UI test suites pass on GitHub's macOS 27 runner as well as on a Mac. Tests that
  sampled pixels, measured windows or hit-tested views now pin the appearance, backing scale,
  colour space and scroller style they assert on, or measure against the screen they run on;
  the project-open tests run against the shipping document controller; the outline-title
  fixture is written byte for byte instead of through PDFKit, whose macOS 27 writer drops an
  outline set on a document opened from a file; and the storage-ordering tests hold the write
  open with a gate instead of polling a transient state.

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
  for macOS 14 and for macOS 15 and later. Each release also ships a zip of the app, and
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
