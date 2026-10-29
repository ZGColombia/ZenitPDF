# ADR-0017 — Shared validation and contract hygiene

Status: Accepted.

## Decision and rationale

Use named refusals for invalid artwork coordinates/strokes, a missing formula and an empty sum without a dimension. Share artwork well-formedness and resource-limit checks across compilation, decoding and persistence. Restrict slope degrees to the valid open interval around a nonvertical plane.

Validate precision while decoding without changing its wire encoding. Normalize finite slope azimuths through their normal initializer and refuse non-finite values. Parameter validation remains at calculation as in ADR-0016.

Dimension ordering includes length power, angle, currency and ratio. A markup measured under another scale is stale; a markup that names no scale does not claim one. Measurement-backed ledger fields, including depth and height, are read-only. Snap kinds explicitly declare whether they require vector content.

Slope parsing accepts only its declared grammar and well-formed numeric tokens. Unit tables must account for every supported case. Frozen contract text derives limits and enumerations from code, preserving fractional numbers and using exhaustive mappings rather than independently maintained prose constants.

These changes preserve existing valid wire formats while rejecting invalid inputs explicitly.
