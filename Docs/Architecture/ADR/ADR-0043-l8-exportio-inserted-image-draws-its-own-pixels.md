# ADR-0043 — Inserted raster images render from source pixels

Status: Accepted; supersedes ADR-0011’s mosaic-only rule for inserted image markups.

## Decision and rationale

An inserted raster image markup renders stored source bytes, cached by artwork digest and mapped through the same letterboxed, rotated placement as its geometry. Decode off the main thread after a 40-million-pixel header check and limit the decoded long edge to 4,096 pixels.

Keep the compiled mosaic as a visible fallback when source bytes are missing or cannot decode. Raster stamps and count symbols retain their bounded geometry rendering. Vector artwork is not decoded again from its source PDF.

`RenderShape.image` carries encoded image bytes and a page-space parallelogram. The common decoder enforces the same bounds. Core Graphics paints the image in fill order for canvas-related outputs, print, snippets and flattened/layered/annotated PDFs. Invalid image data produces a frame/refusal indication rather than disappearing silently.

The Metal backend accepts image bounds and hit geometry but does not paint textured image pixels. The app uses it for the vector underlay, while image-bearing markup output uses the Core Graphics/AppKit paths. A future Metal markup surface would require an explicit image pipeline.

Original artwork bytes were already stored; this change requires no project schema migration.
