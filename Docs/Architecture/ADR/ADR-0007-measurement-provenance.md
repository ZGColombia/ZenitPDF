# ADR-0007 — Measurement provenance and append-only history

Status: Accepted; review text in history is extended by ADR-0021.

## Decision and rationale

Persist a measured value's derivation: geometry digest, scale identity/version/source, calibration evidence, slope and parameters, formula and engine version, and calculation time. The inspector explains the chain from geometry and calibration to raw value and display rounding.

Record changes in `measurement_audit` in the same database transaction as the mutation. Undo and redo append compensating and recompensating entries rather than erasing history. Scale changes record both the scale event and the affected measurements. Use indexed queries and decimal strings for measured values; history must not become a second calculation path.

Expose per-markup derivation and history, a project History view, and exportable audit information. Retention and indexing must keep the mutation path bounded without silently losing the explanation of a current value.

[ADR-0021](ADR-0021-collaboration-review-threads-and-review-history.md) extends history with bounded `review.` text fields. Markup layers are a separate decision in [ADR-0032](ADR-0032-layers-markup-layers.md).
