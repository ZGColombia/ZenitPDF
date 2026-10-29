# ADR-0042 — PDF markup layers and annotation supersession

Status: Accepted; extends ADR-0013. The filename refers to superseded annotations, not a superseded ADR.

## Decision and rationale

Layered PDF export creates one optional-content group per represented project markup layer, in top-first list order, appended after the source drawing's groups. Paint fragments in the shared drawing order and bind them to their parent markup's layer. Unassigned content uses a fallback group.

With no layer descriptors, or only the stock Default layer, retain the single Zenit Markups group. Hidden printable layers travel switched off so recipients can enable them. Nonprintable layers and individually hidden markups are omitted.

Appearance exports suppress previously embedded annotations only when they represent markups in the current document state or annotations already hidden/restored by the canvas. Match annotation names and fragment families; the `/ZPDFMarkup` marker alone is not enough to discard another project's annotations. Retain the legacy unnamed Zenit-subject supersession rule.

Layered and structure-preserving Marked output update affected annotation arrays, including pages without newly painted markups, and report superseded counts. Rebuilt Marked, Clean, Print and report-sheet rendering hide the same superseded annotations before drawing.

Annotated export and Save Markups into PDF deliberately replace the complete Zenit annotation set, including deleted items, and therefore retain their broader marker-based replacement rule. These different policies prevent double painting while preserving unrelated visible annotations. No project schema changes are required.
