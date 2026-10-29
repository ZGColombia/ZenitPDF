# Application targets

| Target | Responsibility |
|---|---|
| `ZenitPDF` | AppKit document app, menus/windows, canvas composition, platform workflows, and App Intents |
| `GeometryService` | Sandboxed XPC entry point for geometry extraction, DXF conversion, and comparison |
| `RepairService` | Sandboxed XPC entry point for qpdf inspection and repair |
| `QuickLookThumbnail` | Finder thumbnail and Quick Look preview extension targets for project packages |

[Building](../BUILDING.md) assembles the executable packages into a universal macOS app.
Building only the [app package](ZenitPDF/README.md) does not assemble the helper bundles,
resources, signatures, or App Intents metadata required by the distributed application.
See the [architecture map](../Docs/Architecture/README.md) for process boundaries and
[Tests](../Tests/README.md) for validation scopes.
