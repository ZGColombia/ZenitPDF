# ADR-0027 — Multiple drawings in one project

Status: Accepted.

## Decision and rationale

A project holds one ordered set of pages from several drawings. Each page retains its drawing identity and source PDF index; set order is separate as specified by ADR-0022.

`TakeoffArchive.writeSet` writes each drawing's pages, markups, scales, Scale Regions and Project Zones under that drawing's row. Page positions are set-wide; custom columns are project-wide. Unscoped zones and held-back markup data are associated with the first drawing.

Persist drawing order in `document_set_entry.sort_order`. Read each stored takeoff in that order, adopt page identities within its own PDF and restore the overall set positions. Refuse markups whose page is absent instead of reparenting them.

The ledger aggregates over the whole set through the same projection as a single drawing. The schema v13 companion tables provide ordering without redefining source page indices.
