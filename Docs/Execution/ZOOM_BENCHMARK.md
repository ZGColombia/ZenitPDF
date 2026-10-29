# Viewer and zoom benchmark method

Measure the complete interaction: pointer/gesture input, page presentation, markup feedback,
and the settled sharp viewport. One raster call is not a complete zoom benchmark.

## Reproducible inputs

Use generated synthetic fixtures from `Packages/ZPDFTestingSupport`. Record the fixture kind,
seed, page bounds, primitive count, viewport dimensions, backing scale, and gesture sequence.
No private drawing is required or published. Record the runtime/toolchain and hardware with
new benchmark output so results can be interpreted and reproduced.

## Measurements

- Main-thread presentation time per frame, separately from background page rasterization.
- Missed frames during a fixed pinch and pan sequence.
- Time from settled zoom to a sharp viewport, both cold and warm.
- Displayed-raster magnification and integral pixel alignment after settling.
- Cache memory, viewport raster bytes, vector underlay memory, and cancellation behavior.
- Stale-result rejection when rapid gestures or page changes supersede pending work.

Report distributions with sample count and p50/p95/p99, plus failures and outliers. Keep
optimized and debug results distinct. Do not compare timings from different fixtures or
hardware without identifying that difference. Correct output and responsiveness are separate
assertions; a fast but blurry or stale frame fails the interaction requirement.

## Code and gates

`ViewerZoomGateTests` in the app test tier asserts the viewer requirements.
`Scripts/verify-viewer-budgets.sh` runs the optimized timing gate;
`Scripts/build-app-package.sh` includes the app package's debug checks.
The committed values are in [quality-thresholds.json](quality-thresholds.json).
See [QUALITY_BAR](QUALITY_BAR.md) and [Tests](../../Tests/README.md).

Historical private-input timings are not published here and are not current acceptance
results. A release needs fresh results against its own source revision and generated corpus.
