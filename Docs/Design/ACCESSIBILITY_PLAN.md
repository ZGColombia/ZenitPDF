# Accessibility plan

This document defines review requirements, not a claim of completed accessibility certification.
The implementation uses AppKit accessibility and design-system semantics. A release review
must exercise the assembled app with keyboard access and VoiceOver.

## Required behavior

- Give every interactive control a useful label, role, value, and state. Icon-only controls
  need accessible names; color alone must never communicate selection, warning, or snap kind.
- Keep focus visible and predictable. Restore it after dismissing a panel or dialog, and
  preserve keyboard navigation through the navigator, canvas, inspector, and Quantity Ledger.
- Expose canvas selection and measurements as meaningful objects with units and provenance.
  Provide a ledger route to inspect and select markups without precise pointer placement.
- Expose ledger column headers, row/group identity, expanded state, values, totals, and warnings.
  Virtualized rows must not misreport identity as the user sorts, filters, or scrolls.
- Announce useful transitions: completion, failure, scale changes, and settled selection.
  Avoid announcing every pointer update or flooding speech during snapping.
- Respect Reduce Motion, Increase Contrast, and system appearance. Keep essential feedback
  visible when animation is suppressed. Use tabular digits for comparable quantities.
- Review text clipping, enlarged content, hit targets, and focus indication on actual surfaces.
  The design target is at least 4.5:1 contrast for normal text, 3:1 for large text and essential
  non-text controls, and a 24-point minimum interactive target.

## Manual review sequence

Open a synthetic drawing with keyboard commands; reach and operate calibration; select a
measurement tool; inspect its result through the ledger; edit a value; trigger and recover
from a validation error; export; close and reopen the project. Repeat key surfaces with
VoiceOver, increased contrast, and reduced motion. Record missing labels, trapped focus,
unreachable controls, lost selection, or unreadable states as defects.

[UI tests and hosted hit-target checks](../../Tests/README.md) support this review but do not
establish live assistive-technology behavior. See [Keyboard](KEYBOARD_MAP.md) and
[Interaction](INTERACTION_MATRIX.md).
