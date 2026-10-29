# ADR-0018 — Cutout rows and unchecked self-intersections

Status: Accepted.

## Decision and rationale

A skipped self-intersection check emits `selfIntersectionCheckSkipped`, with the vertex count and limit. It does not claim that the outline is simple. The UI explains the assumption without replacing the calculated value.

Gross Area reads the outer `planArea` and may sum once per parent. Cutout Area reads removed area and never sums: a parent reports the union while separately reported children may overlap. Plan Area continues to read net area.

Cutout rows show ordinary descriptive fields but no measured or formula quantity. The exception is their own Cutout Area when the parent's policy is `subtractAndReportSeparately`; orphaned cutouts report no quantity. Apply this rule through the shared ledger cell path so screen and all exports agree. A parent's policy edit also reevaluates its child rows.

The parent retains `gross − cutout = net` under subtraction. Volume and true area use the net quantity. This presentation change does not alter the perimeter policies or stored geometry.
