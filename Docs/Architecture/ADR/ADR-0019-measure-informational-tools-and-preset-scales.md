# ADR-0019 — Informational tools and scale evidence

Status: Accepted; the original absence of Keep Existing Values is superseded by ADR-0030 and ADR-0034.

## Decision and rationale

Informational tools write no field that an unrelated quantity column sums. Angle writes angle; radius, diameter and three-point circle write their circle facts; slope writes ratio, percent and angle. Quantitative disc area and sloped length use the corresponding quantity tools. This change introduced formula version 4.

A preset scale has `source == .preset` and no calibration evidence. Replacing a calibration with a preset removes its evidence in the same undoable change. Copies to other pages are inherited scales, also without fabricated evidence. Separate X/Y calibration stores the optional second entered length.

Bulk scale application changes every affected scale in one undoable batch. Before recalibration, calculate an impact preview on copies and show the affected quantities.

The initial Recalculate/Cancel-only restriction is superseded: [ADR-0030](ADR-0030-measure-round2-verification-keep-arcs-captions.md) defines explicit Keep Existing Values and [ADR-0034](ADR-0034-appcore-kept-values-persist-and-iteration1-fixes.md) makes those values durable.
