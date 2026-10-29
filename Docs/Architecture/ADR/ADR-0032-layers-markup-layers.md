# ADR-0032 — Project markup layers

Status: Accepted; draw order and layered-output visibility are amended by ADR-0036 and ADR-0042.

## Decision and rationale

`MarkupLayer` has stable identity, name, order, visibility, lock and print flags. A fixed default-layer identity and `nil` markup layer mean the same thing. Unknown layer references resolve to default. Canonical storage uses nil for default so older markup encodings remain valid.

Schema v18 stores the layer list in `markup_layer`, project choices in `project_setting`, and references in `markup_extra.layer_id`. Layer identity is not style and must not leak through Copy/Paste Style. Avoid a foreign key that would break per-drawing saves during layer deletion; resolve dangling references to default.

Layer add, rename, reorder, flag changes, move and deletion are undoable. Preserve the default layer; deletion names a destination for its markups. Save the active layer and project display units separately as settings.

Effective flags combine layer and markup flags without rewriting stored markups. Hidden items are not drawn or hit-tested; locked items reject edits, though scale changes still recalculate them. New work uses a visible unlocked layer, and cutouts follow their parent. Ledger totals do not change merely because a layer is hidden; filtering is explicit.

[ADR-0036](ADR-0036-app-canvas-layer-order-is-draw-order.md) supersedes the original list-only layer-order rule: layer order controls drawing order. [ADR-0042](ADR-0042-export-markup-layers-as-pdf-layers-and-zenit-annotations-superseded.md) retains hidden printable layers as switched-off optional content in layered PDF output.
