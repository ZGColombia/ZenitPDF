# ADR-0011 — Content-addressed artwork and markup symbols

Status: Accepted; inserted raster images are extended by ADR-0043.

## Decision and rationale

`MarkupRecord.symbol` references artwork by digest and describes kind, size, rotation, built-in glyph and source label. It carries no source bytes. Stamp instances and count symbols use the same project artwork store.

Compile imported artwork once and retain source bytes, compiled geometry and compiler version. Schema v8 adds compiled artwork and `markup_symbol`; preset symbol data stores an AppCore descriptor, not another copy of the artwork. Persistence treats that descriptor as opaque data.

Vector artwork becomes bounded contours and regions. A newly imported single-ink stamp adopts its source ink; an explicit stamp-color edit recolors colorless regions and strokes while preserving white knockouts. Multiple fill inks can remain on their regions, but contours have no independent color. Device-space color extraction is not color management; unsupported colors are not guessed. Count presets retain their classification color.

Raster stamps use a bounded cell mosaic: a maximum 96-cell long edge, quantized color and merged adjacent runs. This is a visible fidelity limitation. [ADR-0043](ADR-0043-l8-exportio-inserted-image-draws-its-own-pixels.md) adds source-pixel rendering for inserted image markups, not raster stamps.

Import limits include 16 MiB source bytes, 20,000 contours, 8,000 points per contour, 200,000 total points, 40 million raster pixels and nesting depth 12. Refusals identify the limit. Imported actions are not executed and no external resource is fetched.

Each render fragment has its own deterministic `shapeIdentity(base:ordinal:)`. Selection resolves the fragment family to the parent markup. This supersedes ADR-0010's shared render identity.
