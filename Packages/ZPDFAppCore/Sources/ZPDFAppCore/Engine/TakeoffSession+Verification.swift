import Foundation
import ZPDFContracts

/// Scale checks kept with the calibration evidence (NL-MEASURE-04, ADR-0030 §1).
extension TakeoffSession {

    /// Measures a stated dimension at the page's scale and builds the check.
    ///
    /// - Parameters:
    ///   - points: the two picked ends of the dimension, page space.
    ///   - statedLength: what the drawing prints for it, in `statedUnit`.
    /// - Throws: ``DocumentCommandError/noScale(_:)`` on a page with no scale.
    public func scaleVerification(
        page: PageID,
        points: [PDFPoint],
        statedLength: Decimal,
        statedUnit: LengthUnit
    ) throws -> (verification: ScaleVerification, scaleID: ScaleID) {
        guard let scale = pageScale(page) else { throw DocumentCommandError.noScale(page) }
        let result = try measure(tool: .length, geometry: MeasurementGeometry(pageID: page, points: points))
        let measured = result[.planLength]?.value ?? 0
        let verification = ScaleVerification(
            points: points,
            statedLength: .length(statedLength, in: statedUnit),
            statedUnit: statedUnit,
            measuredLength: .length(measured),
            scaleVersion: scale.version,
            verifiedAt: sessionNow
        )
        return (verification, scale.id)
    }

    /// Appends a check to the evidence of the scale it checked, and says whether it was stored.
    ///
    /// A preset or inherited scale has no evidence and gets none (ADR-0019): `false`, and the
    /// caller records the check in History only. A check of a scale version that is no longer
    /// in force is refused with `false` too — it checked a scale that has since changed.
    ///
    /// A check is a record of something that happened, like a History entry, not an edit: it is
    /// not an undo step. The caller marks the document changed so it is saved.
    @discardableResult
    public func recordScaleVerification(_ verification: ScaleVerification, scaleID: ScaleID) -> Bool {
        guard let evidence = evidence(for: scaleID),
              let scale = pageScales.values.first(where: { $0.id == scaleID }),
              scale.version == verification.scaleVersion else { return false }
        restoreEvidence(evidence.appending(verification), for: scaleID)
        return true
    }

    /// The checks stored with a scale's evidence, oldest first.
    public func verifications(for scaleID: ScaleID) -> [ScaleVerification] {
        evidence(for: scaleID)?.verifications ?? []
    }
}
