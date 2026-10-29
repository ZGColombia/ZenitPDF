import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
import ZPDFVectorExtraction

/// NL-AUTO-24: ask the drawing's geometry — circles of a radius, lines of a length, parallel
/// lines a distance apart — see the answers highlighted, and commit circles as one count or
/// lines as lengths. Parallel pairs stay highlights: facing lines are not a measured wall.
extension ProjectWindowController {

    /// How the panel reaches the screen, returning its dismissal. A test injects a capture.
    static var geometryQueryPresenter: (@MainActor (GeometryQueryPanelModel, NSWindow?) -> () -> Void) = { model, window in
        guard let window else { return {} }
        let host = NSHostingController(rootView: GeometryQueryPanelView(model: model))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "automation.geometryQuery") {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// The last query's matches, for the commit.
    @MainActor final class GeometryQueryState {
        var circleCentres: [PDFPoint] = []
        var lines: [(PDFPoint, PDFPoint)] = []
        var label = ""
    }

    func beginGeometryQuery(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let core = document.core, let drawing = document.currentPageDrawing,
                  let currentID = core.document.currentPageID,
                  let page = drawing.pages.first(where: { $0.id.rawValue == currentID }) else { return }
            let extraction: VectorPageExtraction
            do {
                extraction = try await self.automationExtraction(for: document, page: page)
            } catch {
                core.status.setActiveToolNote(Self.symbolScheduleExtractionFailureNote(error))
                return
            }
            // Millimetres on a calibrated page, points on one that is not.
            var metresPerPoint: Double?
            if let scale = await core.session.scale(onPage: page.id) {
                let value = scale.matrix.map(PDFPoint(x: 0, y: 0)).distance(to: scale.matrix.map(PDFPoint(x: 1, y: 0)))
                if value.isFinite, value > 0 { metresPerPoint = value }
            }
            let pointsPerUnit = metresPerPoint.map { 1 / ($0 * 1000) } ?? 1
            let unit = metresPerPoint == nil
                ? NSLocalizedString("pt", comment: "Unit label: page points")
                : NSLocalizedString("mm", comment: "Unit label: millimetres")
            let hidden = document.hiddenLayerNames(for: page, snap: false)
            guard let engine = try? GeometryQueryEngine(
                page: extraction,
                pointsPerUnit: pointsPerUnit,
                layerFilter: VectorLayerVisibilityFilter(hiddenLayerIDs: hidden)
            ) else { return }
            let state = GeometryQueryState()
            let box = SheetDismissBox()
            let model = GeometryQueryPanelModel(
                unitLabel: unit,
                onRun: { [weak self, weak document] kind, value, tolerance in
                    let result = await Self.runGeometryQuery(engine, kind: kind, value: value, tolerance: tolerance, state: state)
                    state.label = String(format: "%@ %@ %@", kind.displayName, Self.plain(value), unit)
                    if let self, let document {
                        var overlay = CanvasAutomationOverlay()
                        overlay.hits = result.matchBounds
                        self.canvasController(for: document)?.setAutomationOverlay(overlay)
                    }
                    return result
                },
                onCommit: { [weak self, weak document] kind in
                    guard let self, let document else { return }
                    box.dismiss()
                    self.canvasController(for: document)?.setAutomationOverlay(nil)
                    Task { @MainActor in
                        await self.commitGeometryQuery(kind: kind, state: state, pageID: page.id, core: core)
                    }
                },
                onClose: { [weak self, weak document] in
                    box.dismiss()
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.setAutomationOverlay(nil)
                }
            )
            box.dismiss = Self.geometryQueryPresenter(model, self.window)
        }
    }

    static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Runs one query off the main actor and keeps its matches for the commit.
    static func runGeometryQuery(
        _ engine: GeometryQueryEngine,
        kind: GeometryQueryKind,
        value: Double,
        tolerance: Double,
        state: GeometryQueryState
    ) async -> GeometryQueryPanelResult {
        func rect(_ bounds: VectorBounds) -> PDFRectValue {
            PDFRectValue(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        }
        switch kind {
        case .circles:
            let result = await Task.detached { engine.circles(radius: value, tolerance: tolerance) }.value
            state.circleCentres = result.matches.map { PDFPoint(x: $0.center.x, y: $0.center.y) }
            state.lines = []
            return GeometryQueryPanelResult(
                matchBounds: result.matches.map {
                    PDFRectValue(x: $0.center.x - $0.radiusPoints, y: $0.center.y - $0.radiusPoints,
                                 width: 2 * $0.radiusPoints, height: 2 * $0.radiusPoints)
                },
                truncated: result.truncated,
                refusal: result.wasRejected ? NSLocalizedString("That value cannot be searched for.", comment: "Geometry query refused a value") : nil
            )
        case .lines:
            let result = await Task.detached { engine.segments(ofLength: value, tolerance: tolerance) }.value
            state.lines = result.matches.map { (PDFPoint(x: $0.start.x, y: $0.start.y), PDFPoint(x: $0.end.x, y: $0.end.y)) }
            state.circleCentres = []
            return GeometryQueryPanelResult(
                matchBounds: result.matches.map { rect($0.bounds) },
                truncated: result.truncated,
                refusal: result.wasRejected ? NSLocalizedString("That value cannot be searched for.", comment: "Geometry query refused a value") : nil
            )
        case .parallelPairs:
            let result = await Task.detached { engine.parallelPairs(gap: value, tolerance: tolerance) }.value
            state.circleCentres = []
            state.lines = []
            return GeometryQueryPanelResult(
                matchBounds: result.matches.map { rect($0.bounds) },
                truncated: result.truncated,
                refusal: result.wasRejected ? NSLocalizedString("That value cannot be searched for.", comment: "Geometry query refused a value") : nil
            )
        }
    }

    /// Circles become one count markup, lines one length markup each — one batch, one ⌘Z.
    func commitGeometryQuery(kind: GeometryQueryKind, state: GeometryQueryState, pageID: PageID, core: AppCoreEnvironment) async {
        let documentID = await core.session.documentID
        let now = Date()
        var commands: [DocumentCommand] = []
        switch kind {
        case .circles where !state.circleCentres.isEmpty:
            commands = [.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
                kind: .measurement, tool: .count, subject: state.label,
                geometry: Self.scheduleCountGeometry(pageID: pageID, positions: state.circleCentres),
                createdAt: now, modifiedAt: now
            ))]
        case .lines where !state.lines.isEmpty:
            commands = state.lines.map { start, end in
                .addMarkup(MarkupRecord(
                    id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
                    kind: .measurement, tool: .length, subject: state.label,
                    geometry: MeasurementGeometry(pageID: pageID, points: [start, end]),
                    createdAt: now, modifiedAt: now
                ))
            }
        default:
            return
        }
        do {
            try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString("Geometry Search", comment: "Undo action name for committing geometry search matches")
            )
            await core.commands.settle()
            await core.refresh()
        } catch {
            core.status.setActiveToolNote(String(describing: error))
        }
    }
}
