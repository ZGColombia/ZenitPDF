import AppKit
import CoreGraphics
import Foundation
import os
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRasterAnalysis
import ZPDFSnapEngine
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Auto-trace on a scanned sheet (NL-AUTO-14, first slice): ⌥-click inside a room on a sheet that
/// carries no vector linework, and the room is traced from the pixels — the straight strokes the
/// scan shows, recovered by ``ScanLinework`` — and committed as an area that records it came from
/// the scan (`CaptureMethod.fromScan`, ADR-0031) with the note saying so. Nothing from the scan is
/// a snap target, and nothing is traced without the person's click.
@MainActor
enum ScanTrace {

    /// The largest picture rendered for a trace: 30 megapixels, so an A0 sheet renders at about
    /// 150 dpi and an A3 sheet at the full 300.
    static let maximumPixels = 30_000_000.0
    static let maximumPixelsPerPoint = 300.0 / 72

    /// The confidence recorded on a traced scan area: the proxy linework's own.
    static let confidence = Double(ScanLinework.confidence)

    /// The sheet to read: `pageID`'s own drawing and page in a project of several (U-007), else
    /// the primary drawing's page at `pageIndex`. The index names a page only inside one PDF, so
    /// an added drawing's sheet used to be rendered from the primary drawing's same-index page.
    static func sheet(document: ZenitPDFProjectDocument, pageIndex: Int, pageID: UUID?) -> (drawing: LoadedDrawing, page: ZPDFContracts.PageDescriptor)? {
        guard let drawing = pageID.flatMap(document.loadedDrawing(forPage:)) ?? document.drawing,
              let page = drawing.pages.first(where: { candidate in
                  if let pageID { return candidate.id.rawValue == pageID }
                  return candidate.index == pageIndex
              })
        else { return nil }
        return (drawing, page)
    }

    /// The cache key: the document, the sheet's own drawing's bytes and the page. The digest is
    /// part of it so a document freed and another allocated at the same address never meets the
    /// old sheet, and so two drawings' same-index pages never share an entry.
    static func cacheKey(document: ZenitPDFProjectDocument, pageIndex: Int, pageID: UUID? = nil) -> String? {
        guard let sheet = sheet(document: document, pageIndex: pageIndex, pageID: pageID) else { return nil }
        return "\(ObjectIdentifier(document).hashValue)-\(sheet.drawing.digest.sha256)-\(sheet.page.index)"
    }

    /// The whole sheet as a gray picture, cached per document and page for the session.
    static func raster(document: ZenitPDFProjectDocument, pageIndex: Int, pageID: UUID? = nil) async -> GrayRaster? {
        guard let key = cacheKey(document: document, pageIndex: pageIndex, pageID: pageID) else { return nil }
        if let cached = cache[key] { return cached }
        guard let sheet = sheet(document: document, pageIndex: pageIndex, pageID: pageID) else { return nil }
        let drawing = sheet.drawing, pageIndex = sheet.page.index
        let crop = sheet.page.boxes.crop
        let area = max(1, crop.size.width * crop.size.height)
        let scale = min(maximumPixelsPerPoint, (maximumPixels / area).squareRoot())
        guard let image = try? await drawing.rasterSource.renderRegion(
            pageIndex: pageIndex, region: PDFRect(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height), pixelsPerPoint: scale),
              let raster = GrayRaster(image: image, pageRegion: CGRect(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height))
        else { return nil }
        if cache.count > 4 {
            cache.removeAll()
            prepared.removeAll()
        }
        cache[key] = raster
        return raster
    }

    /// The sheet's linework from the scan, prepared for tracing, cached beside its raster (R-195).
    ///
    /// Only the raster was cached before, so every ⌥-click re-ran ``ScanLinework``'s full-raster
    /// stroke passes and the trace preparation over up to 30 megapixels for the same page. Now
    /// they run once per page, off the main actor, and a click costs one
    /// `RegionTracer.trace(_:click:)`.
    static func preparedTrace(document: ZenitPDFProjectDocument, pageIndex: Int, pageID: UUID? = nil) async -> PreparedTrace? {
        guard let key = cacheKey(document: document, pageIndex: pageIndex, pageID: pageID) else { return nil }
        if let running = prepared[key] { return await running.value }
        guard let raster = await raster(document: document, pageIndex: pageIndex, pageID: pageID) else { return nil }
        if let running = prepared[key] { return await running.value }
        let preparation = Task.detached(priority: .userInitiated) { () -> PreparedTrace in
            ScanTrace.countPreparation()
            return RegionTracer.prepare(primitives: ScanLinework.primitives(in: raster))
        }
        prepared[key] = preparation
        return await preparation.value
    }

    private static var cache: [String: GrayRaster] = [:]
    private static var prepared: [String: Task<PreparedTrace, Never>] = [:]

    /// Preparations run in this process — test observability for R-195.
    nonisolated static var preparationCountForTesting: Int { preparations.withLock { $0 } }
    nonisolated private static let preparations = OSAllocatedUnfairLock(initialState: 0)
    nonisolated static func countPreparation() { preparations.withLock { $0 += 1 } }
}

extension PDFCanvasViewController {

    /// Traces the room under `point` from the page's pixels. Returns whether the scan path
    /// answered (traced, or said why not); `false` hands back to the vector path's refusal.
    func autoTraceOnScan(at point: PDFPointValue, pageID: UUID, pageIndex: Int, isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        guard let context = automationContext, let prepared = await context.scanPreparedTrace(pageID, pageIndex) else { return false }
        let click = PDFPoint(x: point.x, y: point.y)
        let result = await Task.detached(priority: .userInitiated) {
            RegionTracer.trace(prepared, click: click)
        }.value
        guard isCurrent(), core.document.currentPage?.id == pageID, core.measurement.activeKind == .area,
              core.measurement.placedPoints.isEmpty else { return true }
        switch result {
        case .traced(let region):
            core.measurement.appendRawPoints(region.ring.map { PDFPointValue(x: $0.x, y: $0.y) })
            core.measurement.markPlacedPointsCaptured(as: CaptureMethod(kind: .fromScan, confidence: ScanTrace.confidence))
            core.measurement.commitActiveMeasurement()
            core.status.setActiveToolNote(NSLocalizedString(
                "Traced from the scan: this sheet has no vector lines, so the room was read from its pixels. Check the outline before you rely on it.",
                comment: "Auto-trace note on a scanned sheet"))
        case .notClosed:
            core.status.setActiveToolNote(NSLocalizedString(
                "Not traced: on this scan the room's outline does not close (only straight horizontal and vertical lines are read from a scan).",
                comment: "Auto-trace refusal on a scanned sheet"))
        case .tooComplex:
            core.status.setActiveToolNote(AutoTraceWording.tooComplexNote())
        }
        refresh()
        return true
    }
}
