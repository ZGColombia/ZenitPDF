# ADR-0005 — Portable engines and a native platform shell

Status: Accepted; the presentation-package exception is superseded by ADR-0008.

## Decision and rationale

Separate portable contracts and engines from the native application shell. Portable packages must not import AppKit, UIKit or Cocoa. Use Core Graphics and contract value types for geometry, images and colors; inject platform behavior through protocols.

The portable tier includes geometry, measurement, formulas, ledger, snap, extraction, persistence, search, compare, export, renderer, test support and native bridges. Platform UI packages and the AppKit app compose these capabilities. Portable manifests declare macOS and iOS compilation targets; `Scripts/verify-multiplatform.sh` checks the boundary.

An iOS compilation check is not an iPad product. Touch interaction, tablet layout and platform document integration are separate work and are not shipped.

[ADR-0008](ADR-0008-uipresentation-seam.md) supersedes the original allowance for AppKit guards inside ZPDFUIPresentation: that package belongs wholly to the portable tier.
