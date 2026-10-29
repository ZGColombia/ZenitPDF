# ADR-0025 — Live quantity tables and legends

Status: Accepted.

## Decision and rationale

Represent a live summary as a Text markup with a `LiveSummarySpec` in reserved custom column `zenit.summary`. Store the grouping, filter, kind, title and sheet scope rather than a second independent quantity model.

Generate its caption from the shared ledger projection and formatter. State scope, filtered row count, groups, totals and update time. Mixed dimensions produce an explicit unavailable-total explanation. A count legend lists subjects, symbols and counts.

Refresh captions inside the same undo step as the quantity change and retain the previous caption in the inverse. Undo, redo and reopen restore the caption for that state. Ordinary text rendering carries it to the canvas and PDF outputs.

The summary itself contributes no ledger quantity. Placement is one undoable command; no new markup kind or schema is needed.
