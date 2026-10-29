# ADR-0022 — PDF page index and project set order

Status: Accepted.

## Decision and rationale

`PageDescriptor.index` is the zero-based position in the page's own PDF and is fixed at import. `documentID` identifies that PDF. Project set order is a separate ordered page list; ledger page position follows that list.

Schema v13 stores set position in `page_set_entry.position`. Reopening first adopts saved page identities by PDF index, then restores set order. Pages without a saved position keep their PDF order after positioned pages.

The same migration introduces document ordering, sheet metadata and provenance, view rotation/exclusion, and revision pairing tables. Reordering a set must not change which PDF page renders or is measured. Keeping index semantics avoids changing the rendering and extraction contract.
