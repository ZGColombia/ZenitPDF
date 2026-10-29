import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Verify Scale's store (NL-MEASURE-04, ADR-0030 §1): the check is measured by the session's own
/// engine, kept with the calibration evidence when the scale has any, and always listed in History.
extension AppCoreEnvironment {

    /// One check, done and recorded.
    public struct ScaleCheck: Sendable {
        public let verification: ScaleVerification
        public let scaleID: ScaleID
        /// Whether it was kept with the calibration evidence (`false` for a preset or inherited
        /// scale, which has none; History has it either way).
        public let storedWithEvidence: Bool
    }

    /// Measures `points` at the page's scale, compares with the stated length, stores the check and
    /// records it in History.
    ///
    /// - Parameter note: History's note for the check, built by the caller in display units.
    /// - Throws: ``DocumentCommandError/noScale(_:)`` on a page with no scale.
    public func verifyScale(
        page: PageID,
        points: [PDFPoint],
        statedLength: Decimal,
        statedUnit: ZPDFContracts.LengthUnit,
        note: (ScaleVerification) -> String
    ) async throws -> ScaleCheck {
        let (verification, scaleID) = try await session.scaleVerification(
            page: page, points: points, statedLength: statedLength, statedUnit: statedUnit
        )
        let stored = await session.recordScaleVerification(verification, scaleID: scaleID)
        history.recordScaleVerification(verification, scaleID: scaleID, note: note(verification))
        return ScaleCheck(verification: verification, scaleID: scaleID, storedWithEvidence: stored)
    }
}
