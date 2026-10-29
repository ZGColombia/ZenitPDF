import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell

/// Applies the input state machine's effects to the shipping canvas (IM-019).
///
/// `PDFCanvasViewController` no longer decides what a measurement click, press, release,
/// double-click, secondary click or key means: it feeds the event to its
/// ``MeasurementInputController`` and this object carries out what the machine decided. The
/// machine says *what* happens — place a point, commit, cancel, remove a mark — and this says
/// *how*, which on the canvas is not a bare presenter call:
///
/// - a commit goes through the shell's Finish (`ZPDFCommandID.finishGeometry`), which settles
///   in-flight snaps behind a fence, speaks a refusal and honours Reuse Tool. Where the canvas
///   used to wait for its own clicks to land before finishing — the last click of a
///   fixed-count tool, a drag release, a double-click, a secondary click — the wait and its
///   guard are kept here exactly;
/// - Escape's cancel goes to the shell's Cancel (`.cancelTool`), which backs out one level;
/// - a Shift-constrained point is stored as placed, never re-snapped off its ray;
/// - a drag release, a three-point rectangle's derived corner and a ⌥-click rectangle are
///   expanded from the presenter's *settled* points, as before.
///
/// The per-event ``Gesture`` is set by the canvas around each `send(_:)`; it is how one machine
/// effect maps to the one presenter or shell call the canvas has always made for that gesture.
@MainActor
final class CanvasMeasurementDriver: MeasurementInputEffectApplying, CountPointEditing, CutoutCommitting, ArcSegmentDrawing {

    /// What the event being applied was, as far as effect application cares.
    enum Gesture: Equatable {
        /// No routed event: preparation events (pointer, modifiers, snap list) apply nothing.
        case none
        /// A click. `constrained` when Shift holds the point to a ray, so it is stored raw.
        case click(constrained: Bool)
        /// A ⌥-click that completes a three-point rectangle from two placed vertices.
        case optionRectangle
        /// A ⌥-click on a count mark, with the hit tolerance in page units.
        case optionRemoval(point: PDFPointValue, tolerance: Double)
        /// The press of a one-gesture drag tool.
        case dragPress
        /// The release of a one-gesture drag tool.
        case dragRelease
        /// A drag abandoned after its release was refused.
        case abandonDrag
        /// A double-click, with the tolerance inside which a last vertex duplicates the one before.
        case doubleClick(duplicateTolerance: Double)
        /// A two-finger tap or right click.
        case secondaryClick
        /// Escape.
        case escape
        /// Return.
        case finishKey
        /// Backspace / Delete.
        case removeKey
    }

    private let measurement: AppMeasurementToolPresenter
    private let canvas: AppCanvasPresenter
    private let shellCommand: @MainActor (ZPDFCommandID) -> Void

    private(set) var gesture: Gesture = .none
    /// Points the machine placed during the current event, in order.
    private var placedThisEvent: [PDFPointValue] = []
    /// Shell commands issued during the current event, in order.
    private(set) var shellCommandsThisEvent: [ZPDFCommandID] = []
    /// Whether the current event committed, however the commit was carried out.
    private(set) var committedThisEvent = false
    /// A double-click's duplicate last vertex, to drop once the snaps have landed.
    private var dropsDuplicateAfterSettle = false
    /// Deferred commits still waiting for the snap queue.
    private var deferredWorkCount = 0
    /// Commits this driver has carried out or scheduled. A test seam.
    private(set) var commitCountForTesting = 0

    init(
        measurement: AppMeasurementToolPresenter,
        canvas: AppCanvasPresenter,
        shellCommand: @escaping @MainActor (ZPDFCommandID) -> Void
    ) {
        self.measurement = measurement
        self.canvas = canvas
        self.shellCommand = shellCommand
    }

    /// Whether anything this driver started has not reached the presenter yet — a click's snap
    /// resolve, or a commit waiting for one. While it is, the machine's own vertex list is the
    /// better answer and the canvas does not re-synchronise it from the presenter.
    var hasWorkInFlight: Bool { deferredWorkCount > 0 || measurement.hasPlacementsInFlight }

    /// Opens one routed event.
    func begin(_ gesture: Gesture) {
        self.gesture = gesture
        placedThisEvent = []
        shellCommandsThisEvent = []
        committedThisEvent = false
        dropsDuplicateAfterSettle = false
    }

    /// Closes the routed event.
    func end() {
        gesture = .none
        placedThisEvent = []
    }

    // MARK: - MeasurementInputEffectApplying

    func activate(kind: MeasurementKind) {
        measurement.activate(kind: kind)
    }

