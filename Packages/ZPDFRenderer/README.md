# ZPDFRenderer

Shared markup scene compilation and Core Graphics/Metal rendering support. Core Graphics serves print, exported drawings, snippets, and image markup pixels. The app uses Metal for its vector underlay. Image shapes can be accepted by the Metal backend without painting their pixels; do not assume every backend renders every scene identically. See ADR-0043 for inserted image behavior.

## Development

From the repository root:

```sh
Scripts/build-renderer-package.sh
```

This command covers the package's grouped validation tier. See [Tests](../../Tests/README.md)
for its exact scope and [Building](../../BUILDING.md) for prerequisites. Shared PDF fixtures
come from [ZPDFTestingSupport](../ZPDFTestingSupport/README.md).

See the [architecture map](../../Docs/Architecture/README.md) and
[quality requirements](../../Docs/Execution/QUALITY_BAR.md) for cross-package rules.
