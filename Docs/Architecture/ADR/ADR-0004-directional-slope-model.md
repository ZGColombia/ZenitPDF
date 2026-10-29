# ADR-0004 — Directional slope model

Status: Accepted; the arc rule is amended by ADR-0041.

## Decision and rationale

Slope has a magnitude and a steepest-ascent direction. A uniform-plane length uses each mapped segment: `sqrt(|d|² + (s · (d · u))²)`, where `s` is rise/run and `u` is the fall-line unit vector. Perimeters use the same rule around the selected boundary. A blanket factor is not valid for arbitrary directions.

Net surface area is `netPlanArea · sqrt(1 + s²)`. Subtract cutouts in plan before applying the factor. Vertical volume depth uses plan area; depth perpendicular to the surface uses true area. Wall area uses true base length and vertical height; a varying top uses its trapezoidal or triangular height rule. Counts are unaffected.

Keep Plan and True quantities distinct in the inspector, ledger and export. Store the slope, direction and depth reference as explicit inputs. Pitch, percent and angle input resolve to a stored ratio; formatting does not rewrite it. Reject undefined vertical slopes and ambiguous scale-region crossings; flag unusually steep slopes for review.

Arcs on a slope are integrated over their mapped tangent, as specified in [ADR-0041](ADR-0041-quantities-core-sloped-arcs-on-the-curve-three-point-arc-length-ellipse-cutout-ring.md). The original flattened-arc rule is superseded.
