import Foundation
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFRasterAnalysis
import ZPDFVectorExtraction

/// What the canvas needs from its document to run automation truthfully, injected by the window
/// controller so the canvas never reaches for the document itself.
///
/// Without it — a canvas built bare in a test — auto-trace still honours the render's hidden
/// layers, and traces only the page whose extraction the canvas holds.
///
/// Every page-reading closure takes the page's identity with its index (U-007): the index names
/// a page only inside its own PDF, so in a project of several drawings an index alone read the
/// primary drawing's same-index sheet — its linework, its pixels and its hidden layers.
struct CanvasAutomationContext {
    /// The marked-content names auto-trace must leave out on a page: the layers the person hid,
    /// and under a measure lock every layer but the locked one — exactly the snap index's set.
    var traceHiddenLayerIDs: @MainActor (_ pageID: UUID, _ pageIndex: Int) -> Set<String>
    /// The trace choices the person made (NL-AUTO-11), without the layer half.
    var traceChoices: @MainActor () -> TraceFilter
    /// The page's layer-aware extraction, fetched through its own drawing's store when the
    /// canvas's own is for another page or cannot stand in for it.
    var extraction: @MainActor (_ pageID: UUID, _ pageIndex: Int) async -> VectorPageExtraction?
    /// Whether the canvas's own extraction can stand in for a layer-aware one: true when the
    /// drawing has no optional-content layers.
    var underlayIsLayerComplete: @MainActor () -> Bool
    /// A traced area was committed with closed outlines inside it; offer them as cutouts.
    var offerIslands: @MainActor (_ pageID: PageID, _ ring: [PDFPoint], _ islands: [[PDFPoint]], _ metresPerPoint: Double?) -> Void = { _, _, _, _ in }
    /// The scanned page's linework, prepared for tracing and cached with its raster (R-195), so
    /// each ⌥-click costs one trace rather than the full-raster stroke passes. `nil` when the
    /// page cannot be rendered.
    var scanPreparedTrace: @MainActor (_ pageID: UUID, _ pageIndex: Int) async -> PreparedTrace? = { _, _ in nil }
}
