# ADR-0038 — Append-only review logs and complete reads

Status: Accepted; supersedes log rewriting and incomplete merge behavior in ADR-0026.

## Decision and rationale

Append only new lines to a participant's own regular-file log using no-follow, nonblocking access. Read its final byte to determine newline handling. Refuse unreadable/nonregular files; roll back partial writes to the old length. Readers ignore an unterminated final line.

Create `review.json` only when absent. Never replace an unreadable, invalid or newer existing manifest. Read every participant log before publishing and again before merging. Refuse incomplete reads and leave the document/base unchanged rather than silently omitting a participant.

At the size cap, compact only the participant's own log and atomically replace it. Keep merge-winning operations and future-clock operations, preserving deterministic merge semantics within the stated clock assumptions. If the compacted result still exceeds the cap, refuse without writing. The JSON Lines format does not change.

Use bounded regular-file reads that never follow symlinks or block on FIFOs. Cache decoded prefixes, but still read each log on synchronization; perform reads and append work away from the main actor. Keep the fingerprint used to decide a sync so later foreign writes are picked up by the next tick.
