# ADR-0024 — Assemblies derive rows from a stored assignment

Status: Accepted, including recipe editing and per-line cost extensions.

## Decision and rationale

Store `LedgerAssemblyAssignment` as JSON in the reserved `zenit.assembly` custom-value column on the measured source. Assignment, removal and bulk changes use ordinary undoable custom-value commands.

Materialize derived rows for the ledger and exports, never as duplicate canvas or database markups. Give each a deterministic identity from source, recipe and line, with derived provenance, formula and input values. Source edits reevaluate them; deleting or undoing the source removes or restores them. Refuse direct quantity edits. Missing inputs remain visible refusals.

Use the shared formula engine and dimensional algebra. Measurement fields take precedence over supplied defaults; free inputs come from the assignment. Derived quantities participate in dimension-compatible totals and retain their provenance in exports.

Recipes may be built in, stored in the office library or saved in the project's `assembly_recipes` setting. Built-ins are read-only and may be duplicated. Editor and importer use the same validation: declared inputs, valid expressions and matching output dimensions. Optional per-line Unit Cost uses ADR-0020's SI-rate rule.

Preserve unreadable project recipe data byte for byte and refuse overwriting it. Bound project recipe storage to the settings limit. Updating a recipe refreshes unlocked rows carrying an older copy in one undo step; locked rows retain their copy and are reported. Deleting library content does not invalidate assignments that carry their recipe. Presets use built-in/office recipes; [ADR-0035](ADR-0035-quantities-core-coordinate-bound-display-override-preset-assembly.md) defines their assignment encoding.
