# ZPDFMeasurementEngine

The calculation layer for calibrated length, area, cutout, volume, wall area, count, circular, angular, and slope tools. `MeasurementEngine.calculator(for:)` selects a calculator. Clipper2 handles polygon operations; overlapping cutouts are unioned before subtraction. Results carry warnings and formula versions. Invalid and non-finite geometry must produce explicit failures.

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
