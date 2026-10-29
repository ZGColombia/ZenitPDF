import Foundation

/// The interior tint a closed area gets.
///
/// One number for the canvas and the Inspector: `CanvasPageView` tints an area stored without
/// a fill with its stroke at this alpha, and the Inspector's Fill Colour row shows and starts
/// from the same value, so what the row says is what the page draws. 20 % per the 2026-09-23
/// mockup ("Opacity 20%"), the same alpha the measurement and markup tools now store for a new
/// area (`AppMeasurementToolPresenter.measurementFillAlpha`, `ToolStyleSelection.zenitInk`).
public enum MarkupFillDefaults {

    /// The fill alpha, as a fraction of the stroke's own alpha, for an unfilled closed area.
    public static let derivedAreaFillAlpha: Double = 0.20
}
