# ADR-0033 — Vector-preserving redaction with verified fallback

Status: Accepted, including resource-pruning and output-verification amendments.

## Decision and rationale

Use the bounded Swift PDF object/content layer in ZPDFExport to rewrite redacted content, with independent Core Graphics/PDFKit readback. qpdf stays in RepairService for inspection and repair. This redaction parser runs in the app process; it is not an XPC security boundary.

Write a fresh document, not an incremental update that retains removed revisions. Cut affected paths, remove intersecting glyphs, blank image samples and rewrite affected forms. Prune unused resources, embedded font characters and encodings that could retain removed text. Honor crop/rotation transforms and painted stroke width, including caps and mitres.

Drop scripts, actions, embedded/associated files, media/PostScript content, metadata, structure-tree text and affected annotations, form values and destinations. A removed object shared elsewhere may survive only where its use shows it whole; otherwise rewrite that use to retain only visible content. Inspect shared images in nested forms, inline images, patterns and annotation appearances. Unmarked sheets must not retain hidden portions removed on another sheet.

When exact rewriting is unsupported, rasterize the affected sheet and report the reason. Unsupported encrypted/object structures can require whole-document fallback. Patterns, fonts, codecs and resource limits have explicit fallback/refusal rules. Bounded decoding and operator/nesting limits apply before excessive allocation; an undecidable case is not silently accepted.

Before keeping the copy, reopen every page and check structure, text, annotation coverage, remaining painted content under boxes and visual agreement outside them. Read decoded strings and whole words for removed-text checks, including hex/UTF-16 forms; do not mistake PDF operators or image bytes for text. Treat overlapping redaction boxes as their combined coverage. Verify unmarked pages as well as marked ones and inspect shared resources after fallback.

Never overwrite the source, including through an alias to the same file identity. Stage output in the destination's authorized replacement location. For a multi-drawing project, build and verify every copy before publishing the set; a failure must not leave a partial set.

Limits remain: glyph geometry depends on font metrics; the structure tree is dropped; unsupported font metrics fall back. Geometric visibility does not model every occlusion or zero-alpha case. Raster shared-image inspection does not inspect images inside Type 3 glyph programs. These constraints and verification checks do not constitute a security certification. See [security boundaries](../../Execution/FINAL_SECURITY_REPORT.md).
