import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFMeasurementEngine
import ZPDFUIPresentation

/// The words a person reads for a refusal: one sentence they can act on, never an engine type
/// name, an enum case or an identifier (L-102).
///
/// A manual test put this in the warning tray after two clicks with Radius on a sheet with separate
/// X and Y scales: *"measurement failed: scaleApplication(ZPDFGeometry.ScaleApplicationError.
/// directionRequiredForNonUniformScale(7F3275E4-…))"*. Every tray message that used to paste
/// `String(describing: error)` after "The engine reported:" goes through ``sentence(for:)``
/// instead, and the session wraps an engine refusal in these words at the point it turns it into
/// ``DocumentCommandError/measurementFailed(_:)``, so the detail it carries is already plain.
public enum UserFacingRefusal {

    /// The sentence for any refusal the session, the engine or an edit can raise.
    public static func sentence(for error: any Error) -> String {
        switch error {
        case let refusal as DocumentCommandError: return sentence(for: refusal)
        case let refusal as MeasurementEngineError: return sentence(for: refusal)
        case let refusal as AreaSplitRefusal: return refusal.message
        case let refusal as ScaleApplicationError: return sentence(for: refusal)
        case let refusal as GeometryError: return sentence(for: refusal)
        default:
            if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
                return described
            }
            return generic
        }
    }

    /// When nothing more specific can be said.
    static var generic: String {
        NSLocalizedString(
            "Zenit could not complete this change.",
            comment: "Refusal sentence when the reason has no plain wording of its own"
        )
    }

    // MARK: Session

    static func sentence(for refusal: DocumentCommandError) -> String {
        switch refusal {
        case .unknownMarkup:
            return NSLocalizedString("That markup is no longer in the document.", comment: "Refusal sentence")
        case .unknownPage, .pageIndexOutOfRange:
            return NSLocalizedString("That page is no longer in the document.", comment: "Refusal sentence")
        case .markupLocked:
            return NSLocalizedString("The markup is locked. Unlock it to change it.", comment: "Refusal sentence")
        case .noScale:
            return NSLocalizedString(
                "This page has no scale yet. Set the scale to measure on it.",
                comment: "Refusal sentence: a measurement on a page with no scale"
            )
        case .scaleBelongsToAnotherPage:
            return NSLocalizedString(
                "That scale belongs to another sheet, so it cannot be used on this one.",
                comment: "Refusal sentence"
            )
        case .scaleHasNoPage:
            return NSLocalizedString("That scale does not belong to any sheet.", comment: "Refusal sentence")
        case .measurementFailed(let detail):
            // The session writes this detail in words (``sessionDetail(for:)``); a detail from an
            // older path that is not a sentence yet is made one.
            return sentenceCased(detail)
        case .ledgerFailed:
            return NSLocalizedString("The ledger could not be updated.", comment: "Refusal sentence")
        }
    }

    /// The detail the session stores in ``DocumentCommandError/measurementFailed(_:)`` for a
    /// refusal it caught: the plain sentence, so `description` and the tray never carry the
    /// engine's case names.
    static func sessionDetail(for error: any Error) -> String {
        sentence(for: error)
    }

    // MARK: Engine

    static func sentence(for refusal: MeasurementEngineError) -> String {
        switch refusal {
        case .scaleApplication(let error):
            return sentence(for: error)
        case .scale:
            return NSLocalizedString(
                "This sheet's scale cannot be used. Calibrate the sheet again.",
                comment: "Refusal sentence: the scale transform is unusable"
            )
        case .measurement(let error):
            return sentence(for: error)
        case .geometry(let error):
            return sentence(for: error)
        case .unsupportedGeometry:
            return NSLocalizedString(
                "This shape does not have the points this tool needs.",
                comment: "Refusal sentence: the geometry does not fit the tool"
            )
        case .clipper, .numeric, .dimension, .slope, .unitMismatch:
            return noNumber
        }
    }

    static func sentence(for refusal: ScaleApplicationError) -> String {
        switch refusal {
        case .directionRequiredForNonUniformScale:
            // The one thrower is the circle measure: a radius under separate X and Y scales.
            return MeasurementWarningSummary.circleNeedsUniformScale.message
        case .overlappingRegions:
            return NSLocalizedString(
                "Two Scale Regions on this sheet overlap. Change one so they no longer overlap.",
                comment: "Refusal sentence"
            )
        case .unknownScale, .invalidRegionBoundary:
            return NSLocalizedString(
                "A Scale Region on this sheet cannot be used. Check it in Scale Regions.",
                comment: "Refusal sentence"
            )
        case .emptyGeometry:
            return MeasurementWarningSummary.degenerateGeometry.message
        case .numeric:
            return noNumber
        }
    }

    static func sentence(for refusal: MeasurementError) -> String {
        switch refusal {
        case .emptyGeometry, .fewerThanThreeUniquePoints, .degenerateArea:
            return MeasurementWarningSummary.degenerateGeometry.message
        case .selfIntersectingPolygon:
            return NSLocalizedString("This outline crosses itself.", comment: "Refusal sentence")
        case .nearlyCollinearPoints:
            return MeasurementWarningSummary.nearlyCollinear.message
        case .cutoutOutsideParent:
            return MeasurementWarningSummary.cutoutDoesNotOverlapParent.message
        case .missingParameter(let key):
            return sentence(missing: key)
        case .slopeAzimuthRequired:
            return sentence(missing: .slopeAzimuth)
        case .volumeDepthReferenceRequired:
            return sentence(missing: .volumeDepthReference)
        case .negativeNetArea:
            return NSLocalizedString(
                "The cutouts are larger than the area they are cut from.",
                comment: "Refusal sentence"
            )
        case .negativeParameter:
            return NSLocalizedString("A depth or height cannot be negative.", comment: "Refusal sentence")
        case .nonFiniteCoordinate, .coordinateOutOfRange:
            return NSLocalizedString(
                "A point of this shape is not a valid position on the page.",
                comment: "Refusal sentence"
            )
        case .unsupportedField:
            return noNumber
        }
    }

    /// The value a measurement was not given, named, and where to give it.
    static func sentence(missing key: MeasurementParameterKey) -> String {
        switch key {
        case .depth:
            return NSLocalizedString(
                "This measurement needs a depth. Enter it in the tool options and try again.",
                comment: "Refusal sentence: the Volume tool has no depth"
            )
        case .height:
            return NSLocalizedString(
                "This measurement needs a wall height. Enter it in the tool options and try again.",
                comment: "Refusal sentence: the Wall Area tool has no height"
            )
        case .heightAtEnd:
            return NSLocalizedString(
                "This measurement needs the wall height at the far end. Enter it and try again.",
                comment: "Refusal sentence: a gable wall has no far-end height"
            )
        case .riseRun:
            return NSLocalizedString(
                "This measurement needs a slope. Enter it in the tool options and try again.",
                comment: "Refusal sentence: a sloped tool has no slope"
            )
        case .perSegmentRiseDrop, .totalRiseDrop:
            return NSLocalizedString(
                "This measurement needs a rise or drop. Enter it in the tool options and try again.",
                comment: "Refusal sentence: the Rise/Drop tool has no value"
            )
        case .slopeAzimuth:
            return NSLocalizedString(
                "This slope needs a fall-line direction. Pick the fall line and try again.",
                comment: "Refusal sentence: a slope applied to a length without a fall-line direction"
            )
        case .volumeDepthReference:
            return NSLocalizedString(
                "This sloped volume needs to know whether its depth is vertical or square to the surface.",
                comment: "Refusal sentence: a sloped volume without a depth reference"
            )
        case .openingAreas:
            return NSLocalizedString(
                "An opening subtracted from this wall is not a valid area.",
                comment: "Refusal sentence: a wall's opening areas are invalid"
            )
        }
    }

    static func sentence(for refusal: GeometryError) -> String {
        switch refusal {
        case .fewerThanThreeUniquePoints, .degenerateSegment, .zeroLengthVector:
            return MeasurementWarningSummary.degenerateGeometry.message
        case .nearlyCollinearPoints:
            return MeasurementWarningSummary.nearlyCollinear.message
        case .selfIntersectingRing:
            return NSLocalizedString("This outline crosses itself.", comment: "Refusal sentence")
        case .nonFiniteCoordinate, .nonFiniteBounds:
            return NSLocalizedString(
                "A point of this shape is not a valid position on the page.",
                comment: "Refusal sentence"
            )
        default:
            return noNumber
        }
    }

    /// The engine could not produce a number, for a reason a person cannot act on.
    static var noNumber: String {
        NSLocalizedString(
            "Zenit could not compute a number for this shape.",
            comment: "Refusal sentence when the engine fails for an internal reason"
        )
    }

    /// `detail` as a sentence: a capital first letter and a closing full stop.
    static func sentenceCased(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return generic }
        var sentence = first.uppercased() + trimmed.dropFirst()
        if let last = sentence.last, !".!?".contains(last) { sentence += "." }
        return sentence
    }
}
