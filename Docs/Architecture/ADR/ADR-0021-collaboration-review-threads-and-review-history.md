# ADR-0021 — Review threads, history and drawn text

Status: Accepted; extends ADR-0007.

## Decision and rationale

Store replies in `review_entry`, with stable identity, project/markup references, parent, author label, timestamps, retraction flag and collaboration clock fields. Threads outlive deleted markups. A reply is a database operation integrated with document undo; it is not a measurement command.

Status events are read from history instead of duplicated in thread storage. A note's displayed attribution comes from the history entry that wrote the current text; when unavailable, show that attribution was not recorded.

Measured history values remain canonical decimal strings. Reserved `review.` keys may carry plain text up to 32 KiB for status, comment, label, subject, flags and drawn text. Quantity consumers ignore these review keys, so editing a note does not count as remeasurement.

Text and callout words live in `MarkupRecord.caption`; `comment` is the review note. `editText` is undoable. On hydration, a legacy text/callout record with no caption moves its comment into caption and starts with an empty note. An existing caption, even empty, prevents repeating that migration. Schema v12 adds the thread table; the caption migration uses existing fields.
