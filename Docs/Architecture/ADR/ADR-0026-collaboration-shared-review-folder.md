# ADR-0026 — Shared review through user-selected folders

Status: Accepted; log writing and incomplete reads are superseded by ADR-0038.

## Decision and rationale

Use a user-chosen folder with `review.json`, one `participants/<id>.zlog` operation log and one presence file per participant. Keep each participant's project database local; do not put a shared SQLite database in the folder. The app makes no network connection. External folder synchronization belongs to the user's storage service.

Each participant writes only its own log. Validate project identity and participant filenames and reject entries claiming a different log identity. This rule provides format consistency, not cryptographic authentication of a person with folder access.

Operations carry stable IDs and a hybrid logical clock. Split markups into canonical registers; keep geometry and measurement inputs together. Exchange geometry rather than trusted computed quantities. Deduplicate operations, merge in deterministic clock order, use last-writer-wins registers and removal/retraction rules, and recompute quantities locally.

Publish differences from the local base, read and merge the folder, then apply changes as one undoable operation. Update the base from the applied state. Unsupported in-place changes are reported, not forced through destructive remove/re-add operations.

[ADR-0038](ADR-0038-persistence-services-platform-shared-review-log-append-and-complete-reads.md) replaces whole-log rewriting with bounded append/compaction and requires a complete read before synchronization.