    func deactivate() {
        if gesture == .escape {
            issueOnce(.cancelTool)
        } else {
            measurement.deactivate()
        }
    }

    func placePoint(_ point: PDFPointValue) {
        placedThisEvent.append(point)
        switch gesture {
        case let .click(constrained):
            // The second point of a click is the three-point rectangle's derived corner; it is
            // computed from the presenter's settled corners when the commit runs.
            guard placedThisEvent.count == 1 else { return }
            measurement.setPage(PageID(canvas.viewport.pageID))
            if constrained {
                // The committed point is the constrained point: stored
                // raw, because re-resolving the snap would yank it off the ray again.
                measurement.appendRawPoints([point])
            } else {
                // The snap engine's answer already wins over the raw pointer; the presenter
                // resolves it once more on the session so the stored point is the snapped one.
                measurement.placePoint(point)
            }
        case .optionRectangle, .dragRelease:
            // Applied when the commit runs: the depth point and derived corner as placed, the
            // drag's opposite corner expanded to the full outline.
            break
        case .dragPress:
            measurement.setPage(PageID(canvas.viewport.pageID))
            measurement.placePoint(point)
        default:
            measurement.placePoint(point)
        }
    }

    func removeLastPoint() {
        switch gesture {
        case .doubleClick:
            dropsDuplicateAfterSettle = true
        case .removeKey:
            // The window fences and settles in-flight placements before it removes (LT-6).
            issueOnce(.removeLastVertex)
        default:
            measurement.removeLastPoint()
        }
    }

    func commitActiveMeasurement() {
        committedThisEvent = true
        commitCountForTesting += 1
        let kind = measurement.activeKind
        switch gesture {
        case .click:
            guard let kind, !placedThisEvent.isEmpty else {
                // Clicking the first vertex again closes the polygon on the spot.
                issueFinish()
                return
            }
            if kind.derivesFourthCorner, placedThisEvent.count == 2 {
                // The three-point rectangle finishes itself on the third click, deriving the
                // fourth corner from the three *settled* corners.
                afterSettling { [measurement] in
                    guard measurement.activeKind == kind else { return false }
                    let placed = measurement.placedPoints
                    guard placed.count == 3 else { return false }
                    measurement.appendRawPoints([
                        MeasurementInputStateMachine.derivedFourthCorner(placed[0], placed[1], placed[2])
                    ])
                    return true
                }
            } else {
                // Two clicks and done: a fixed-count tool commits on its last click once that
                // click has landed.
                afterSettling { [measurement] in
                    guard measurement.activeKind == kind else { return false }
                    let completing = kind.completingPointCount ?? kind.minimumPointCount
                    return measurement.placedPoints.count >= completing
                }
            }
        case .optionRectangle:
            // Area's third gesture: `P4 = P1 + P3 − P2`, committed at once.
            measurement.appendRawPoints(placedThisEvent)
            issueFinish()
        case .dragRelease:
            guard let kind, let release = placedThisEvent.last else {
                issueFinish()
                return
            }
            afterSettling { [measurement] in
                guard measurement.activeKind == kind, let anchor = measurement.placedPoints.first else {
                    return false
                }
                // The three remaining corners are derived from the two snapped opposite
                // corners, so no second snap resolve can bend the rectangle.
                let corners = AppMeasurementToolPresenter.rectangleCorners(anchor: anchor, opposite: release)
                measurement.appendRawPoints(Array(corners.dropFirst()))
                return true
            }
        case let .doubleClick(tolerance):
            forwardDoubleClickFinish(duplicateTolerance: tolerance)
        case .secondaryClick:
            guard let kind else { return }
            afterSettling { [measurement] in
                guard measurement.activeKind == kind, kind.completingPointCount == nil else { return false }
                return measurement.placedPoints.count >= kind.minimumPointCount
            }
        case .none, .optionRemoval, .dragPress, .abandonDrag, .escape, .finishKey, .removeKey:
            issueFinish()
        }
    }

    func cancelActiveMeasurement() {
        switch gesture {
        case .escape:
            // Escape backs out one level through the shell, which knows about canvas modes,
            // registered workflow modes and Reuse Tool.
            issueOnce(.cancelTool)
        default:
            measurement.cancelActiveMeasurement()
        }
    }

    // MARK: - CountPointEditing

    func removePoint(at index: Int) {
        if !measurement.hasPlacementsInFlight {
            // The machine was synchronised from the presenter before this event, so its index
            // is the presenter's index.
            measurement.removePoint(at: index)
        } else if case let .optionRemoval(point, tolerance) = gesture {
            // A mark still resolving has no settled index yet: remove by position, the rule the
            // presenter applies to its own list.
            measurement.removePoint(near: point, tolerance: tolerance)
        }
    }

