import Foundation

/// The picked points and the entered real-world length behind a calibrated scale (ADR-0007).
///
/// This is the evidence a "How this number was calculated" panel shows for a scale whose source
/// is ``ScaleSource/calibrationTwoPoint`` or ``ScaleSource/calibrationXY``: which points on the
/// page were picked, and what real length the user said they span. For a preset or inherited
/// scale there is no evidence, and the field is absent rather than fabricated.
public struct CalibrationEvidence: Codable, Hashable, Sendable {
    /// The calibration points, in PDF page space. Two for a two-point calibration, four for a
    /// separate X-Y calibration (X pair first, then Y pair).
    public let points: [PDFPoint]
    /// The real-world length the user entered, in SI base units (metres).
    public let enteredLength: DecimalQuantity
    /// The unit the user typed the length in, kept so the panel can echo "5.000 m" exactly as
    /// it was entered rather than re-deriving a display unit.
    public let enteredUnit: LengthUnit
    /// The Y line's entered length, in metres, for a separate X-Y calibration (ADR-0019).
    ///
    /// `enteredLength` is the X line's. Absent for a two-point calibration, and absent in every
    /// record written before ADR-0019, which decode unchanged.
    public let secondaryEnteredLength: DecimalQuantity?
    /// Checks of this calibration against other dimensions the drawing states, oldest first
    /// (NL-MEASURE-04, ADR-0030).
    ///
    /// Absent until the first check, and absent in every record written before ADR-0030, which
    /// decode unchanged. A check never changes the scale; it is evidence about it.
    public let verifications: [ScaleVerification]?

    public init(
        points: [PDFPoint],
        enteredLength: DecimalQuantity,
        enteredUnit: LengthUnit,
        secondaryEnteredLength: DecimalQuantity? = nil,
        verifications: [ScaleVerification]? = nil
    ) {
        self.points = points
        self.enteredLength = enteredLength
        self.enteredUnit = enteredUnit
        self.secondaryEnteredLength = secondaryEnteredLength
        self.verifications = verifications
    }

    /// The same evidence with one more check appended.
    public func appending(_ verification: ScaleVerification) -> CalibrationEvidence {
        CalibrationEvidence(
            points: points,
            enteredLength: enteredLength,
            enteredUnit: enteredUnit,
            secondaryEnteredLength: secondaryEnteredLength,
            verifications: (verifications ?? []) + [verification]
        )
    }
}

/// One check of a scale against a second dimension the drawing states (NL-MEASURE-04,
/// ADR-0030): two picked points, the length the drawing prints for them, and what they measure
/// at the scale version checked.
public struct ScaleVerification: Codable, Hashable, Sendable {
    /// The two picked points, in PDF page space.
    public let points: [PDFPoint]
    /// The length the drawing states for the line, in metres.
    public let statedLength: DecimalQuantity
    /// The unit the stated length was typed in, echoed verbatim.
    public let statedUnit: LengthUnit
    /// What the line measures at the scale, in metres.
    public let measuredLength: DecimalQuantity
    /// The revision of the scale that was checked (spec 10.6).
    public let scaleVersion: Int
    /// When the check ran. From an injected clock.
    public let verifiedAt: Date

    public init(
        points: [PDFPoint],
        statedLength: DecimalQuantity,
        statedUnit: LengthUnit,
        measuredLength: DecimalQuantity,
        scaleVersion: Int,
        verifiedAt: Date
    ) {
        self.points = points
        self.statedLength = statedLength
        self.statedUnit = statedUnit
        self.measuredLength = measuredLength
        self.scaleVersion = scaleVersion
        self.verifiedAt = verifiedAt
    }

    /// `measured ÷ stated − 1`, exact in `Decimal`; `nil` for a zero stated length.
    public var deviation: Decimal? {
        guard statedLength.value != 0 else { return nil }
        return measuredLength.value / statedLength.value - 1
    }
}

/// Everything a measured value was computed *from*, captured at the moment of computation
/// (ADR-0007 §1).
///
/// A quantity with no traceable derivation is a rumour. This record is the derivation: the
/// geometry (by digest), the scale revision in force, where that scale came from, the slope and
/// parameters applied, and the exact engine build that ran the formula. It is persisted
/// alongside the value, not recomputed later — if it is not captured now, the data is simply
/// not recoverable afterwards.
public struct MeasurementProvenance: Codable, Hashable, Sendable {
    /// Stable hash of the canonical page-space geometry encoding the value was computed from.
    /// Two identical drawings digest identically on every machine and in every build.
    public let geometryDigest: String
    /// Which scale was in force.
    public let scaleID: ScaleID
    /// The page that scale belongs to (spec 10.5).
    ///
    /// Recorded so the disclosure can say *"1:50, calibrated on page 3"* and be right about the
    /// page as well as the ratio. `scaleID` alone cannot answer it after the fact: the scale it
    /// names may since have been deleted, and a derivation that has to look elsewhere to finish
    /// its own sentence is not a derivation. `nil` only for a scale that has no page — a bare
    /// engine call outside a document, or a value read from a project written before per-page
    /// scale — never for a measurement this application computed.
    public let scalePageID: PageID?
    /// Which revision of that scale (spec 10.6).
    public let scaleVersion: Int
    /// Two-point calibration / separate X-Y / preset / inherited (spec 10.2-10.5).
    public let scaleSource: ScaleSource
    /// The picked points and entered real-world length, for a calibrated scale. Absent for a
    /// preset or inherited scale — never fabricated.
    public let calibrationEvidence: CalibrationEvidence?
    /// The slope in force: magnitude, fall-line azimuth and mode (ADR-0004).
    public let slope: SlopeSpecification
    /// Depth, height, cutout policy, perimeter policy, volume depth reference — the full
    /// parameter set the engine received.
    public let parameters: MeasurementParameters
    /// Which calculation revision produced the value (``ContractVersion/measurementFormulaVersion``).
    public let formulaVersion: Int
    /// Build identity of the engine that ran, for example an app version string.
    public let engineVersion: String
    /// When the value was computed. From an injected clock, never the wall clock directly.
    public let computedAt: Date
    /// The document layer the markup was drawn against. Reserved by ADR-0007 §5 so history and
    /// layers agree when the layer model lands; `nil` until then.
    public let layerName: String?
    /// How the geometry was captured — by a person, or by a detector a person accepted
    /// (NL-AUTO-18, ADR-0031). Absent means manual, which is what every record written before
    /// ADR-0031 decodes as. Kept across a recalculation while the geometry is unchanged.
    public let captureMethod: CaptureMethod?

    public init(
        geometryDigest: String,
        scaleID: ScaleID,
        scalePageID: PageID? = nil,
        scaleVersion: Int,
        scaleSource: ScaleSource,
        calibrationEvidence: CalibrationEvidence? = nil,
        slope: SlopeSpecification,
        parameters: MeasurementParameters,
        formulaVersion: Int,
        engineVersion: String,
        computedAt: Date,
        layerName: String? = nil,
        captureMethod: CaptureMethod? = nil
    ) {
        self.geometryDigest = geometryDigest
        self.scaleID = scaleID
        self.scalePageID = scalePageID
        self.scaleVersion = scaleVersion
        self.scaleSource = scaleSource
        self.calibrationEvidence = calibrationEvidence
        self.slope = slope
        self.parameters = parameters
        self.formulaVersion = formulaVersion
        self.engineVersion = engineVersion
        self.computedAt = computedAt
        self.layerName = layerName
        self.captureMethod = captureMethod
    }
}
