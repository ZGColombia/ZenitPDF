# ADR-0036 — Layer order determines drawing order

Status: Accepted; supersedes the cross-layer ordering rules in ADR-0029 and ADR-0032.

## Decision and rationale

Draw by layer rank, then stably by markup order within the layer. The top listed layer draws above lower layers. A one-layer project therefore retains its previous appearance.

`MarkupLayerSet.drawOrder` is the shared rule. Canvas rendering, reverse hit-testing, marquee selection, Split Canvas, print and PDF outputs consume it. Review exchange also preserves draw order, without excluding content solely because a layer is hidden.

Stored markup order and ledger order remain unchanged. Reordering layers updates the layer list, not every markup row. Arrange commands operate within the item's page and layer while other slots retain their positions. Include layer order in the canvas scene key so reordering causes a redraw.

This replaces the original list-only interpretation of layer order without a project schema migration.
