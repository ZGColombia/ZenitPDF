# ADR-0001 — Graphite Workshop design system

Status: Proposed design policy; implementation details live in ZPDFDesignSystem.

## Decision and rationale

Use semantic design tokens for color, typography, spacing, iconography, motion and appearance. Author light, dark and increased-contrast variants explicitly. Keep the drawing dominant and use color together with labels or shapes for status and snapping.

Use tabular digits for comparable quantities, system text for labels and monospaced text for identifiers. Prefer platform symbols for generic actions and original vector geometry for measurement tools. Controls need accessible labels and useful hit areas even when the visible glyph is smaller.

Motion explains state changes and must not delay measurement input. Reduce Motion removes animation without removing information. Canvas backdrop and measurement ink have distinct roles from application chrome.

The design targets a 24-point minimum hit area and a shared spacing ramp. Token calculations do not establish rendered accessibility: review focus, contrast, scaling and VoiceOver in the assembled app. See [Accessibility](../../Design/ACCESSIBILITY_PLAN.md) and [Visual reference](../../Design/VISUAL_REFERENCE.md).
