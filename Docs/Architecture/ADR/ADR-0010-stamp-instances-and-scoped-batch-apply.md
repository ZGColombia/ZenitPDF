# ADR-0010 — Stamp instances and scoped batch application

Status: Accepted; artwork identity and raster handling are superseded by ADR-0011.

## Decision and rationale

A markup may carry an optional `StampInstance`. Store resolved field text, template identity, placement and an artwork digest, never a live recipe or a copy of the artwork per placement. Missing optional fields preserve older record decoding.

The additive `markup_stamp` table projects the instance; `stamp_artwork` stores content once by digest. Artwork outlives individual placements so undo can restore a stamp without losing its source.

Vector stamp contours are geometry in a unit box, transformed to page space. Each emitted render shape requires a distinct identity, grouped back to its placement; [ADR-0011](ADR-0011-imported-artwork-and-markup-symbols.md) supersedes the original shared-identity rule and defines raster mosaics.

`BatchPageItemProducing` supplies item-specific matching and placement. AppCore handles scope, per-page anchoring, preview, progress, cancellation and one audit/undo group. Resolve anchors against each page's visible box. Build records before committing one atomic batch; cancellation must not leave half a batch.
