# Zenit PDF

Construction takeoff and PDF markup for macOS 14 or later, on Apple silicon and Intel.
Open a drawing, calibrate its scale, measure quantities, and export a summary.

## Install

1. **Easiest: one line in Terminal.** Open the Terminal app (press Command-Space, type
   *Terminal*, press Return), paste this line and press Return:

   ```sh
   curl -fsSL https://github.com/ZGColombia/ZenitPDF/releases/latest/download/install.sh | bash
   ```

   It downloads the newest release, checks its SHA-256 checksum, and installs Zenit PDF into
   Applications so that it opens without a security prompt.
2. **Or download the disk image** (`ZenitPDF-<version>-universal.dmg`) from
   [GitHub Releases](https://github.com/ZGColombia/ZenitPDF/releases/latest), open it and drag
   **Zenit PDF** onto **Applications**.
3. **First launch from the disk image:** macOS asks you to confirm once, because the app is not
   notarized. On macOS 15 and 26, double-click the app, click **Done**, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**. On macOS 14,
   Control-click the app, choose **Open**, then click **Open**.

Step-by-step help, updating, uninstalling and troubleshooting: [Installing Zenit PDF](Docs/INSTALL.md).

Zenit PDF processes files locally. It makes no network connections, collects no telemetry,
and needs no account. The interface is English only; number formats follow your locale.
Published under the MIT license. Copyright ZENIT GROUP S.A.S.

## Update and uninstall

The app has no Developer ID signature and is not notarized, so a Gatekeeper prompt is
expected when it is opened from a downloaded disk image or zip. It has no update feature. To
update, run the install line above again, or quit the app and replace the installed copy with
the disk image of a new GitHub release. Back up your projects before moving to a newer version.
To remove the app and its settings, see [Uninstalling](Docs/INSTALL.md#uninstalling).
There is no published Homebrew cask yet; [Packaging/homebrew](Packaging/homebrew) holds a
template for one.

## Work with a drawing

1. Open a PDF, or import an image or DXF drawing.
2. Calibrate a known distance and check the page's units. Use Scale Regions when a sheet
   contains details at different scales.
3. Measure on the canvas and review the resulting rows in the Quantity Ledger.
4. Save a `.zpdfproj` project, then export the quantities or marked drawing you need.

## Features

- Length, polylength, perimeter, area, rectangle and ellipse area, cutouts, volume,
  wall area, count, radius, diameter, circle, angle, slope, rise/drop, sloped quantities,
  arc length, dimensions, and temporary measurements.
- Vector Snap and markup snapping, scale calibration, scale regions, and measurement provenance.
- A Quantity Ledger with grouping, filtering, formulas, custom columns, estimating fields,
  assemblies, and XLSX spreadsheet round-trip review.
- Text and drawing markups, stamps, tool presets, layers, review threads, photo attachments,
  and review files in a shared folder you choose.
- Multi-drawing projects, text search and on-device OCR, Revision Compare, Revision Overlay,
  and Split Canvas.
- CSV, XLSX, Zenit JSON, PDF reports, annotated/marked/layered/clean PDFs, and PNG snippets.
  Export choices preserve different kinds of editability; review the selected output mode.
- Finder thumbnails and Quick Look previews for saved projects; Shortcuts actions to open
  a drawing or project, get ledger totals, and export the ledger.
- A read-only [command-line tool](Tools/ZenitCLI/README.md) for project information,
  verification, totals, and export.

## Limitations

Recognition of symbols, rooms, and scales is heuristic and needs review. Imported vector
stamps have limited color fidelity (strokes use the stamp ink); raster stamps use a bounded mosaic. Digital
signatures have no trusted RFC 3161 timestamp. Deleting a markup retains its photo attachments,
which continue to occupy storage. There is no iPad app or EPUB support. The app is not notarized.
See [known limitations](Docs/KNOWN_LIMITATIONS.md) for details.

## Build and contribute

A full Xcode 27.1 installation and Swift 6 are required for bundle assembly. The first build
needs network access to fetch GRDB through SwiftPM. Anyone can build an ad-hoc-signed app
without a certificate; see [Building](BUILDING.md) and [Toolchain](TOOLCHAIN.md).
Tests use generated synthetic fixtures; no private drawings are required or published.

- [Contributing](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md)
- [Architecture](Docs/Architecture/README.md), [packages](Packages/README.md), and [tests](Tests/README.md)
- [Project and interchange formats](Docs/Formats/zpdfproj.md)
- [Privacy](Docs/Legal/PRIVACY.md) and [security reporting](SECURITY.md)
- [Changelog](CHANGELOG.md), [license](LICENSE), and [third-party notices](THIRD-PARTY-NOTICES.md)
