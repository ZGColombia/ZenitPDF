# ADR-0040 — Blank formula input is no value

Status: Accepted.

## Decision and rationale

Map formula `blankValue` and `blankCondition` failures to `LedgerCellError.Kind.missingInput`. Display No input with the engine's detail, rather than inventing a zero.

Aggregation includes that row in Rows but excludes the missing cell from Count, sums, extrema and weighted values. Incremental removal reverses the same contribution exactly.

Do not disguise an upstream refusal as missing input. Track refused input/formula cells during evaluation and propagate the referenced refusal when a dependent expression otherwise reports missing input. Choose deterministically when several refusals apply.

Overflow, division by zero, unit conflict and invalid grammar remain errors that refuse numerical aggregates. Screen and exports share this policy.
