# ADR-0023 — Save Markups into PDF

Status: Accepted.

## Decision and rationale

Save Markups into PDF is an explicit, confirmed operation. In Quick PDF Mode it atomically replaces the opened PDF. In Project Mode the package's source drawing remains immutable and the operation writes a chosen destination.

Write annotations and an embedded `zenit-takeoff.zpdfoverlay` as an associated supplemental file. The embedded descriptor records the measured drawing prefix's length and SHA-256. A later save replaces the previous Zenit annotation set, dependent replies/pop-ups and embedded takeoff while retaining unrelated annotations and attachments.

The incremental writer keeps the opened bytes as the output prefix. Refuse an in-place write if the file on disk no longer begins with those bytes; validate the prefix hash before trusting a restored takeoff. Refuse unsupported encrypted, unindexed or dimension-mismatched inputs rather than rewriting the original through PDFKit.

Confirmation names the destination and changes. Without an affirmative answer, write nothing. [ADR-0042](ADR-0042-export-markup-layers-as-pdf-layers-and-zenit-annotations-superseded.md) distinguishes full annotation replacement from appearance-export supersession.
