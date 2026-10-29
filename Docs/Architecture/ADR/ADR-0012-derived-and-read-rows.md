# ADR-0012 — Measured, derived and read quantities

Status: Accepted; assembly storage is specified by ADR-0024.

## Decision and rationale

Every quantity states its provenance: `measured`, `derived` or `read`. An absent provenance decodes as measured for compatibility. Derived and read quantities require a derivation containing source identity or region, formula or recognized text, input values and origin identifier. A measured row must not claim such a derivation.

Derived quantities change by reevaluating their source and formula, not by direct quantity edits. Deleting the source removes its derived rows in the same undoable operation. Read quantities may be corrected, but remain read and retain an audit trail.

Show provenance in the ledger and exports without relying on color alone. A mixed report must not present a recognized or calculated quantity as a geometric measurement.

The optional record fields are additive. [ADR-0024](ADR-0024-quantities-assemblies.md) refines storage for assemblies: persist the source assignment and materialize derived rows, rather than storing duplicate derived markup records.
