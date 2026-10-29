# ADR-0020 — Unit Cost is a rate; Total Cost is derived

Status: Accepted.

## Decision and rationale

Unit Cost is money per SI base unit of the row's priced quantity: metre, square metre, cubic metre or piece. Display-unit changes must not change a price. Rates do not sum; ordinary currency amounts do.

Total Cost is exact Decimal multiplication of the row's priced quantity by its rate, through the shared cell path so repeat multipliers and cutout rules apply. Missing cost or missing quantity yields an empty cell. A cost on an informational tool with no priced quantity is a refusal, not a zero. Overflow or inexact arithmetic remains an error.

Formula `UnitCost` has the corresponding currency-rate dimension. A dimensionally valid formula agrees with Total Cost; a mismatched quantity is refused.

A new rate uses the ledger's existing currency, otherwise the number locale's currency, otherwise SEK. Once stored, the value's own currency code remains authoritative. All surfaces and exports read the same aggregation policy.