    // MARK: - ArcSegmentDrawing (NL-MEASURE-05)

    var isArcNextSegment: Bool { measurement.isArcNextSegment }
    var arcThroughPoint: PDFPointValue? { measurement.arcThroughPoint }
    /// The presenter's answer: no arc during a Scale Region or Project Zone boundary capture
    /// (ADR-0030 §5.7). The protocol's default would have said yes.
    var drawsArcSegments: Bool { measurement.drawsArcSegments }

    func setArcNextSegment(_ isArc: Bool) {
        measurement.setArcNextSegment(isArc)
    }

    /// The arc's through point, snapped on the session like a click's vertex and queued behind
    /// the vertices already clicked.
    func placeArcThroughPoint(_ point: PDFPointValue) {
        measurement.setPage(PageID(canvas.viewport.pageID))
        // A Shift-held or typed click is stored as placed, like its vertex would be; any other
        // click snaps on the session.
        if case .click(constrained: true) = gesture {
            measurement.placeArcThroughPoint(point, snapping: false)
        } else {
            measurement.placeArcThroughPoint(point)
        }
    }

    func removeArcThroughPoint() {
        measurement.removeArcThroughPoint()
    }

    // MARK: - CutoutCommitting

    func commitActiveCutout(parentMarkupID: UUID) {
        // The shell's Finish commits through the presenter, which sends a cutout with a parent
        // to `DocumentCommand.addCutout` — never `.addMarkup`.
        measurement.cutoutParentID = MarkupID(parentMarkupID)
        commitActiveMeasurement()
    }

    // MARK: - Finishing

    /// A double-click's finish: settle, drop the duplicate last vertex the machine found, then
    /// hand Finish to the shell. Also used for a double-click the machine refused, so the shell
    /// still speaks the refusal exactly as it always did.
    func forwardDoubleClickFinish(duplicateTolerance: Double) {
        let dropsDuplicate = dropsDuplicateAfterSettle
        afterSettling { [measurement] in
            let points = measurement.placedPoints
            if dropsDuplicate, points.count >= 2,
               points[points.count - 1].distance(to: points[points.count - 2]) <= duplicateTolerance {
                measurement.removeLastPoint()
            }
            return true
        }
    }

    /// Hands Finish to the shell unless this event already did.
    func issueFinishIfNeeded() {
        guard !shellCommandsThisEvent.contains(.finishGeometry) else { return }
        issueFinish()
    }

    private func issueFinish() {
        shellCommandsThisEvent.append(.finishGeometry)
        shellCommand(.finishGeometry)
    }

    private func issueOnce(_ command: ZPDFCommandID) {
        guard !shellCommandsThisEvent.contains(command) else { return }
        shellCommandsThisEvent.append(command)
        shellCommand(command)
    }

    /// Waits for every in-flight placement, runs `prepare`, and hands Finish to the shell when
    /// it returns `true` — the shape of every deferred finish the canvas has had.
    private func afterSettling(_ prepare: @escaping @MainActor () -> Bool) {
        deferredWorkCount += 1
        let shellCommand = self.shellCommand
        Task { @MainActor [weak self, measurement] in
            await measurement.settlePlacements()
            if prepare() { shellCommand(.finishGeometry) }
            self?.deferredWorkCount -= 1
        }
    }
}

/// Applies the calibration flow's effects: two reference points, snapped on the session and
/// Shift-constrained after the snap, exactly as before (IM-019).
///
/// Calibration is a two-point completing gesture, which is what the machine's Length semantics
/// are; the machine counts the clicks and decides Escape, and this carries both out.
@MainActor
final class CanvasCalibrationDriver: MeasurementInputEffectApplying {

    private let place: @MainActor (PDFPointValue) -> Void
    private let end: @MainActor () -> Void

    init(place: @escaping @MainActor (PDFPointValue) -> Void, end: @escaping @MainActor () -> Void) {
        self.place = place
        self.end = end
    }

    func activate(kind: MeasurementKind) {}
    /// Escape over an armed calibration with no point placed.
    func deactivate() { end() }
    func placePoint(_ point: PDFPointValue) { place(point) }
    func removeLastPoint() {}
    /// Nothing to do: the second reference point ends calibration when its snap lands.
    func commitActiveMeasurement() {}
    /// Escape with one reference point placed.
    func cancelActiveMeasurement() { end() }
}
