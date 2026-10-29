# ADR-0006 — Snippet export from page-space geometry

Status: Accepted.

## Decision and rationale

A snippet describes a source drawing, page and revision; a markup subset, page rectangle or zone; content options; caption policy; and output scale. Its region comes from stored page-space geometry, so changing viewport zoom or window size does not change the output.

Captions use the same ledger projection and formatter as other exports. Compact captions include value, unit, label and subject; full captions add drawing, page, revision, scale and calibration context. An explicit no-caption mode is permitted, but is not the default.

Support bounded PNG output, pasteboard output with a plain-text caption fallback, and a PDF region output. Report dimensions before large allocations and refuse outputs beyond the pixel budget. Offscreen rendering accepts a page-space rectangle and scale.

Snippet export introduces no separate annotations or image-editing state: content comes from the project. A future platform share sheet is outside the macOS release.
