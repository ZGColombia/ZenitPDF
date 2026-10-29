# ADR-0008 — ZPDFUIPresentation is wholly portable

Status: Accepted; supersedes the presentation-package exception in ADR-0005.

## Decision and rationale

Keep ZPDFUIPresentation together as a portable package. It contains value types and presenter protocols, so it needs neither an AppKit-specific sibling nor conditional AppKit imports.

Apply the same forbidden-import checks and iOS compilation gate as for the other portable packages. Native convenience code belongs in ZPDFDesignSystem or an appropriate UI surface package.

This decision replaces the earlier allowance to guard or split AppKit conveniences in [ADR-0005](ADR-0005-multiplatform-boundary.md). It does not promise an iPad application.
