# ADR-0041 — Sloped arc integration and consistent stored geometry

Status: Accepted; supersedes the flattened sloped-arc rule in ADR-0004 and formula version 7.

## Decision and rationale

Integrate a sloped arc over its mapped tangent with the shared Gauss–Legendre schedule. The rule works under affine scale and returns the plan result unchanged at zero slope. Handle complete turns plus a remainder without unbounded iteration. This replaces the flattened-polyline slope approximation.

Point-form Arc Length completes at three points. Collapse consecutive duplicates, then refuse any live input with another count. Normalize legacy records to the first three distinct points the earlier engine actually measured. Share that repair across hydration, clipboard, overlay import and review exchange, including the merged state and local review base so normalization is not republished as a new edit.

Store the geometry actually measured. Canvas and snap read one `drawnPointChain` rule for the arc through start, through-point and end; degenerate input remains visible as its placed polyline until refused.

`EllipseCutoutRing` keeps its four cardinal vertices on the drawn box and adjusts the other radii to retain area πab. This avoids false outside-parent warnings when the box is flush with an axis-aligned boundary. It is still an area-preserving polygon, so slanted tangencies retain a small approximation limitation.

Accepted partial overlap is non-blocking and says only the inside part is subtracted; no overlap remains a typed refusal. The calculation changes introduced formula version 8. Older kept results are recomputed under changed formula rules; stored legacy arc geometry is normalized without a schema change.
