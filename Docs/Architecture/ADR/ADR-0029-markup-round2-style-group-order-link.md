# ADR-0029 — Markup styling, groups, ordering and links

Status: Accepted; cross-layer draw order is superseded by ADR-0036.

## Decision and rationale

Add optional text style, cloud-arc size, rotation and blend mode to `MarkupStyle`. Absent fields preserve previous appearance and encoding. Clamp explicit cloud arcs to their valid range and normalize effective rotation. Stamps retain their own placement rotation.

Add optional group identity and a link target to `MarkupRecord`. A link names exactly one page or a permitted http/https/mailto URL. External links require confirmation before handoff to the system. Persist group/link extras in the existing style JSON without changing the schema; older readers ignore unknown keys.

Within a layer, drawing and hit-testing use markup order, persisted as `markup_extra.sort_order`. Arrange commands reorder only the applicable page/layer and store the previous order for undo. [ADR-0036](ADR-0036-app-canvas-layer-order-is-draw-order.md) supersedes the original claim that markup order alone governs every layer.

A clouded callout is a cloud ring with leader target and box points, with words in caption. Freehand stores a simplified open point chain; smoothing is rendering, not stored geometry. Structural commands reuse the existing custom-value command category.
