# Visual reference

Zenit PDF uses the Graphite Workshop design system in `Packages/ZPDFDesignSystem`.
Its semantic tokens, original measurement glyphs, and platform symbols are the implementation
reference. This document does not depend on external screenshots or private visual evidence.

The drawing remains the primary working area. Chrome should support dense, legible inspection
without competing with measurement ink. Keep selection, snapping, warnings, and measurement
states visually distinct, with labels or shapes as well as color.

Use semantic colors for light/dark and increased-contrast appearances. Use tabular digits for
quantities, standard text styles for labels, and monospaced text only when character-level
reading is useful. Interactive hit areas may be larger than their visible glyphs.

Motion communicates state changes and preserves continuity. It must not delay point placement
or hide essential feedback under Reduce Motion. Review actual rendered controls and drawing
content at different scales; a token table alone does not establish visual accessibility.

See [Accessibility](ACCESSIBILITY_PLAN.md), [Screen map](SCREEN_MAP.md), and
[the design-system decision](../Architecture/ADR/ADR-0001-graphite-workshop-design-system.md).
