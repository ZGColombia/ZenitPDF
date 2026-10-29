import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Caption control on the canvas (NL-MEASURE-09): a measurement's pill drawn where the person
/// dragged it, with a leader back to its automatic place, and a length beside every segment when
/// the caption asks for them. The offset is stored in page points on the style
/// (`MarkupStyle.measurementCaption`, ADR-0030 §3), so it follows zoom, save and reopen.
extension CanvasPageView {

    /// Arms the placement for one shape's caption: its stored offset (plus a drag in progress)
    /// in view points.
    func beginCaptionPlacement(for shape: CanvasMarkupShape, transform: PageDisplayTransform) {
        guard shape.kind == .measurement else { return }
        captionShapeID = shape.id
        // The one conversion the culling bounds use too (V-011).
        var offset = Self.captionViewOffset(of: shape, transform: transform)
        if let drag = captionDragPreview, drag.id == shape.id {
            offset.width += drag.delta.width
            offset.height += drag.delta.height
        }
        captionViewOffset = offset
    }

    func endCaptionPlacement() {
        captionShapeID = nil
        captionViewOffset = .zero
    }

    /// The box a caption pill is drawn in: the automatic box, moved by the offset, with a leader
    /// from the automatic place when it moved. Every other pill passes through untouched.
    func placedCaptionBox(_ automatic: CGRect, ink: NSColor?) -> CGRect {
        guard let id = captionShapeID else { return automatic }
        let box = automatic.offsetBy(dx: captionViewOffset.width, dy: captionViewOffset.height)
        if captionViewOffset != .zero, let ink {
            let leader = NSBezierPath()
            leader.move(to: CGPoint(x: automatic.midX, y: automatic.midY))
            leader.line(to: CGPoint(x: box.midX, y: box.midY))
            leader.lineWidth = ZPDFStroke.measurement
            leader.setLineDash([3, 2], count: 2, phase: 0)
            ink.setStroke()
            leader.stroke()
        }
        captionFrames[id] = box
        return box
    }

    /// The caption under a view point, among `candidates`, from the frames last drawn.
    func captionHit(at viewPoint: CGPoint, among candidates: Set<UUID>) -> UUID? {
        captionFrames.first { candidates.contains($0.key) && $0.value.insetBy(dx: -2, dy: -2).contains(viewPoint) }?.key
    }

    /// A small neutral pill at every segment's midpoint, offset off the line.
    func drawSegmentLabels(_ shape: CanvasMarkupShape, transform: PageDisplayTransform) {
        guard !shape.segmentLabels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: ZPDFColor.nsColor(.textPrimary)
        ]
        for label in shape.segmentLabels {
            let a = transform.viewPoint(from: label.start), b = transform.viewPoint(from: label.end)
            let length = hypot(b.x - a.x, b.y - a.y)
            let text = label.text as NSString
            let size = text.size(withAttributes: attributes)
            // Too short a segment on screen for its label: skip rather than pile labels up.
            guard length >= size.width * 0.8 else { continue }
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            // Nudged off the line along its normal, so the label never covers the stroke.
            let normal = length > 0 ? CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length) : .zero
            let lift = size.height * 0.9
            let centre = CGPoint(x: mid.x + normal.x * lift, y: mid.y + normal.y * lift)
            let box = CGRect(x: centre.x - size.width / 2 - 3, y: centre.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
            let pill = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            ZPDFColor.nsColor(.elevated).withAlphaComponent(0.92).setFill()
            pill.fill()
            ZPDFColor.nsColor(.border).setStroke()
            pill.lineWidth = ZPDFStroke.hairline
            pill.stroke()
            text.draw(at: CGPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attributes)
        }
    }
}

extension PDFCanvasViewController {

    /// How segment labels are measured and worded on a page (NL-MEASURE-09).
    func segmentLabelling(forPage pageID: UUID) -> CanvasSegmentLabelling {
        CanvasSegmentLabelling.make(snapshot: core.snapshot, page: pageID)
    }

    /// Starts dragging a selected measurement's caption when the press lands on it. Returns
    /// whether it did (the Select tool's drag then belongs to the caption).
    func beginCaptionDrag(at point: PDFPointValue) -> Bool {
        guard let transform = pageView.transform else { return false }
        let view = transform.viewPoint(from: point)
        guard let id = pageView.captionHit(at: view, among: core.canvas.selectedMarkupIDs) else { return false }
        captionDrag = (id: id, start: point)
        pageView.captionDragPreview = (id, .zero)
        return true
    }

    /// Follows the pointer with the caption.
    func moveCaptionDrag(to point: PDFPointValue) -> Bool {
        guard let drag = captionDrag, let transform = pageView.transform else { return false }
        let from = transform.viewPoint(from: drag.start), to = transform.viewPoint(from: point)
        pageView.captionDragPreview = (drag.id, CGSize(width: to.x - from.x, height: to.y - from.y))
        return true
    }

    /// Drops the caption: its offset, in page points, is written to the style as one undo step.
    func endCaptionDrag(at point: PDFPointValue) -> Bool {
        guard let drag = captionDrag else { return false }
        captionDrag = nil
        pageView.captionDragPreview = nil
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        guard dx != 0 || dy != 0 else { return true }
        let core = self.core
        Task { @MainActor in
            guard let record = await core.session.markup(MarkupID(drag.id)) else { return }
            let current = record.style.measurementCaption?.labelOffset ?? PDFPoint(x: 0, y: 0)
            let commands = MeasurementCaptionText.commands(on: [record]) {
                $0.labelOffset = PDFPoint(x: current.x + dx, y: current.y + dy)
            }
            do {
                try await core.commands.performBatch(
                    commands,
                    actionName: NSLocalizedString("Move Label", comment: "Undo action name: a measurement's caption dragged")
                )
            } catch {
                ZenitPDFProjectDocument.reportRefusedEdit(error, core: core)
            }
        }
        return true
    }
}
