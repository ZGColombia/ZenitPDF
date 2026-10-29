# ADR-0030 — Scale verification, kept values, captions and arc geometry

Status: Accepted; specific calculation and persistence rules are amended by ADR-0034, ADR-0037 and ADR-0041.

## Decision and rationale

Store scale verification points, stated/measured lengths, scale version and time with calibration evidence. Derive deviation using Decimal. Checks append history and mark the document edited; they are observations, not undoable edits. Preset/inherited scales gain history checks without fabricated calibration evidence. Recalibration creates new evidence; old evidence remains available through undo.

Keep Existing Values is an explicit scale-change choice. Preserve previous values and their scale version, flag them stale, and offer an explicit recalculation action. Hydration may retain a kept result only under an older version of the same resolved scale and the current formula version. [ADR-0034](ADR-0034-appcore-kept-values-persist-and-iteration1-fixes.md) specifies durable storage of the complete result. Scale Region creation does not retain values under an unrelated scale.

`MeasurementCaption` is optional display metadata: selected fields, segment labels and a PDF-point label offset. Use the shared formatter and stored values. Caption edits are undoable style changes, not a second measurement source.

Curved polygon and chain edges use optional bulges, `tan(sweep/4)`, aligned with vertices. Straight records retain their encoding and digest. Compute uniform-scale arc lengths as `r·sweep` and areas as shoelace plus signed circular segments. Curve-aware editing preserves arcs or refuses an ambiguous operation rather than storing chords silently.

During supported multi-point drawing, A toggles a three-point next arc: start, through point, end. Backspace reverses the latest input, and a closing edge may be curved. Exact split/merge works on line and circle intersections and verifies area conservation. Insert projects onto an arc; removal joins compatible co-circular arcs or refuses. Scale Region splitting uses exact pieces for additive quantities, with explicit refusals for unsupported holes, overlaps and boundary quantities.

Snap uses curve primitives and export uses cubic paths; renderer flattening remains an implementation detail. Auto-trace is different: it commits a polygon with a stated 0.05-point flattening tolerance and records capture provenance. Visible fence lines may close openings and are temporary drawing aids.

The initial flattened-cutout rule and exclusion of curved polygon cutouts are superseded by [ADR-0037](ADR-0037-quantities-core-exact-arc-cutouts-ellipse-quadrature-snap-projection.md). [ADR-0041](ADR-0041-quantities-core-sloped-arcs-on-the-curve-three-point-arc-length-ellipse-cutout-ring.md) defines sloped integration and exactly three-point Arc Length input.
