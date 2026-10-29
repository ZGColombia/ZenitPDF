# ADR-0002 — UI presentation through standalone packages

Status: Proposed package-boundary policy, clarified by ADR-0008.

## Decision and rationale

UI packages depend on presenter protocols and transferable value types rather than concrete engines. `ZPDFUIPresentation` defines the seam; `ZPDFDesignSystem` provides visual primitives; shell, measurement, ledger and workflow packages implement their respective surfaces.

Presenters are observable and main-actor isolated. Background computation returns `Sendable` values rather than sharing mutable engine state with views. Derived presentation state belongs in shared protocol extensions where possible. Synthetic mock presenters remain useful for previews and empty, loading, error and large-data cases.

`ZPDFAppCore` adapts domain contracts and services to the presentation protocols. Geometry, measurement, persistence, aggregation and stored precision remain domain responsibilities. UI formatting must never round stored quantities. Contract conflicts are resolved at the adapter boundary, with domain semantics preserved.

The portable presentation package must contain no AppKit conveniences; see [ADR-0008](ADR-0008-uipresentation-seam.md). The [architecture map](../README.md) describes the current package composition.
