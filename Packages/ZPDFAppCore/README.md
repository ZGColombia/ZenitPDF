# ZPDFAppCore

Engine-backed presentation and workflow coordination. `TakeoffSession` is the actor coordinating measurement, scales, markups, snapping, and ledger state; presenters expose that state through `ZPDFUIPresentation`. The app tier supplies document and platform integration.

## Development

From the repository root:

```sh
Scripts/build-appcore-package.sh
```

This command covers the package's grouped validation tier. See [Tests](../../Tests/README.md)
for its exact scope and [Building](../../BUILDING.md) for prerequisites. Shared PDF fixtures
come from [ZPDFTestingSupport](../ZPDFTestingSupport/README.md).

See the [architecture map](../../Docs/Architecture/README.md) and
[quality requirements](../../Docs/Execution/QUALITY_BAR.md) for cross-package rules.
