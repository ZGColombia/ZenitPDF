# Native bridges

Swift-facing packages wrap a small set of vendored native libraries.

| Bridge | Purpose | License and source record |
|---|---|---|
| QPDFBridge | PDF inspection and repair in RepairService | Apache-2.0; [VENDORED](QPDFBridge/VENDORED.md) |
| LibXlsxWriterBridge | XLSX output | BSD-2-Clause plus embedded notices; [VENDORED](LibXlsxWriterBridge/VENDORED.md) |
| Clipper2Bridge | Polygon operations for geometry and cutouts | BSL-1.0; [VENDORED](Clipper2Bridge/VENDORED.md) |

Keep patches and build exclusions documented alongside the vendored sources. Preserve the
upstream notices in [THIRD-PARTY-NOTICES](../THIRD-PARTY-NOTICES.md) and bundle resources.
[Tests](../Tests/README.md) describes bridge checks; [Architecture](../Docs/Architecture/README.md)
describes why qpdf belongs in the repair service rather than the main app.
