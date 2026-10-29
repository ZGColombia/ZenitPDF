# ZPDFExport

Ledger CSV, XLSX, Zenit JSON, and PDF reports, plus PDF drawing export and signing/redaction support. Ledger exporters consume a common projection so grouping, units, values, and display precision remain consistent. XLSX writing uses the vendored native bridge. Annotated, layered, flattened, and clean outputs serve different editing and presentation needs.

## Development

From the repository root:

```sh
Scripts/verify-export.sh
```

This command covers the package's grouped validation tier. See [Tests](../../Tests/README.md)
for its exact scope and [Building](../../BUILDING.md) for prerequisites. Shared PDF fixtures
come from [ZPDFTestingSupport](../ZPDFTestingSupport/README.md).

See the [architecture map](../../Docs/Architecture/README.md) and
[quality requirements](../../Docs/Execution/QUALITY_BAR.md) for cross-package rules.
