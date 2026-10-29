# ADR-0016 — Net quantity columns and nonnegative parameters

Status: Accepted; Gross Area and Cutout Area columns are added by ADR-0018.

## Decision and rationale

The ledger's Plan Area column reads `netArea`, and Wall Area reads `netWallArea`. Quantities used for ordering and estimating must reflect cutouts. The gross outline remains a separate measurement field; [ADR-0018](ADR-0018-cutout-rows-and-skipped-self-intersection-warning.md) exposes it in its own column.

`MeasurementParameters.validate()` requires depth, height and end height to be finite and nonnegative. Validate dimensions first. Zero remains a valid degenerate quantity; a negative or NaN parameter produces a typed error naming the field.

Decoding does not silently repair a negative parameter. Stored data remains readable and calculation performs the validation. The column mapping changes display behavior without changing the stored row or column shape.
