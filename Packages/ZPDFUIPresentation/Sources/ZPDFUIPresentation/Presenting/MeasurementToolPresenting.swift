import Foundation
import Observation

/// Presents the measurement palette, the live measurement in progress and the unit settings.
@MainActor
public protocol MeasurementToolPresenting: ZenitPresenting {

    /// Every tool the palette offers, in palette order.
    var availableKinds: [MeasurementKind] { get }
    /// The armed tool, or `nil` when the pointer tool is active.
    var activeKind: MeasurementKind? { get }
    /// Recently used tools, newest first. The palette remembers the last-used tool.
    var lastUsedKinds: [MeasurementKind] { get }
    /// The scale the in-progress measurement will be computed against.
    var activeScale: ScaleSummary? { get }
    /// Output unit for length results.
    var lengthUnit: LengthUnit { get }
    /// Output unit for area results.
    var areaUnit: AreaUnit { get }
    /// Output unit for volume results.
    var volumeUnit: VolumeUnit { get }
    /// How slopes are rendered.
    var slopeDisplayMode: SlopeDisplayMode { get }
    /// Fraction precision used for imperial length display.
    var imperialPrecision: ImperialPrecision { get }
    /// Fields of the measurement in progress, updated as points are placed.
    var liveFields: [MeasurementFieldSummary] { get }
    /// Warnings raised by the measurement in progress.
    var liveWarnings: [MeasurementWarningSummary] { get }
    /// Snap feedback for the point being placed, or `nil`.
    var snapFeedback: SnapFeedbackSnapshot? { get }
    /// Points placed so far, in page space.
    var placedPoints: [PDFPointValue] { get }
    /// Whether the measurement in progress is a Temporary Measure, which is never stored.
    var isTemporaryMeasurement: Bool { get }
    /// Temporary measurements accumulated in the overlay.
    var temporaryMeasurements: [MarkupSummary] { get }
    /// Whether ``commitActiveMeasurement()`` would succeed right now.
    var canCommit: Bool { get }
    /// What the estimator has typed into the tool options bar's parameter field.
    ///
    /// Kept as text rather than as a number so a half-typed `"2."` is not thrown away
    /// between keystrokes, and so the exact digits reach `Decimal` without passing through
    /// binary floating point.
    var parameterText: String { get }
    /// ``parameterText`` parsed, in the requirement's entry unit — the active length unit
    /// for a depth, a height or a rise/drop, and a bare percentage for a slope. `nil` when
    /// nothing usable has been typed.
    var parameterValue: Decimal? { get }
    /// Why the armed tool cannot measure anything on this sheet at all, in one sentence, or
    /// `nil` when it can — a circle tool under separate X and Y scales (L-102). Said by the
    /// status line from the moment the tool is armed (``armedToolNote``), before any click.
    var toolUnavailableReason: String? { get }
    /// Where on this sheet the armed tool can measure, in one sentence, when that is only part
    /// of it — a circle tool on a sheet whose own scale and Scale Regions disagree about separate
    /// X and Y (L-102) — or `nil`. Unlike ``toolUnavailableReason`` it blocks nothing; the status
    /// line says it on arming (``armedToolNote``), before a click the other part would refuse.
    var toolRestrictionNote: String? { get }

    /// Arms a measurement tool.
    func activate(kind: MeasurementKind)
    /// Disarms the measurement tool and returns to the pointer.
    func deactivate()
    /// Adds a point to the measurement in progress.
    func placePoint(_ point: PDFPointValue)
    /// Removes the most recently placed point.
    func removeLastPoint()
    /// Discards the measurement in progress.
    func cancelActiveMeasurement()
    /// Commits the measurement in progress as a markup. Does nothing when ``canCommit``
    /// is `false`, so that a blocked measurement is never half-saved.
    func commitActiveMeasurement()
    /// Turns the accumulated temporary measurements into real markups.
    func promoteTemporaryMeasurementsToMarkups()
    /// Clears the accumulated temporary measurements.
    func clearTemporaryMeasurements()
    /// Sets the length output unit.
    func setLengthUnit(_ unit: LengthUnit)
    /// Sets the area output unit.
    func setAreaUnit(_ unit: AreaUnit)
    /// Sets the volume output unit.
    func setVolumeUnit(_ unit: VolumeUnit)
    /// Sets the slope display mode.
    func setSlopeDisplayMode(_ mode: SlopeDisplayMode)
    /// Sets the imperial fraction precision.
    func setImperialPrecision(_ precision: ImperialPrecision)
    /// Sets the tool options bar's parameter field. An empty or unparseable string clears
    /// the value, which puts the armed tool back into "cannot be committed yet".
    func setParameterText(_ text: String)
}

