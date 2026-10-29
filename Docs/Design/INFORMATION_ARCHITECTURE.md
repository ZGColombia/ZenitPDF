# Information architecture and terminology

A **project** is the saved `.zpdfproj` package. It can hold a set of drawings, their pages,
markups, calibration evidence, ledger state, and supporting files. A **drawing** is the source
PDF or a PDF derived from a supported image/DXF input. A **page** is one sheet of that drawing.

| Term | Meaning |
|---|---|
| Markup | An annotation or measurement placed on a page |
| Quantity Ledger | Rows, columns, groups, formulas, and totals derived from project work |
| Scale Region | A bounded part of a page with its own calibration |
| Project Zone | An organizational region used to classify work |
| Tool Library | Reusable tool presets and symbols |
| Vector Snap | Candidate points derived from usable drawing vectors |
| Revision Compare | Detection and review of differences between drawing revisions |
| Revision Overlay | Visual alignment and overlay of revisions |
| Split Canvas | Side-by-side drawing views |
| Workspace | A saved arrangement of working UI surfaces |

The navigator selects project content; the canvas shows and edits the drawing; the inspector
shows properties of the current selection; the Quantity Ledger supports review and reporting.
Warnings and status must identify the affected drawing or selection instead of implying a
project-wide failure when only one operation failed.

Keep selection identity stable across grouping, sorting, and page changes. Keep the scope of
commands visible: selection, page, drawing, or set. Opening an image as a drawing is different
from inserting an image markup or attaching a site photo.

See [Screen map](SCREEN_MAP.md), [Formats](../Formats/zpdfproj.md), and
[Architecture](../Architecture/README.md).
