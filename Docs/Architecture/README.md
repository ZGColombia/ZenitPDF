# Architecture

Zenit PDF is a Swift 6 macOS application with AppKit composition and independently testable
SwiftPM packages. The package manifests are the dependency graph; the map below describes
responsibilities rather than every transitive dependency.

```text
Apps/ZenitPDF (AppKit documents, windows, menus, platform integration)
    ├── ZPDFUIShell / ZPDFUIWorkflows / ZPDFUIMeasurement / ZPDFUILedger
    │       └── ZPDFDesignSystem + ZPDFUIPresentation protocols and values
    └── ZPDFAppCore (presenters, TakeoffSession, workflow coordination)
            ├── ZPDFContracts
            ├── Geometry / MeasurementEngine / SnapEngine / FormulaEngine / QuantityLedger
            ├── PDFKitBridge / Renderer / Search / Compare
            └── Persistence / Export / ServiceClient
```

## Presentation and calculation

`ZPDFUIPresentation` supplies view-facing values and presenter protocols. `ZPDFAppCore`
adapts engine state into those protocols. `TakeoffSession` coordinates measurement state,
scales, markups, snapping, and ledger projections. Views request actions instead of defining
measurement arithmetic. Geometry uses `Double`; ledger aggregation uses `Decimal`, with
rounding at display/export boundaries. Contracts define units, dimensions, provenance,
validation, and interchange semantics.

Code, tests and [`Docs/Contracts`](../Contracts/) carry labels such as `spec 10.4` (also written
`spec §10.4`, and listed in each contract's `specSections`), a section number after an ADR
number (`ADR-0030 §5.6`), and feature numbers such as `feature 16`. They point to the project's original internal
product specification, its roadmap and the long-form decision records, none of which is
published; the [ADRs](ADR/) in this repository have no numbered sections. The labels are kept as
stable traceability labels. Each contract invariant is stated in full in the contract itself,
and the published ADR with the same number records the decision.

## Persistence and export

`ZPDFPersistence` uses GRDB/SQLite inside a `.zpdfproj` package, with integrity records,
versioned migrations, recovery data, and durable save operations. The source drawing and
working copy have separate roles. [Format documentation](../Formats/zpdfproj.md) describes
what is public and what remains an internal storage schema.

`ZPDFExport` writes ledger CSV, XLSX, JSON, and PDF reports, and drawing outputs.
`ZPDFSpreadsheet` reads XLSX workbooks with row identity for reconciliation. Import Spreadsheet
Changes reviews editable text, estimating, and custom text/currency cells as an undoable change;
measured or computed quantities cannot be replaced by typing over a workbook cell. `ZPDFRenderer` supplies shared
markup scenes. Native bridges provide polygon operations, XLSX writing, and service-side
PDF repair; see [Bridges](../../Bridges/README.md).

## Parser and process boundaries

| Work | Runtime boundary in an assembled app |
|---|---|
| PDF open, rendering, text/outline/annotation access through PDFKit and Core Graphics | In the main application process |
| Image decoding, spreadsheet parsing, project metadata/database access | In the main application process |
| Pure Swift PDF object/stream parsing used by export, signing, and redaction | In the main application process |
| Vector extraction, DXF conversion, revision comparison | `GeometryService.xpc` through `ZPDFServiceClient`/`ZPDFServiceWire` |
| qpdf inspection and repair | `RepairService.xpc`; native parser linked into the service |
| Finder thumbnail/preview generation | Quick Look extension processes |
| Project inspection and ledger export by the `zenit` command-line tool | Its own unsandboxed process in the user's Terminal session |

XPC requests pass bounded data and file access rather than unrestricted document paths.
Some geometry operations have in-process development fallbacks when no service bundle is
available. A SwiftPM test or `swift run` session is therefore not equivalent to the assembled
app's isolation. Sandboxing is a defense boundary, not a claim that all parsing is isolated.
See [Security boundaries](../Execution/FINAL_SECURITY_REPORT.md).

## Command line and system integration

[ZenitCLI](../../Tools/ZenitCLI/README.md) reads a private working copy of a project to
verify it, report information/totals, and export ledger data without modifying the source package.
The assembled app includes the `zenit` executable in `Contents/Helpers`. It is signed with
Hardened Runtime and no entitlements and runs unsandboxed in the user's Terminal session, on the
paths it is given.

`Apps/QuickLookThumbnail` supplies thumbnail and preview extension targets. Saved thumbnails
and summaries are preferred; thumbnail fallback can render a drawing's first page in the
extension's process. Shortcuts/App Intents expose Open Drawing or Project, Get Totals,
and Export Quantity Ledger; the app build extracts the required metadata.

The application has no network connections or update feature. Shared Review exchanges files
in a user-chosen folder; transport by a separate file-sharing service is outside the app.

## Further reading

- [Packages](../../Packages/README.md) and [Applications](../../Apps/README.md)
- [Build instructions](../../BUILDING.md) and [test tiers](../../Tests/README.md)
- [Core workflow](../Design/CORE_LOOP.md) and [quality requirements](../Execution/QUALITY_BAR.md)
- [Architecture decisions](ADR/ADR-0005-multiplatform-boundary.md): decisions remain historical
  records; amendments identify the portions they replace.
