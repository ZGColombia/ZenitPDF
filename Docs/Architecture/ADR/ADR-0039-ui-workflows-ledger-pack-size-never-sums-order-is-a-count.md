# ADR-0039 — Per-row inputs do not sum; order quantities are counts

Status: Accepted.

## Decision and rationale

Add optional `LedgerColumnDefinition.neverSums`. True excludes the column from Sum through the common aggregation plan; nil retains existing policy. Normalize false to nil so old encodings remain unchanged. Row counts remain available.

Carry the flag through presentation and column editing as Leave out of totals. Use it for pack sizes and other per-row parameters whose sum is meaningless.

An order quantity is explicitly typed by its formula: `CONVERT(ROUNDUP([Gross] / [Pack size], 0), 1, count)`. The formula compiler and runtime both produce count, so dependent formulas and exports agree. Do not retag a ratio only at the display layer. No separate expression grammar is introduced.
