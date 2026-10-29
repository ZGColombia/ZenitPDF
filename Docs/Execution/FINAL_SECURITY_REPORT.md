# Security boundaries and review scope

This public report describes the security model and the areas requiring release verification.
It is not a certificate of safety or a claim that a current binary has passed a penetration test.
Historical execution logs are not used as evidence for a newer source revision.

## Parsing and input surfaces

| Surface | Process | Boundary |
|---|---|---|
| PDFKit/Core Graphics PDF opening, rendering, text, outlines, annotations, hazard inspection | Main app | App sandbox, bounded requests, exception handling |
| Pure Swift PDF object/stream parsing for redaction, signing, and export | Main app | Bounded nesting, object/stream sizes, and validation; not XPC isolation |
| Image intake, photo/artwork decoding | Main app | Header checks and size/pixel limits before decoding |
| Spreadsheet ZIP/XML input | Main app | Entry/size/inflation limits and disabled external entity resolution |
| Project metadata and SQLite storage | Main app | Package integrity, version checks, path/member validation, and schema handling |
| Vector extraction, DXF conversion, revision comparison | GeometryService in the assembled app | XPC requests, descriptor-based file access, bounded reply decoding, service sandbox |
| qpdf inspection and repair | RepairService | Native parser linked into the service; service sandbox |
| Project thumbnails and previews | Quick Look extension processes | Bounded regular-file reads; saved images/summaries preferred |
| `zenit` CLI: project manifest and integrity record, SQLite (GRDB), Core Graphics page reads | `zenit` process (`Contents/Helpers/zenit`), started by the user in Terminal | Unsandboxed; Hardened Runtime, no entitlements. Read-only open of a private working copy, the application's integrity and schema checks before numbers are reported (unless `--allow-unverified`), drawing paths confined to `documents/` |

Some geometry paths run in-process when no bundled service exists in a development/test run.
Do not infer the assembled bundle's isolation from a package test. PDFKit remains in the main
application even when both XPC services are present.

## Standing requirements

- Automatic updating has been removed. The application makes no network connections, collects no telemetry, and has no update feature.
- PDF JavaScript and launch actions are not executed by application workflows.
- Original drawing bytes have a separate role from working and exported copies. Explicit
  save/export operations must accurately describe which destination they change.
- Untrusted service replies, metadata, artwork, spreadsheets, and interchange formats must be
  validated before they become application state. Newer unsupported formats must be refused.
- User-selected shared folders contain review files; any external synchronization belongs to
  the user's storage service. No review server is part of the application.
- Secrets and release private keys must never enter the source tree or distribution artifacts.

## Important review areas

Project loading must validate integrity and coordinate-system/schema metadata. SQLite
connections must not trust document-supplied schema behavior; hostile triggers and corrupt
rows need explicit handling. Test recovery and durable saving with generated projects.

Descriptor access and reply validation narrow XPC exposure. Review service entitlements,
client identity checks, crash/retry behavior, and native dependency linkage in the assembled
bundle. Resource bounds reduce denial-of-service exposure but cannot make every document cheap
to parse. ImageIO and PDFKit processing still share the application's process resources.

Local document signatures have no RFC 3161 timestamp service. Local code signing of the app is
separate. Published releases are built by `.github/workflows/release.yml` and, like source
builds, are ad-hoc signed with the designated requirement `identifier "com.zenitgroup.zenitpdf"`,
which any ad-hoc-signed app claiming that identifier satisfies. The self-signed certificate
mode (`ZENIT_RELEASE_SIGNING=1`), which enforces the pin in
`Apps/ZenitPDF/Bundle/DesignatedRequirement.txt`, is a maintainer option that is never used
for published releases and never mixed with them: switching modes changes the designated
requirement, so every installed copy asks once whether to open a version that "differs from
previously opened versions". Neither mode uses Developer ID or notarization.

## Resolved findings

### S17-05 — URL-supplied file paths: fixed

