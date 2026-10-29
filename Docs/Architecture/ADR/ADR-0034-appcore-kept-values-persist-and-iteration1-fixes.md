# ADR-0034 — Durable kept values and gap-preserving area merges

Status: Accepted; exact cutout calculation is extended by ADR-0037.

## Decision and rationale

Persist a complete kept `MeasurementResult` under `keptMeasurement` in `markup.style_blob`, including values, warnings, formula version and provenance. Write it only for a nonempty result flagged `staleScaleVersion`. Restore it after capture metadata. A capture stamp with no values cannot qualify as a kept result.

Do not reconstruct a kept result from the limited `measurement_value` columns: they omit fields and warnings. ADR-0030's scale/formula checks still govern whether a kept result remains valid. Other markup blobs remain unchanged, and older readers ignore the extra key.

An area merge that encloses gaps produces one merged outer ring and explicit child cutouts in the same undoable batch. Preserve exact arcs in the outline and gaps, subtract later joined areas from those gaps, and refuse disconnected results. State when a gap was retained. Traced union follows the same plan; perimeter/wall tools still refuse an unsupported gap.

Disjoint interior curved cutouts use their exact areas. [ADR-0037](ADR-0037-quantities-core-exact-arc-cutouts-ellipse-quadrature-snap-projection.md) extends exact handling to intersecting curved boundaries.

Build Vector Snap indexes lazily for every displayed page. Keep indexes synchronized with edits; changing PDF layer state invalidates the affected drawing's other page indexes so they rebuild under the new visibility.
