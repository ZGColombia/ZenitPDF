import Foundation
import OSLog

/// The canvas's log.
///
/// It exists so a refused raster is visible rather than silent. Gate Z8 turns a raster the
/// budget will not allow into a typed error, and a typed error nobody records is the same
/// thing as a clamp: the user sees a page that did not sharpen and has no way to find out
/// why. Nothing here logs a file path or a page's content.
enum CanvasLog {
    static let logger = Logger(subsystem: "com.zenitgroup.zenitpdf", category: "canvas")

    /// Printing and the flattened export shapes.
    ///
    /// Same reason as above, one artefact further out: a sheet whose markups the flatten path
    /// refused prints without them, and a printed drawing that quietly lost a dimension is the
    /// defect this whole path was built to close. It must be findable in the log.
    static let printing = Logger(subsystem: "com.zenitgroup.zenitpdf", category: "printing")
}

extension CanvasLog {
    /// Intervals for Instruments (NL-PERF-01): `ZoomGestureFrame`, `LayoutPage`, `CanvasDraw`,
    /// `TileRender`, `TileDeliver`, `UnderlayRender`. They cost nothing while no tool records,
    /// and they let one "Animation Hitches" trace attribute any hitch that remains.
    static let signposter = OSSignposter(subsystem: "com.zenitgroup.zenitpdf", category: "canvas.performance")
}
