# ZPDFPDFKitBridge

PDFKit and Core Graphics access behind document-provider abstractions: opening, metadata, page rendering, text, thumbnails, outlines, annotation inspection, and document hazards. This library runs in its caller’s process; ordinary app PDF opening/rendering is in-process. A protocol boundary is not a sandbox boundary.

## Development

From the repository root:

```sh
Scripts/build-io-packages.sh
```

This command covers the package's grouped validation tier. See [Tests](../../Tests/README.md)
for its exact scope and [Building](../../BUILDING.md) for prerequisites. Shared PDF fixtures
come from [ZPDFTestingSupport](../ZPDFTestingSupport/README.md).

See the [architecture map](../../Docs/Architecture/README.md) and
[quality requirements](../../Docs/Execution/QUALITY_BAR.md) for cross-package rules.
