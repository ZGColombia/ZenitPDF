# Interaction model

The command table, tool presenters, and canvas gesture code define exact bindings. This guide
records the shared behavior that changes must preserve.

| Interaction | Required outcome |
|---|---|
| Select a tool | Show its name, required input, current options, and applicable scale state |
| Move over geometry | Show snap candidate kind and location without committing a point |
| Place a point | Use the same page-space location for preview, stored geometry, and calculation |
| Finish a multi-point tool | Commit only valid geometry; report an actionable refusal otherwise |
| Cancel | Remove the active preview without silently creating a saved markup |
| Edit a completed measurement | Recompute affected values and preserve history/provenance |
| Change scale | Explain affected scope and ask how existing measurements should be treated |
| Select a ledger row | Select/reveal the corresponding drawing content by identity |
| Sort or filter | Retain meaningful selection and recompute totals over the intended scope |
| Review recognition | Accept, reject, or correct proposed geometry before treating it as verified |
| Export | Identify destination, scope, format, and what remains editable |

Pointer modifiers are contextual. Text editors retain text-editing shortcuts; a canvas tool
must not intercept ordinary typing in an inspector field. The running app's Help → Keyboard
Shortcuts reference is authoritative for the effective command bindings.

Loading, empty, partial, error, and completed states need distinct feedback. Long work should
report progress and support cancellation where the operation exposes it. No success message
may be shown before the operation succeeds.

See [Keyboard map](KEYBOARD_MAP.md), [Accessibility](ACCESSIBILITY_PLAN.md), and
[core workflow](CORE_LOOP.md).
