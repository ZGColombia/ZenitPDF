import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Measure ▸ Draw Fence Line and Clear Fence Lines (NL-MEASURE-11).
extension ProjectWindowController {

    /// Two clicks — snapped like a calibration pick — draw a fence line on the page on screen.
    func beginFenceLine(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        FencePick.arm(document)
        document.pendingScaleCalibration = nil
        beginCalibration(for: document)
        core.status.setActiveToolNote(NSLocalizedString(
            "Draw Fence Line: click both sides of the opening.",
            comment: "Status note while picking a fence line"
        ))
    }

    func clearFenceLines(for document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let count = canvasController(for: document)?.clearTraceFences() ?? 0
        core.status.setActiveToolNote(Self.fenceLinesClearedNote(count))
    }

    /// The status note after Clear Fence Lines, for every count (W-014: "1 fence line(s)
    /// removed." used to be the only form).
    static func fenceLinesClearedNote(_ count: Int) -> String {
        guard count > 0 else {
            return NSLocalizedString("This page has no fence lines.", comment: "Status note: Clear Fence Lines found none")
        }
        return LocalizedPlural.string(
            "%lld fence lines removed.", count: count,
            one: NSLocalizedString("%lld fence line removed.", comment: "Status note after Clear Fence Lines removed one"),
            other: NSLocalizedString("%lld fence lines removed.", comment: "Status note after Clear Fence Lines; the count")
        )
    }
}

/// The two clicks of a fence line.
@MainActor
enum FencePick {

    private static var pending: Set<UUID> = []

    static func arm(_ document: ZenitPDFProjectDocument) {
        PendingPointPicks.disarmAll(document)
        pending.insert(document.documentIdentity)
    }

    static func isArmed(_ document: ZenitPDFProjectDocument) -> Bool { pending.contains(document.documentIdentity) }

    /// Forgets a pending fence line (Escape, or another pick armed) — R-001.
    static func disarm(_ document: ZenitPDFProjectDocument) { pending.remove(document.documentIdentity) }

    static func finish(points: [PDFPointValue], document: ZenitPDFProjectDocument, canvas: PDFCanvasViewController?) {
        pending.remove(document.documentIdentity)
        guard points.count == 2, let canvas, let core = document.core else { return }
        canvas.addTraceFence(from: points[0], to: points[1])
        core.status.setActiveToolNote(NSLocalizedString(
            "Fence line drawn. ⌥-click the room with Area, Perimeter or Wall Area to trace it.",
            comment: "Status note after a fence line was drawn"
        ))
    }
}
