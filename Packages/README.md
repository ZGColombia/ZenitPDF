# Swift packages

Packages separate domain calculations, document processing, persistence, and presentation.
Read the [architecture map](../Docs/Architecture/README.md) before moving responsibilities
between them. Swift 6 is used throughout; macOS 14 is the app's deployment floor.

| Area | Packages |
|---|---|
| Domain vocabulary | `ZPDFContracts` |
| Quantities and formulas | `ZPDFGeometry`, `ZPDFMeasurementEngine`, `ZPDFFormulaEngine`, `ZPDFQuantityLedger` |
| Drawing interpretation | `ZPDFVectorExtraction`, `ZPDFSnapEngine`, `ZPDFPDFKitBridge`, `ZPDFSearch`, `ZPDFCompare`, `ZPDFMeasureDictionary`, `ZPDFRasterAnalysis` |
| Drawing and exchange | `ZPDFRenderer`, `ZPDFExport`, `ZPDFSpreadsheet`, `ZPDFDXF`, `ZPDFImageIntake`, `ZPDFExtensions` |
| Projects and services | `ZPDFPersistence`, `ZPDFServiceClient` (with its `ZPDFServiceWire` library), `ZPDFCollaboration` |
| Coordination | `ZPDFAppCore` |
| UI | `ZPDFUIPresentation`, `ZPDFDesignSystem`, `ZPDFCanvasCore`, `ZPDFUIMeasurement`, `ZPDFUILedger`, `ZPDFUIWorkflows`, `ZPDFUIShell` |
| Test data | `ZPDFTestingSupport` |

- `ZPDFMeasureDictionary` reads the scale a CAD program wrote into a PDF: the page's `/VP`
  viewports and their `/Measure` dictionaries, as metres per point.
- `ZPDFRasterAnalysis` recovers straight linework and finds boxed symbols on scanned sheets,
  on the Mac with no model; every result is a proposal marked as coming from the scan.
- `ZPDFExtensions` reads `.zpdfpack` files: zips of tool sets, job templates and export
  profiles with a `pack.json` manifest. Nothing in a pack executes.
- `ZPDFCanvasCore` holds the canvas arithmetic without AppKit: page-to-display transforms, zoom,
  viewport raster planning, and where value pills and dimension text sit.

The package manifests define exact dependencies. GRDB is fetched by SwiftPM for persistence;
first-time dependency resolution needs network access. Native bridges are vendored under
`Bridges/`. Some domain targets also compile for iOS, but no iPad app is shipped.

See [Building](../BUILDING.md) and [Tests](../Tests/README.md) for the grouped build/test scripts.
All shared PDF fixtures are generated synthetically, without private drawings.
