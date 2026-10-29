# ADR-0037 — Exact arc cutouts, ellipse quadrature and snap geometry

Status: Accepted; formula version 7 is superseded by ADR-0041.

## Decision and rationale

Compute net curved area by splitting line/arc boundaries at exact intersections, classifying pieces against true winding and integrating the retained boundary with compensated, origin-shifted area terms. Canonical ordering removes duplicate shared boundaries. Use the same retained pieces for `outerPlusCutoutEdges` perimeter.

Fall back to bounded flattened booleans with an explicit precision warning for self-crossings, ambiguous contacts, normalized or unchecked rings, excessive work or disagreement beyond the flattening/lattice error bound. Preserve the existing exact disjoint-interior result where applicable. Polygon Cutout can draw and edit arcs; Ellipse Cutout remains a distinct shape.

Use stable singular-value ellipse axes and quadrature for circumference. Arc Length under separate X/Y scales uses the common mapped-curve integration rule and does not report a circular radius/angle where the transformed geometry is not circular. These changes introduced formula version 7.

Canvas and snap share record-level geometry rules: inscribed ellipses rather than their box corners; actual open chains and curved edges; visible frames only; callout leaders; and the same rotation centre and angle. Ellipse quadrant and centre targets are not high-priority polygon vertices. Hidden-layer markups are excluded from snap and restored by undoing visibility changes.

This supersedes ADR-0030's general flattened-cutout calculation and extends ADR-0034's disjoint case. [ADR-0041](ADR-0041-quantities-core-sloped-arcs-on-the-curve-three-point-arc-length-ellipse-cutout-ring.md) adds sloped integration and refines three-point arc and ellipse-cutout behavior.