extension MeasurementToolPresenting {

    /// No tool is unavailable unless the presenter says why.
    public var toolUnavailableReason: String? { nil }

    /// No tool is restricted to part of a sheet unless the presenter says where.
    public var toolRestrictionNote: String? { nil }

    /// What the status line says about the armed tool: why it cannot measure on this sheet,
    /// else where on it it can, else the value it is still waiting for, else nothing (L-102).
    public var armedToolNote: String? { toolUnavailableReason ?? toolRestrictionNote ?? missingParameterNote }

    /// The headline field of the measurement in progress, if there is one.
    public var livePrimaryField: MeasurementFieldSummary? {
        guard let activeKind else { return nil }
        return liveFields.first { $0.field == activeKind.primaryField }
    }

    /// Whether any live warning blocks committing.
    public var hasBlockingWarning: Bool { liveWarnings.contains(where: \.isBlocking) }

    /// How many more points the armed tool needs before it can be committed.
    public var remainingPointCount: Int {
        guard let activeKind else { return 0 }
        return max(0, activeKind.minimumPointCount - placedPoints.count)
    }

    /// The value the armed tool needs from the tool options bar, or `nil` when it measures
    /// only what is drawn.
    public var requiredParameter: MeasurementParameterRequirement? {
        activeKind?.requiredParameter
    }

    /// Whether the armed tool needs a parameter it has not been given.
    ///
    /// While this is `true` the measurement cannot be committed, and the tool says why.
    /// It replaces the old behaviour, which was to let the estimator finish, hand the
    /// engine parameters it could not use, and drop the result on the floor.
    public var isMissingRequiredParameter: Bool {
        requiredParameter != nil && parameterValue == nil
    }

    /// The one-line reason the armed tool cannot be committed yet, or `nil`.
    public var missingParameterNote: String? {
        guard let requirement = requiredParameter, parameterValue == nil else { return nil }
        return requirement.missingValueNote
    }

    /// Why Finish would refuse right now, in one spoken sentence — or `nil` when it would
    /// not. A Return that does nothing with nothing said is the silent-commit defect,
    /// and it happened again live (LT-9, 2026-08-29): every refusal a commit can make must
    /// have words here.
    public var commitRefusalReason: String? {
        guard let activeKind else { return nil }
        // A tool that cannot measure on this sheet says that, not "2 more points" (L-102).
        if let reason = toolUnavailableReason { return reason }
        if remainingPointCount > 0 {
            return MeasurementPointPhrases.finishRefusal(activeKind, remaining: remainingPointCount)
        }
        if let note = missingParameterNote { return note }
        if let blocking = liveWarnings.first(where: \.isBlocking) {
            return blocking.message
        }
        return nil
    }
}

/// The one wording for "how many more points the armed tool needs" (W-074).
///
/// The input machine (Return pressed too early, and the point-placed announcement), this
/// presenter's Finish refusal and the toolbar's live readout all state this fact. They used to
/// carry three copies — one hand-rolled `count == 1 ? … : …` that bypassed the plural catalogue
/// — and Return and Finish refused with two different sentences for the same condition
/// ("Area: 2 more points needed." against "Area needs 2 more points before it can be finished.").
public enum MeasurementPointPhrases {

    /// "1 more point" / "3 more points" (BH-785, BH-822, IM-137).
    public static func morePoints(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld more points",
            count: count,
            one: NSLocalizedString("%lld more point", comment: "Count of points still needed, singular"),
            other: NSLocalizedString("%lld more points", comment: "Count of points still needed, plural")
        )
    }

    /// "Area needs 2 more points before it can be finished." — what Return and Finish both say
    /// when the armed tool has too few points.
    public static func finishRefusal(_ kind: MeasurementKind, remaining: Int) -> String {
        String(
            format: NSLocalizedString(
                "%1$@ needs %2$@ before it can be finished.",
                comment: "Status note when Finish is pressed with too few points; tool name and '1 more point'"
            ),
            kind.displayName,
            morePoints(remaining)
        )
    }
}
