# ADR-0015 — Cutout containment and net boundary semantics

Status: Accepted.

## Decision and rationale

Refuse a cutout with no overlap using `cutoutOutsideParent(cutoutIndex:)`. The index refers to the original holes list even when earlier holes are degenerate. Accept partial overlap with a warning and subtract only the part inside the parent, using the containment tolerance.

A negative net wall area is a typed `negativeNetArea` error. Openings that exactly consume the wall produce a flagged zero.

`outerOnly` perimeter is the drawn outer boundary. `outerPlusCutoutEdges` is the boundary of the net boolean region, including its hole boundaries, so overlapping or edge-touching cutouts do not count shared edges twice.

The calculation change introduced measurement formula version 3. Stored results retain their formula stamp so later recalculation is detectable. [ADR-0041](ADR-0041-quantities-core-sloped-arcs-on-the-curve-three-point-arc-length-ellipse-cutout-ring.md) clarifies the non-blocking copy for accepted partial overlap.
