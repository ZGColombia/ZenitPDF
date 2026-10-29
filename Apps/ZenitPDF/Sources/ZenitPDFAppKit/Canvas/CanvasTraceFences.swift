import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFSnapEngine
import ZPDFUIPresentation

/// One fence line as the page view draws it (NL-MEASURE-11).
struct CanvasFenceLine: Equatable, Sendable {
    let start: PDFPointValue
    let end: PDFPointValue
}

/// Auto-trace upgrades (NL-MEASURE-11): fence lines a person draws across an opening, and trace
/// for Perimeter and Wall Area as well as Area.
///
/// Measure ▸ Draw Fence Line takes two clicks (snapped, like a calibration pick) and keeps the line
/// on the page, drawn dashed and labelled "Fence"; the next ⌥-click trace treats every fence as a
/// wall and says which it closed across, and the committed markup records their widths
/// (ADR-0031's capture method). The tracer's refusal to invent a boundary stands: a fence is a
/// line the person drew and can see. Measure ▸ Clear Fence Lines removes them.
extension PDFCanvasViewController {

    /// The tools ⌥-click traces for: Area, and the two tools whose boundary is a room's outline —
    /// Perimeter (the ring's length) and Wall Area (the ring's length times the height).
    static let traceableKinds: Set<MeasurementKind> = [.area, .perimeter, .wallArea]

    /// Walks the click with the fences drawn in, off the main actor.
    nonisolated static func traceWithFences(
        _ prepared: PreparedTrace,
        click: PDFPoint,
        fences: [ProposedClosure],
        maximumClosureWidth: Double
    ) async -> FencedTraceResult {
        await Task.detached(priority: .userInitiated) {
            RegionTracer.trace(prepared, click: click, fences: fences, maximumClosureWidth: maximumClosureWidth)
        }.value
    }

    /// The status note, with the fences the region closed across named.
    static func fenceNote(_ used: [ProposedClosure], appendedTo note: String) -> String {
        guard !used.isEmpty else { return note }
        // W-014: one and other forms ("Closed by 1 fence line(s)." used to be the only one).
        return note + " " + LocalizedPlural.string(
            "Closed by %lld fence lines.", count: used.count,
            one: NSLocalizedString("Closed by %lld fence line.", comment: "Auto-trace note: the traced region closed across one fence line"),
            other: NSLocalizedString("Closed by %lld fence lines.", comment: "Auto-trace note: how many fence lines the traced region closed across")
        )
    }

    /// Adds a fence line on the page on screen.
    func addTraceFence(from start: PDFPointValue, to end: PDFPointValue) {
        guard let pageID = core.document.currentPage?.id else { return }
        let fence = ProposedClosure(start: PDFPoint(x: start.x, y: start.y), end: PDFPoint(x: end.x, y: end.y))
        guard fence.width > 0 else { return }
        traceFences[pageID, default: []].append(fence)
    }

    /// Removes every fence line on the page on screen. Returns how many there were.
    @discardableResult
    func clearTraceFences() -> Int {
        guard let pageID = core.document.currentPage?.id else { return 0 }
        let count = traceFences[pageID]?.count ?? 0
        traceFences[pageID] = nil
        return count
    }

    /// ⇧⌥-click with exactly one area selected: the traced face is added to that area as one
    /// `editVertices` (``TracedUnion``).
    ///
    /// `id` is the area selected **at the click**, which the click's own ⇧ asked to add to: the
    /// trace lands after an extraction and a walk, and this used to read the live ⇧ state and the
    /// live selection then — a ⇧⌥-click released before a slow trace finished traced a separate
    /// room, and a ⌥-click followed by pressing ⇧ rewrote the selected area (V-009).
    func unionTracedFace(_ ring: [PDFPoint], into id: UUID) {
        let core = self.core
        Task { @MainActor [weak self] in
            guard let record = await core.session.markup(MarkupID(id)) else { return }
            do {
                // A gap the union closes around is kept open as a cutout, in the same step (K-10).
                let plan = try TracedUnion.plan(adding: ring, to: record)
                try await core.commands.performBatch(plan.commands, actionName: NSLocalizedString(
                    "Add Traced Room", comment: "Undo action name: a traced face added to the selected area"
                ))
                core.status.setActiveToolNote(plan.statusNote ?? NSLocalizedString(
                    "Traced and added to the selected area.",
                    comment: "Auto-trace note: a face was unioned into the selected area"
                ))
            } catch TracedUnion.Refusal.apart {
                core.status.setActiveToolNote(NSLocalizedString(
                    "That room does not touch the selected area, so it was not added. ⌥-click without Shift to trace it on its own.",
                    comment: "Auto-trace note: the traced face is apart from the selected area"
                ))
            } catch TracedUnion.Refusal.enclosesGap {
                // ADR-0030 §5.7: stored, the gap's hole would be erased on the next recompute and
                // counted as area.
                core.status.setActiveToolNote(NSLocalizedString(
                    "Adding that room would close the area around a gap it cannot keep open, so it was not added.",
                    comment: "Auto-trace note: the union with the traced face would enclose a hole"
                ))
            } catch TracedUnion.Refusal.curvedEdgeNotExact {
                core.status.setActiveToolNote(AreaSplitRefusal.curvedEdgeNotExact.message)
            } catch {
                core.status.setActiveToolNote(NSLocalizedString(
                    "Select one plain area without cutouts to add traced rooms to it.",
                    comment: "Auto-trace note: the selection cannot take a traced face"
                ))
            }
            self?.refresh()
        }
    }

    /// Keeps the page view's fence lines in step with the page on screen.
    func refreshTraceFenceLines() {
        let current = core.document.currentPage?.id
        pageView.traceFenceLines = (current.flatMap { traceFences[$0] } ?? []).map {
            CanvasFenceLine(start: PDFPointValue(x: $0.start.x, y: $0.start.y), end: PDFPointValue(x: $0.end.x, y: $0.end.y))
        }
    }
}

extension CanvasPageView {

    /// Fence lines: dashed, in the snap accent, each labelled "Fence" in words.
    func drawTraceFences(transform: PageDisplayTransform) {
        guard !traceFenceLines.isEmpty else { return }
        let ink = CanvasMarkupStyle.onPaper(.accentBlue)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: ZPDFColor.nsColor(.textPrimary)
        ]
        let label = NSLocalizedString("Fence", comment: "Canvas label on a fence line drawn for auto-trace") as NSString
        let size = label.size(withAttributes: attributes)
        for fence in traceFenceLines {
            let a = transform.viewPoint(from: fence.start), b = transform.viewPoint(from: fence.end)
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = ZPDFStroke.emphasis
            path.setLineDash([6, 3], count: 2, phase: 0)
            ink.setStroke()
            path.stroke()
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let box = CGRect(x: mid.x - size.width / 2 - 3, y: mid.y - size.height - 6, width: size.width + 6, height: size.height + 2)
            let pill = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            ZPDFColor.nsColor(.elevated).withAlphaComponent(0.92).setFill()
            pill.fill()
            ink.setStroke()
            pill.lineWidth = ZPDFStroke.hairline
            pill.stroke()
            label.draw(at: CGPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attributes)
        }
    }
}
