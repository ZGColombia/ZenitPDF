# ZPDFQuantityLedger

Aggregation, grouping, filtering, sorting, and reports for measurement rows and derived/read rows. Totals use exact `Decimal` arithmetic and dimension checks; display rounding must not feed back into stored values. Dependencies are contracts and the formula engine, with no AppKit UI dependency.

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
