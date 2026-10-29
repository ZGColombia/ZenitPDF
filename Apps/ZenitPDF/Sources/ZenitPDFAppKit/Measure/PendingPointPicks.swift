import Foundation

/// The two-click picks that borrow the calibration pick: Verify Scale, Split Area, Curve an Edge,
/// Draw Fence Line and Pick Fall Line. `ProjectWindowController.finishCalibration` hands the two
/// points to the first one armed, before the scale sheet.
///
/// At most one may be armed per document, and none may outlive the calibration that collects its
/// points. Until iteration 1 (R-001) Escape disarmed only Verify Scale and Split Area, so a
/// cancelled Curve an Edge, fence line or fall line took the NEXT calibration's two clicks: the
/// stale fall line rewrote the slope of the markups selected when it was armed, and no scale
/// sheet opened. Every arm site now clears the others first, and every way out of an uncollected
/// calibration clears them all.
@MainActor
enum PendingPointPicks {

    /// Forgets every pending pick of the document.
    static func disarmAll(_ document: ZenitPDFProjectDocument) {
        VerifyScale.disarm(document)
        AreaSplitFlow.disarm(document)
        CurveEdgePick.disarm(document)
        FencePick.disarm(document)
        FallLinePick.disarm(document)
    }

    /// Whether any pick is waiting for the document's calibration points.
    static func anyArmed(_ document: ZenitPDFProjectDocument) -> Bool {
        VerifyScale.isArmed(document) || AreaSplitFlow.isArmed(document) || CurveEdgePick.isArmed(document)
            || FencePick.isArmed(document) || FallLinePick.isArmed(document)
    }
}
