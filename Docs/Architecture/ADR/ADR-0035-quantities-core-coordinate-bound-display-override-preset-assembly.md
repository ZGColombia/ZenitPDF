# ADR-0035 — Bounded geometry, display overrides and exact numeric policy

Status: Accepted; formula versions 5 and 6 are historical and are superseded by ADR-0037 and ADR-0041.

## Decision and rationale

Bound coordinates and curved extents to an inclusive magnitude of `1e7` PDF points and refuse larger geometry. Validate opening areas as finite and nonnegative, just like depth and height. These are typed errors, not clamped quantities.

Optional `displayOverride` distinguishes per-markup units from project units. It affects formatting only; calculations and totals remain in SI. Screen and exports use the same per-row formatting. Mixed-unit spreadsheets identify units per row and must not sum incompatible displayed magnitudes through a spreadsheet SUM.

Use one exact-or-refuse Decimal addition/subtraction policy. Subtraction uses addition of the negated operand to detect precision loss consistently. Formula and ledger callers keep their typed error mappings; neither silently rounds an intermediate aggregate.

Store preset assemblies in `customDefaults["zenit.assembly"]`. Draw, Place and Apply share the assignment path. Editor and import validate the complete assignment, including any carried recipe. Bound it to 16,384 characters and retain or reject it whole; never truncate JSON. Preserve unreadable assignments until explicitly replaced.

Calculation corrections introduced formula versions 5 and 6: normalize self-crossing holes with warnings, use origin-shifted compensated area, canonically order cutout booleans, support perpendicular thickness at zero slope, preserve exact disjoint boundaries, and evaluate degeneracy in page space. Use stable ellipse axes, mapped-tangent quadrature under nonuniform scale, drawn-order rise/drop pairing, and drawn-boundary net area when its prerequisites hold. If only the lattice result is reliable, retain its documented precision limits.

Share Scale Region sampling and overlap predicates between engine and application. Remove unused alternative implementations rather than preserving competing calculation paths. Later formula revisions in [ADR-0037](ADR-0037-quantities-core-exact-arc-cutouts-ellipse-quadrature-snap-projection.md) and [ADR-0041](ADR-0041-quantities-core-sloped-arcs-on-the-curve-three-point-arc-length-ellipse-cutout-ring.md) supersede the recorded version numbers, not the validation and formatting decisions.
