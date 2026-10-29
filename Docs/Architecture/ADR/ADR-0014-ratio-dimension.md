# ADR-0014 — Ratios are distinct from counts

Status: Accepted.

## Decision and rationale

Add a `ratio` tag to `QuantityDimension` so a share or slope cannot silently behave as a count. Both remain dimensionless with base symbol `1`, but aggregation and formula typing preserve their distinct meanings.

A quotient of equal non-dimensionless units is a ratio; a dimensioned result cannot carry the tag. Scaling counts by ratios yields counts. Bare literals remain transparent in multiplication/division, and a dimensionless power retains its tag except that power zero is a count. A recipe's declared output dimension determines whether a dimensionless result represents a count.

Encode the tag only when true; old encodings remain counts and existing dimension encodings are unchanged. Measurement slope fields declare ratio. On decoding stored measurement results, retag only count/ratio mismatches; preserve other dimension errors for validation.

Formula static and runtime types must agree. The original change raised architecture contract version to 2 and measurement contract version to 4; these are historical transition numbers, not a claim about the latest version.
