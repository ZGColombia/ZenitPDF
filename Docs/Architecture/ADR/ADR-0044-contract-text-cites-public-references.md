# ADR-0044 — Frozen contract text states its own rules

Status: Accepted.

## Decision and rationale

The frozen contracts state every rule in their own human-readable strings — type summaries, field invariants and document invariants. Besides that text, a string cites only an ADR, a section or criterion ID of the published [quality requirements](../../Execution/QUALITY_BAR.md) (`QUALITY_BAR 2.5`, `QUALITY_BAR P11`), a section label of the original product specification (the numbering every contract's `specSections` list uses), or a bug or work-item identifier. The specification, and the long-form decision records that a section number after an ADR number (`ADR-0007 §5`) refers to, are not published: those labels are kept for traceability only, as the [architecture overview](../README.md) explains, and no string needs the cited text to be read. A string never cites any other development document, a working-session tag or an internal plan. Where a string cited such material, it now states the rule itself or cites the ADR that records it.

This is a text-only re-freeze, made for publication. Six strings changed, all in the Swift catalogue under `Packages/ZPDFContracts/Sources/ZPDFContracts/Freeze/`:

- `MARKUP_CONTRACT` — `MarkupRecord.stamp` invariant and the stamp-field document invariant now cite ADR-0010 alone; the stamp rule (fields resolved once at placement, frozen, never re-resolved on read) is unchanged and was already stated in the text.
- `MARKUP_CONTRACT` — `MarkupRecord.symbol` invariant cites spec 12.13, the numbering `MEASUREMENT_CONTRACT.specSections` and `ContractVersion.markup` already use, together with ADR-0011.
- `MARKUP_CONTRACT` — the `StampArtworkKind` summary drops its citation; the sentence and the type's invariant state the rule. The `StampFieldKind` summary cites ADR-0010.
- `MEASUREMENT_CONTRACT` — the `MeasurementProvenance.layerName` invariant drops a working-session tag; it still cites ADR-0007 §5.

The Swift documentation of `ContractDocument.specSections` now calls them specification sections. Documentation comments are not part of the freeze output.

`Docs/Contracts/*.json` was regenerated from the catalogue with the committed `frozenAt` (`swift run zpdf-contract-freeze ../../Docs/Contracts 2026-09-01T23:28:48Z`), the same pinned timestamp `Scripts/build-core-packages.sh` uses for its drift check. It was not edited by hand. Only `MARKUP_CONTRACT.json` and `MEASUREMENT_CONTRACT.json` differ; the other five documents are byte-identical.

## Versions and compatibility

No field name, Swift type, enum case, raw value, unit, table or specification list changed. Removing every `summary`, `invariant`, `invariants` and `note` value from the documents before and after the re-freeze leaves identical JSON. `ContractVersion` numbers track the wire grammar of persisted records and are raised only when that grammar changes, so none is raised: markup stays 6, measurement 5, and the architecture, scale, snap, ledger and formula versions are unchanged. `frozenAt` and the `generator` string are unchanged. The documents carry no digest and no file in the repository pins a hash of them, so nothing else needs updating.

No data migration is needed. Stored projects, exported files and every `Codable` payload are unaffected because the catalogue strings exist only in the freeze output; no runtime code reads them.

## Verification

- `swift test` in `Packages/ZPDFContracts`: the freeze suite refuses unannotated or stale fields, and the page-index contract test reads the committed `ARCHITECTURE_FREEZE.json`.
- `Scripts/build-core-packages.sh`: regenerates the freeze into a scratch directory with the committed `frozenAt` and fails on any byte difference from `Docs/Contracts`.
- `Scripts/verify-no-competitor-names.sh` and `Scripts/verify-author-scrub.sh` cover the regenerated documents.
