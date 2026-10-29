# ADR-0009 — Takeoff hydration companion tables

Status: Accepted; kept-result hydration is extended by ADR-0034.

## Decision and rationale

Schema v5 adds `takeoff_state` and `markup_extra` beside the base project tables. The first records drawing-level state; the second carries markup kind, ordering, parent/count links, caption, printability, parameters and richer geometry/custom-value JSON.

Continue writing the base geometry blob and measurement decimal strings. Write geometry JSON only when the blob cannot represent the geometry exactly, and write both projections in one transaction. When present, the richer geometry is authoritative for hydration. Default parameters need no redundant JSON.

Ordinary hydration recomputes through the measurement engine and compares round-trip values with stored results. Explicitly kept stale-scale values are the exception defined by [ADR-0034](ADR-0034-appcore-kept-values-persist-and-iteration1-fixes.md). Companion tables are additive: readers that ignore them can still read the base project representation.
