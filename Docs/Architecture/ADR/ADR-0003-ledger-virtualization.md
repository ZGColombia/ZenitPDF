# ADR-0003 — Quantity Ledger virtualization

Status: Proposed performance and presentation policy.

## Decision and rationale

Use an AppKit outline/table surface backed by an index-addressed ledger projection. Fetch only the rows needed for the visible range; do not materialize the entire ledger into a UI array. Stable row identities survive sorting, filtering, grouping and reuse of cells.

Run queries, grouping and formula work away from the main actor. Main-thread work presents results and handles input. Selection synchronizes with the canvas by identity in both directions, including revealing a row inside a collapsed group.

Cells use tabular digits, explicit units and meaningful accessibility values. Virtualization must preserve row identity, headers, expanded state and keyboard navigation for assistive technology.

Evaluate changes with generated 100,000-row ledgers, correctness assertions after each operation, timing distributions and memory measurements. The budgets in [QUALITY_BAR](../../Execution/QUALITY_BAR.md) are requirements, not recorded passing results. Replacing the AppKit surface requires evidence that the replacement preserves these properties.