`zenitpdf://open?path=…` is refused, and no file is opened. `ZenitURLRoute`
(in `Apps/ZenitPDF/Sources/ZenitPDFAppKit/App/ZenitURLRouter.swift`) classifies an `open` link
that names a path as a refused file request; the handler opens nothing and posts one status
note that names neither the path nor the file and points to File ▸ Open…. A plain
`zenitpdf://open` shows the Open panel, where the person chooses a file themselves. Nothing in
the product creates a path link: Shortcuts open drawings through `OpenDrawingIntent`, and the
command-line tool reads projects itself.

### S17-10 — vector codec caps looser than the extractor: fixed

The decoder of the geometry service's reply, `VectorExtractionCodec`, now refuses to decode more
than the extractor can produce. Its caps are the extractor's own ceilings in
`VectorExtractionBudget`: at most 2 000 000 primitives (`maximumPrimitiveCountCeiling`) and at
most 1 000 000 ring vertices (`maximumPointsPerSubpathCeiling`). They were 8 000 000 and
4 000 000, so a compromised service could make the application materialise four times the
largest legitimate page with every byte passing the caps. `CodecCapAlignmentTests` in
`ZPDFVectorExtraction` holds the two numbers equal.

### Other S17 findings: fixed

Code comments cite these identifiers where each fix is enforced.

| Finding | Where it is enforced | Tests that hold it |
|---|---|---|
| **S17-01** — the decoder of the geometry service's vector reply narrowed unbounded scalar fields with `Int(_:)`, so a hostile reply could trap the application instead of being refused | Every scalar a reply decoder reads is bounded before use: `VectorExtractionCodec` through `readBoundedInt`, and `RasterWireCodec` (`ZPDFServiceWire`) | `HostileCodecPayloadTests` (`ZPDFVectorExtraction`), `HostileRasterPayloadTests` (`ZPDFServiceClient`) |
| **S17-02** — Revision Compare parsed the compared PDF in the application process | The compared document's page boxes, page rasters and vector geometry are read in `GeometryService` through `ServiceBackedRevisionDocumentSource`; `RevisionComparator`'s initializer that took an in-process PDF provider is unavailable | `CompareIsolationTests` (`ZPDFServiceClient`), `IsolationContractTests` (`ZPDFCompare`) |
| **S17-03** — qpdf's C++ parser was statically linked into the application through the in-process repair fallback | `ZPDFServiceClient` does not depend on `ZPDFQPDF`; the fallback is injected through `RepairInProcessExecuting`, implemented only in `ZPDFRepairServiceCore`, which the application does not link | `QPDFLinkageTests` (`ZPDFServiceClient`) scans the emitted object files for qpdf symbols |
| **S17-06** — SQL stored in a project's schema could call non-innocuous SQLite functions | `PRAGMA trusted_schema = OFF` on every connection, probes included (`DatabaseTuning.applyUntrustedSchemaPragmas`), and the open path measures the setting | `HostileProjectPackageTests` (`ZPDFPersistence`) |
| **S17-07** — `integrity.json` was read on open but never checked | The package is verified against its integrity record on the open path, before SQLite opens the file for writing; a read-write open refuses a mismatch with a typed error naming the member, unless it is damage in a package carrying crash evidence, which recovery handles; a read-only open records the verdict (`ProjectPackage+Integrity.swift`) | `HostilePackageTests` (`ZPDFPersistence`) |
| **S17-08** — the manifest's `coordinateSystem` was never compared | An unknown coordinate system is refused in `ProjectManifest.assertReadable()` | `HostilePackageTests` (`ZPDFPersistence`) |
| **S17-09** — a project database could carry foreign triggers, views or other schema objects that ran inside the application's transactions | `ProjectSchemaInventory` compares the schema with exactly what the migrations create; a deviation is refused on a read-write open and recorded on a read-only open | `HostilePackageTests`, `HostileProjectPackageTests` (`ZPDFPersistence`) |

## Verification references

[Tests](../../Tests/README.md) describes package, malformed-input, linkage, launch, and bundle
checks. [Architecture](../Architecture/README.md) maps the process boundaries.
[SECURITY](../../SECURITY.md) provides private reporting instructions.
[Distribution](../Release/DISTRIBUTION.md) describes release artifacts and checksums.

Reading these boundaries does not verify a built artifact. Record checks against the exact
release candidate and report any unrun or blocked checks explicitly.
