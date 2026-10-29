# Screen map

| Surface | Purpose | State to preserve |
|---|---|---|
| Project window | Compose navigation, drawing, inspector, and ledger | Current document/page and selection |
| Navigator | Select drawings, pages, and project content | Stable page identity and visible loading state |
| Canvas | View, measure, annotate, compare, and select | Zoom, active gesture, snap feedback, calibration context |
| Inspector | Edit properties of the selection | Mixed values, validation errors, and editing focus |
| Quantity Ledger | Review rows, grouping, formulas, and totals | Selection identity, filters, expanded groups, and column settings |
| Tool Library | Reuse presets and artwork | Selected preset, import review, and missing-artwork feedback |
| Scale/calibration surfaces | Define and verify a page or region scale | Units, scope, evidence, and existing-value decision |
| Search/review surfaces | Locate drawing content and inspect proposals | Active result, source page, and accept/reject state |
| Export flow | Choose output and destination | Scope, format semantics, progress, and actual completion |
| Settings and help | Configure preferences and explain current commands | Accessible focus and effective settings |

For each surface, design empty, loading, populated, error, and partial-result states. Keep
recoverable failures local to the task. Dialogs should restore focus after dismissal; inspector
edits must not unexpectedly arm a canvas tool.

The [architecture map](../Architecture/README.md) identifies the packages implementing these
surfaces. [Information architecture](INFORMATION_ARCHITECTURE.md) defines their shared terms.
