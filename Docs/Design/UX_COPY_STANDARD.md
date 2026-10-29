# Interface copy

The interface ships in English only. Number formatting follows the user's locale. Keep stored
numbers and machine-readable interchange separate from localized display strings.

Use direct verbs and familiar drawing terms. Name the affected object, explain what happened,
and offer a concrete next action. Avoid claiming that a proposed scale or recognized boundary
is verified. Distinguish measured, derived, and imported/read values.

| Situation | Copy rule |
|---|---|
| Missing scale | Explain that calibration is needed for the selected tool and identify the page/region |
| Invalid geometry | State the specific problem; preserve enough input to correct it |
| Read-only or damaged file | Explain which action failed and what can still be done |
| Partial result | Name what completed and what was skipped or refused |
| Export complete | Name the created output only after it has been written successfully |
| No result | Explain the search/filter scope; do not describe it as a system failure |
| Unsupported format | Name supported alternatives, such as PDF or DXF for CAD input |

Use the terms in [Information architecture](INFORMATION_ARCHITECTURE.md). Keep labels short,
but do not remove units or qualifications needed to interpret a number. Use plural forms and
format placeholders safely; do not build sentences by concatenating translated fragments.

For quantity displays, use consistent precision and tabular digits. A blank input is not
implicitly zero. A mixed-dimension total is unavailable with a reason, not a misleading number.
