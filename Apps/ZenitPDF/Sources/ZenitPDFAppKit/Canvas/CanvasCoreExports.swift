// NL-PLAT-17 (r2-platform): the canvas's portable half — PageDisplayTransform, ZoomMath,
// ViewportRasterPlanner, AreaPillLayout, DimensionGrammar — lives in Packages/ZPDFCanvasCore so
// an iPad canvas can draw with the same numbers. Re-exported here so every file and test of the
// application reads those names exactly as it did when they lived in this directory.
@_exported import ZPDFCanvasCore
