# User experience review questions

This is a review checklist, not a backlog claiming that the listed problems exist in every build.

| Risk | Review question |
|---|---|
| Untrusted scale | Can the user identify the active scale, its scope, and its evidence? |
| Wrong quantity | Can a ledger value be traced to geometry, units, formula, and cutouts? |
| Silent value change | Does a scale or geometry edit explain and preserve the resulting history? |
| Hidden scope | Does a batch or export action identify selection/page/drawing/set scope? |
| Lost context | Can a user move from a row to its drawing and back without losing selection? |
| False totals | Are incompatible dimensions, informational fields, and blank formula inputs handled honestly? |
| Ambiguous output | Does the export flow explain appearance, editability, and omitted content? |
| Unreachable action | Can keyboard and assistive-technology users operate the same task? |
| Recovery confusion | Does reopening a project explain recovery choices without losing the saved state? |
| Recognition overconfidence | Can proposals be inspected and corrected before acceptance? |

Use synthetic drawings and record concrete steps, expected behavior, actual behavior, and
source revision for any defect. The acceptance path is the [core workflow](CORE_LOOP.md).
