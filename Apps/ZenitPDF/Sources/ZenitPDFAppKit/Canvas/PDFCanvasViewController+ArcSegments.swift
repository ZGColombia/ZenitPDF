import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell

/// Arc segments while drawing (NL-MEASURE-05, ADR-0030 §5.6).
///
/// A is the Area tool's single key, and it stays that outside a shape in progress. Mid-shape it
/// never switches tools — switching would throw the shape away — and on a length, polylength,
/// perimeter or area it makes the next segment a three-point arc: the next click is a point the
/// arc passes through, the click after it the arc's end. The live overlay draws the arc, and the
/// pill says its length beside the running value.
extension PDFCanvasViewController {

    /// Whether a shape is being placed right now, measurement or markup: a point placed or one
    /// still resolving.
    var isShapeInProgress: Bool {
        if core.measurement.activeKind != nil,
           !core.measurement.placedPoints.isEmpty || core.measurement.hasPlacementsInFlight {
            return true
        }
        return core.markup.activeKind != nil && !core.markup.placedPoints.isEmpty
    }

    /// Whether a tool key — a single-letter tool shortcut or a number slot — belongs to the canvas
    /// right now rather than to the window's tool shortcuts (ADR-0030 §5.7, §5.8). The window's key
    /// router asks this before every tool key, so the two cannot disagree.
    ///
    /// - During a two-point pick — Calibrate, Verify Scale, the Split Area line, Curve an Edge, a
    ///   fence or fall line — every tool key: the clicks go to the pick until it ends, so a tool
    ///   switch would light a tool the next click does not use.
    /// - While a typed length is being entered, every tool key: the letter of "25cm" or "12ft" is
    ///   not a tool switch that throws the shape away.
    /// - While a shape a tool switch would discard is in progress, every tool key. A count group
    ///   is not discarded — a switch commits it — so mid-count only A, the arc
    ///   key, stays here.
    func ownsToolKey(characters: String, modifiers: ZPDFModifierFlags) -> Bool {
        if isCalibrating || !typedEntry.isEmpty { return true }
        if characters == "a", modifiers.isEmpty { return isShapeInProgress }
        return isShapeLostOnToolSwitch
    }

    /// Whether switching tools now would throw a shape away: a measurement other than a count, or
    /// a markup, with a point placed or one still resolving.
    var isShapeLostOnToolSwitch: Bool {
        guard isShapeInProgress else { return false }
        return core.markup.activeKind != nil || core.measurement.activeKind?.isPointPlacement != true
    }

    /// A tool key the window left to the canvas because the canvas owns it (K-02): it never
    /// switches tools here, and the status note says what to do instead. Returns whether the key
    /// was spent; `false` when the canvas does not own tool keys, so the key falls through as before.
    func holdToolKey() -> Bool {
        if isCalibrating {
            core.status.setActiveToolNote(Self.twoPointPickToolNote)
            return true
        }
        guard !typedEntry.isEmpty || isShapeLostOnToolSwitch else { return false }
        core.status.setActiveToolNote(NSLocalizedString(
            "Finish the shape (Return) or cancel it (Esc) before choosing another tool.",
            comment: "Status note when a tool shortcut is pressed while a shape or a typed length is in progress"
        ))
        return true
    }

    /// The note for a tool key pressed during a two-point pick.
    static var twoPointPickToolNote: String {
        NSLocalizedString(
            "Finish or cancel the two-point pick (Esc) before choosing a tool.",
            comment: "Status note when a tool key is pressed while a two-point pick (calibration, split line, curve an edge) is in progress"
        )
    }

    /// The A key. Returns whether it was spent (always: outside a shape it arms Area).
    func handleAreaKey() -> Bool {
        if isCalibrating {
            // The clicks belong to the pick until it ends: arming Area here lit the toolbar's
            // Area while every click still went to the pick (ADR-0030 §5.7).
            core.status.setActiveToolNote(Self.twoPointPickToolNote)
            return true
        }
        guard isShapeInProgress else {
            onShellCommand?(.measureArea)
            return true
        }
        if core.measurement.activeKind != nil {
            prepareMeasurementInputForArc()
            if measurementInputForTesting.acceptsArcToggle {
                routeArcToggle()
                refresh()
                return true
            }
        }
        // A shape in progress whose segments cannot be arcs: A does nothing. Arming Area here
        // would discard the shape the person is drawing.
        core.status.setActiveToolNote(NSLocalizedString(
            "This tool draws straight segments only. Finish or cancel the shape to pick another tool.",
            comment: "Status note when A is pressed mid-shape on a tool whose segments cannot be arcs"
        ))
        return true
    }

    /// The bulges of the placed points, one per point, for the live overlay.
    func liveArcBulges() -> [Double] {
        let measurement = core.measurement
        guard !measurement.placedArcBulges.isEmpty else { return [] }
        return (0..<measurement.placedPoints.count).map { measurement.placedArcBulges[$0] ?? 0 }
    }

    /// "Arc 3.93 m" while an arc segment follows the pointer, for the pill — not for a Length,
    /// whose value already is the arc.
    func liveArcCaption() -> String? {
        guard core.measurement.activeKind != .length,
              let arc = core.measurement.liveArcSegmentField?.displayTextWithUnit, !arc.isEmpty else { return nil }
        return String(
            format: NSLocalizedString("Arc %@", comment: "Live pill: the length of the arc segment being drawn"),
            arc
        )
    }
}
