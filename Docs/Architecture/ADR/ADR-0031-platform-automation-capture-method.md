# ADR-0031 — Capture method records geometric provenance

Status: Accepted.

## Decision and rationale

`CaptureMethod` records how geometry was obtained: manual input, tracing, symbol matching, exact blocks, room detection, scans, wall centrelines or imported measurement annotations. Use a flat value with optional evidence and an unrecognized-kind representation for forward compatibility.

Add optional `MeasurementProvenance.captureMethod`; absence means manual. Capture describes geometry, not a source of trusted quantities. Keep it during recalculation only while the geometry digest agrees; editing geometry resets the capture to manual.

Accepted recognition proposals carry a capture stamp with no values. The normal engine computes the quantities. A proposal accepted before calibration keeps its digest-checked capture separately until it can be measured.

Schema v17 stores capture JSON beside geometry so reopening does not lose it. Display the method and relevant evidence in derivation details and traced exports. Recognition remains subject to review; a capture stamp is not a certification of correctness.
