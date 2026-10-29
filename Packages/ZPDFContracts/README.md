# ZPDFContracts

The domain vocabulary: geometry, scales, units, measurements, markups, ledger values, errors, and provenance. Geometry uses `Double`; aggregates use `Decimal`. Contracts are independent of AppKit and of concrete engine implementations. The freeze generator produces the committed JSON contract snapshots; changes require reviewing their compatibility.

## Development

From the repository root:

```sh
Scripts/build-core-packages.sh
```

This command covers the package's grouped validation tier. See [Tests](../../Tests/README.md)
for its exact scope and [Building](../../BUILDING.md) for prerequisites. Shared PDF fixtures
come from [ZPDFTestingSupport](../ZPDFTestingSupport/README.md).

See the [architecture map](../../Docs/Architecture/README.md) and
[quality requirements](../../Docs/Execution/QUALITY_BAR.md) for cross-package rules.
