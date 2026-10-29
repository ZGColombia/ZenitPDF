# ADR-0013 — Layered markup PDF export

Status: Accepted; grouping is superseded in part by ADR-0042; the original qpdf writer proposal is superseded by the Swift exporter.

## Decision and rationale

`layeredMarkups` is a distinct output mode alongside annotated, flattened and clean PDF. Paint markup content inside PDF optional-content spans so a recipient can switch it on and off.

Append optional-content groups to the drawing's existing `/OCProperties`; never replace its own layer tree. Preserve source bytes as the incremental output's prefix and explain the modifications. If the structure cannot be safely extended, refuse instead of silently changing to flattened output.

The implementation is `ZPDFExport.LayeredMarkupExporter`, using the Swift PDF object layer. qpdf remains confined to inspection and repair. [ADR-0042](ADR-0042-export-markup-layers-as-pdf-layers-and-zenit-annotations-superseded.md) defines one group per project markup layer and the single-group fallback.

Verification must read the exported structure and render it with markup groups off; opening the file alone does not establish layer fidelity. This is an export-mode change, not a project-storage migration.
