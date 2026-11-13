# ADR-0045 — Continuous scrolling as one strip with one live page

Status: Accepted.

## Decision and rationale

A document of several pages scrolls as one vertical strip of sheets. The canvas keeps exactly one *live* page — the current page, which the tools, the hit test, the scene and the raster pipeline act on — and lays it out in its slot of the strip. The other sheets in or near the view are *passive*: each is a `CanvasRasterLayerView` and a `CanvasPageView` in passive mode, the same two classes the live page is drawn with, so a sheet looks the same whichever role it has. A passive sheet takes no events, keyboard, cursor, tracking or accessibility; the live page view, which spans the whole document view, owns all of them.

`PageStripLayout` (`ZPDFCanvasCore`) is the geometry: slots stacked top to bottom on a shared centre line, with a 24-page-point gap that scales with the zoom. The strip is therefore an exact similarity under zoom, and the zoom-about-a-point arithmetic of the single page holds for any point on any sheet. For one page the slot origin is the pan margin, the single-page layout exactly.

The current page follows the view. After a scroll, the page with the largest visible area becomes current through `AppDocumentPresenter.followView(toPage:settle:)`, followed by one synchronous layout and scene re-filter in the same run-loop turn, so the hand-off moves nothing on screen. A challenger needs 20 % more area than the current page; between two sheets wholly in view, the one under the centre line wins; at most one hand-off happens per 100 ms. The follow rule does not run during a pinch, a zoom animation or a pinch's commit.

The shared `CanvasTileCache` is the hand-off: passive sheets plan with `ViewportRasterPlanner` in document coordinates exactly as the live page does and store their tiles under the same grid. When a sheet becomes live, every cell it showed is already cached and nothing is rendered; when the live page becomes passive, it reads the same tiles back. A passive sheet's stand-in is the 2048-pixel thumbnail the Navigator and the live base raster use, or 512 pixels for a small sheet.

`followView` is not a navigation. It does not move `navigationSerial`, keeps a Navigator multi-selection, and with `settle` off defers the snap-index build and the scale offer by 250 ms, so a fling across many sheets starts no extraction for the sheets it passes. A navigation — Navigator, page keys, page field, search hit, bookmark, a removed page's fallback — moves the serial, and the canvas rests the page: its top edge 16 points below the viewport's top, or the whole sheet centred when it fits. A page made current by a navigation or a press stays current until the person scrolls or zooms at a point, even beside a larger neighbour that shows more of itself.

Work in progress holds the current page: placed measurement or markup points, an arc's through point, an armed boundary capture, an open text box, a calibration point, a drag, a typed length or the keyboard cursor, an opening proposal, a Scale Region draft or calibration destination, or a borrowed two-click pick. Scrolling never cancels it. A press on another sheet makes that sheet current before the press is interpreted, unless the page is held; then the press is ignored, as a press off the sheet always was.

## Limits

- While PDF layer overrides are active, the canvas shows one page at a time and says so in the status bar. A passive sheet rendered natively would show a layer the person has hidden; per-page layer filters on passive sheets are future work.
- A strip taller than 2¹⁹ points (a long document at a high zoom) lays out a window of pages around the current one — always with that page's two neighbours, so a sheet taller than half the bound can still be scrolled off — and re-bases it, by whole points and without moving the view, when the view nears its edge. While work holds the current page the window must keep it, so the view stops at the window's edge and the status bar says why. Core Animation's exactness at tens of millions of points could not be shown without a display, so magnitudes stay within a factor of two of what single-page layout already reaches. The scrollers then span the window, not the document.
- Level tiles during a pinch, the vector underlay and the render notice remain live-page only. A turned or cropped sheet has no stand-in raster, as on the live page.
- Split Canvas panes and a second window keep their own single-page behaviour.

## Setting

One app-wide preference, `ZenitCanvasPreferences.pageLayout`: View ▸ Continuous Scroll and Settings ▸ Canvas ▸ Continuous scrolling, continuous by default. Single-page mode, and every one-page document, behave exactly as before, including the overscroll page turn. Switching keeps the page and the place on it.

## Verification

- `PageStripLayoutTests` (`ZPDFCanvasCore`): slots, similarity, gaps, the visible range on 323 pages, the follow rule and its hysteresis, the window.
- `AppDocumentPresenterFollowViewTests` (`ZPDFAppCore`): selection, the navigation count and the dwell.
- `CanvasContinuousScrollTests` (app tier): hand-off moves and renders nothing, the page lock, press adoption, navigation, zoom anchors, pinch commit, virtualisation, layer overrides, the setting.
