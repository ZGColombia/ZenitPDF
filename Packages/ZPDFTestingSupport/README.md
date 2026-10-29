# ZPDFTestingSupport

Generated synthetic PDF fixtures and mutation support. `ZPDFFixtures` writes PDFs to a caller-supplied directory with a `FixtureManifest` describing the geometry and expected quantities. Fixtures cover known geometric cases and malformed inputs; private drawings are not required or published. Tests should use independent expected values rather than asking the implementation under test to generate its own oracle.

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
