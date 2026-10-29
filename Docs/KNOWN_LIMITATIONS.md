# Known limitations

- **Recognition needs review.** Symbol matching, room detection, and scale recognition use
  heuristics. Confirm proposed counts, boundaries, units, and scales before accepting quantities.
- **Vector stamp color fidelity is limited.** Single-ink stamps adopt their source ink and can
  be recolored. Multiple fill colors may be retained, but strokes use the stamp color. Import
  does not preserve every source color space or PDF appearance feature.
- **Raster stamps use a bounded mosaic.** Fine details may be simplified when a raster image
  is used as stamp artwork or a count symbol. This is distinct from Insert Image, which draws
  decoded source pixels subject to image-size limits and uses the mosaic as a fallback.
- **Signatures have no RFC 3161 timestamp.** Signing uses a local certificate without a
  timestamp service; a displayed signing time is not a trusted external timestamp.
- **Deleting a markup retains its photos.** Attachments remain in project storage and count
  toward its storage budget. Removing a markup is not a photo-cleanup operation.
- **English interface only.** Numeric formatting follows the user's locale.
- **macOS only.** There is no iPad version. Portable engine targets do not imply a mobile app.
- **No Homebrew cask.** Install from a GitHub release or build from source.
- **No EPUB input.** DWG is also not read directly; request a PDF or DXF export.
- **Not notarized.** There is no Developer ID signature. On macOS 15 and later, right-click →
  Open no longer bypasses Gatekeeper: try to open the app once, then use System Settings →
  Privacy & Security → Open Anyway. On macOS 14, right-click → Open still works. See
  [Installing](INSTALL.md#opening-zenit-pdf-the-first-time).
- **Manual updates.** The application has no update feature and makes no network connections.
  Download a new release from GitHub to update.
- **Renderer benchmark.** GPU p99 at 100 000 markups / 5 % zoom reads 20–22 ms in the gate's
  unpaced benchmark (frames submitted far faster than the display, up to eight in flight, 15
  samples); a display-paced p99 has not been measured; the gate asserts GPU p50.

These limits describe product behavior, not a claim that every input file has been tested.
See [Building](../BUILDING.md) for prerequisites and [Security](../SECURITY.md) for reporting.
