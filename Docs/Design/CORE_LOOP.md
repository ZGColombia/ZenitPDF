# Core workflow

The primary task is **open a drawing → calibrate → measure → review and export**.
A user must be able to trace a quantity back to the drawing, scale, geometry, and formula
that produced it. Feature breadth must not weaken that chain.

## Acceptance criteria

1. Open a supported drawing with clear loading, failure, and recovery states.
2. Calibrate a known dimension, review units and page/region scope, and verify against another
   known distance. A proposed or preset scale must not be presented as measured evidence.
3. Place a length and an area with visible snap and completion feedback. Canceling a gesture
   must not create an unexplained partial measurement.
4. Review ledger rows, units, warnings, and totals. Cutouts affect their parent; informational
   values must not become unrelated summed quantities.
5. Save and reopen the project with scale, geometry, values, and provenance intact.
6. Export the same quantities and grouping shown by the ledger. Distinguish raw values from
   displayed rounding and explain the selected drawing output mode.

A changed scale needs an explicit decision about existing measurements. Kept values retain
the scale evidence under which they were computed. Recognition proposals need review before
becoming accepted quantities.

[The core-loop runner](../../Scripts/acceptance-core-loop.sh) uses synthetic fixtures.
Its passing result does not replace observing a complete user interaction in the assembled app.
[Quality requirements](../Execution/QUALITY_BAR.md) define numeric and performance criteria.
