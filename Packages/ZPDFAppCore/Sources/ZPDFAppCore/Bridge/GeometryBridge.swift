import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFUIPresentation

// Page-space geometry crosses the seam unchanged. Both sides use PDF user space with a
// bottom-left origin and no zoom in it, so these conversions are field copies — and they
// exist precisely so that they stay field copies: the moment a view-space `CGRect` starts
// arriving in an engine, this file stops compiling.

extension PDFPointValue {
    /// A page-space point as the UI renders it.
    public init(domain point: PDFPoint) { self.init(x: point.x, y: point.y) }
}

extension PDFPoint {
    /// A page-space point as an engine consumes it.
    public init(shown point: PDFPointValue) { self.init(x: point.x, y: point.y) }
}

extension PDFRectValue {
    /// A page-space rectangle as the UI renders it, standardized.
    public init(domain rect: PDFRect) {
        let standardized = rect.standardized
        self.init(
            origin: PDFPointValue(domain: standardized.origin),
            size: PDFSizeValue(
                width: standardized.size.width,
                height: standardized.size.height
            )
        )
    }

    /// The bounding box of a point list, or an empty rectangle at the origin.
    public init(boundingBoxOf points: [PDFPoint]) {
        guard let box = PDFRect.boundingBox(of: points) else {
            self.init(origin: .zero, size: .zero)
            return
        }
        self.init(domain: box)
    }
}

extension ZPDFUIPresentation.PageRotation {
    /// The viewer rotation matching a page's `/Rotate`.
    public init(domain rotation: ZPDFContracts.PageRotation) {
        switch rotation {
        case .degrees0: self = .degrees0
        case .degrees90: self = .degrees90
        case .degrees180: self = .degrees180
        case .degrees270: self = .degrees270
        }
    }
}

extension ColorRGBA {
    /// A markup colour as the UI renders it, clamped to the unit range.
    public init(domain color: RGBAColor) {
        let clamped = color.clampedToUnitRange()
        self.init(
            red: clamped.red,
            green: clamped.green,
            blue: clamped.blue,
            alpha: clamped.alpha
        )
    }
}

extension RGBAColor {
    /// A markup colour as a record stores it.
    public init(shown color: ColorRGBA) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

// MARK: - Tools and kinds

extension Shown.Kind {
    /// The palette entry for an engine tool. Total: the two enumerations declare the same
    /// twenty-two tools, and the compiler enforces that they stay that way.
    public init(domain tool: Domain.Tool) {
        switch tool {
        case .length: self = .length
        case .dimension: self = .dimension
        case .polylength: self = .polylength
        case .perimeter: self = .perimeter
        case .area: self = .area
        case .rectangleArea: self = .rectangleArea
        case .ellipseArea: self = .ellipseArea
        case .polygonCutout: self = .polygonCutout
        case .ellipseCutout: self = .ellipseCutout
        case .volume: self = .volume
        case .wallArea: self = .wallArea
        case .count: self = .count
        case .radius: self = .radius
        case .diameter: self = .diameter
        case .threePointCircle: self = .threePointCircle
        case .angle: self = .angle
        case .slope: self = .slope
        case .riseDrop: self = .riseDrop
        case .trueSlopedLength: self = .trueSlopedLength
        case .trueSlopedArea: self = .trueSlopedArea
        case .arcLength: self = .arcLength
        case .temporaryMeasure: self = .temporaryMeasure
        }
    }
}

extension Domain.Tool {
    /// The engine tool a palette entry arms.
    public init(shown kind: Shown.Kind) {
        switch kind {
        case .length: self = .length
        case .dimension: self = .dimension
        case .polylength: self = .polylength
        case .perimeter: self = .perimeter
        case .area: self = .area
        case .rectangleArea: self = .rectangleArea
        case .ellipseArea: self = .ellipseArea
        case .polygonCutout: self = .polygonCutout
        case .ellipseCutout: self = .ellipseCutout
        case .volume: self = .volume
        case .wallArea: self = .wallArea
        case .count: self = .count
        case .radius: self = .radius
        case .diameter: self = .diameter
        case .threePointCircle: self = .threePointCircle
        case .angle: self = .angle
        case .slope: self = .slope
        case .riseDrop: self = .riseDrop
        case .trueSlopedLength: self = .trueSlopedLength
        case .trueSlopedArea: self = .trueSlopedArea
        case .arcLength: self = .arcLength
        case .temporaryMeasure: self = .temporaryMeasure
        }
    }
}

extension Shown.Markup {
    /// The markup family the UI draws for a stored record.
    public init(domain kind: Domain.Kind) {
        switch kind {
        case .text: self = .text
        case .callout: self = .callout
        case .note: self = .note
        case .highlight: self = .highlight
        case .underline: self = .underline
        case .strikeout: self = .strikeout
        case .freehand: self = .freehand
        case .line: self = .line
        case .arrow: self = .arrow
        case .polyline: self = .polyline
        case .rectangle: self = .rectangle
        case .ellipse: self = .ellipse
        case .polygon: self = .polygon
        case .cloud: self = .cloud
        case .stamp: self = .stamp
        case .image: self = .image
        case .hyperlink: self = .hyperlink
        case .measurement: self = .measurement
        case .count: self = .count
        case .revisionCloud: self = .revisionCloud
        case .issue: self = .issue
        }
    }
}

extension Domain.Kind {
    /// The stored family for a UI markup.
    public init(shown kind: Shown.Markup) {
        switch kind {
        case .text: self = .text
        case .callout: self = .callout
        case .note: self = .note
        case .highlight: self = .highlight
        case .underline: self = .underline
        case .strikeout: self = .strikeout
        case .freehand: self = .freehand
        case .line: self = .line
        case .arrow: self = .arrow
        case .polyline: self = .polyline
        case .rectangle: self = .rectangle
        case .ellipse: self = .ellipse
        case .polygon: self = .polygon
        case .cloud: self = .cloud
        case .stamp: self = .stamp
        case .image: self = .image
        case .hyperlink: self = .hyperlink
        case .measurement: self = .measurement
        case .count: self = .count
        case .revisionCloud: self = .revisionCloud
        case .issue: self = .issue
        }
    }
}

extension Shown.Status {

    /// The review status the UI shows: the same state, one to one (NL-COLLAB-03).
    ///
    /// This used to fold eight contract states into six — `inProgress`→In Review,
    /// `resolved`→Completed, `cancelled`→Rejected — so the Inspector and the ledger disagreed
    /// about the same markup, and picking the collapsed state was a silent no-op.
    public init(domain status: Domain.Status) {
        switch status {
        case .none: self = .none
        case .open: self = .open
        case .inProgress: self = .inProgress
        case .resolved: self = .resolved
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        case .cancelled: self = .cancelled
        case .completed: self = .completed
        }
    }
}

extension Domain.Status {
    /// The stored status for a picked one: exactly the state picked (NL-COLLAB-03).
    public init(shown status: Shown.Status) {
        switch status {
        case .none: self = .none
        case .open: self = .open
        case .inProgress: self = .inProgress
        case .resolved: self = .resolved
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        case .cancelled: self = .cancelled
        case .completed: self = .completed
        }
    }
}

// MARK: - Measurement fields

extension Shown.Field {

    /// The UI field a contract field is shown as, or `nil` when the UI has no field for it.
    ///
    /// Four contract fields have no presentation counterpart and are deliberately dropped
    /// rather than folded into a neighbour:
    ///
    /// | Contract field | Why it is not shown |
    /// | --- | --- |
    /// | `truePerimeter` | ADR-0004 §2; the palette shows `perimeter`, and a sloped boundary is a ledger column, not a live field. |
    /// | `cutoutArea` | Reported through `netArea` and the cutout's own row. |
    /// | `planWallArea` | The palette shows the net wall area; the gross figure is a ledger column. |
    /// | `wallArea` (gross, over the true base) | Same reason; the UI's `wallArea` is the net one. |
    ///
    /// `netWallArea` maps to the UI's `wallArea` because that is the number the wall-area
    /// tool is understood to produce — the one with the openings already taken out.
    public init?(domain field: Domain.Field) {
        switch field {
        case .count: self = .count
        case .planLength: self = .planLength
        case .trueLength: self = .trueLength
        case .perimeter: self = .perimeter
        case .planArea: self = .planArea
        case .trueArea: self = .trueArea
        case .netArea: self = .netArea
        case .netWallArea: self = .wallArea
        case .volume: self = .volume
        case .rise: self = .rise
        case .run: self = .run
        case .slopeRatio: self = .slopeRatio
        case .slopePercent: self = .slopePercent
        case .slopeAngle: self = .slopeAngle
        case .depth: self = .depth
        case .height: self = .height
        case .radius: self = .radius
        case .diameter: self = .diameter
        case .circumference: self = .circumference
        case .arcLength: self = .arcLength
        case .angle: self = .angle
        case .truePerimeter, .cutoutArea, .planWallArea, .wallArea:
            return nil
        }
    }
}

extension Domain.Field {
    /// The contract field behind a UI field. Total in this direction: every presentation
    /// field has exactly one contract origin.
    public init(shown field: Shown.Field) {
        switch field {
        case .count: self = .count
        case .planLength: self = .planLength
        case .trueLength: self = .trueLength
        case .perimeter: self = .perimeter
        case .planArea: self = .planArea
        case .trueArea: self = .trueArea
        case .netArea: self = .netArea
        case .wallArea: self = .netWallArea
        case .volume: self = .volume
        case .rise: self = .rise
        case .run: self = .run
        case .slopeRatio: self = .slopeRatio
        case .slopePercent: self = .slopePercent
        case .slopeAngle: self = .slopeAngle
        case .depth: self = .depth
        case .height: self = .height
        case .radius: self = .radius
        case .diameter: self = .diameter
        case .circumference: self = .circumference
        case .arcLength: self = .arcLength
        case .angle: self = .angle
        }
    }
}

// MARK: - Warnings

extension MeasurementWarningSummary {

    /// The UI warning for an engine warning code, or `nil` when the code is a diagnostic
    /// the user has nothing to do about.
    ///
    /// The UI's warning vocabulary is smaller than the engine's on purpose: the engine
    /// distinguishes `duplicatePointsCollapsed` from `fewerThanThreeUniquePoints` because
    /// a test needs to; the user needs to be told "this shape has no area".
    public init?(domain code: MeasurementWarning.Code) {
        switch code {
        case .selfIntersectingPolygon, .polygonNormalized:
            self = .selfIntersecting
        case .degenerateArea, .fewerThanThreeUniquePoints:
            self = .degenerateGeometry
        case .duplicatePointsCollapsed, .openPolygonClosedImplicitly:
            // Successful normalisations with a correct number: two clicks that snapped onto
            // the same vertex were collapsed into one, or an open ring was closed. Mapping
            // them to the *blocking* "no measurable extent" refused a valid area with a false
            // message (BH-089). A shape that genuinely collapses also carries
            // `degenerateArea` or `fewerThanThreeUniquePoints`, which still block.
            return nil
        case .nearlyCollinearPoints:
            self = .nearlyCollinear
        case .verticalSlopeUndefinedRun:
            self = .verticalRun
        case .mixedScaleRegions:
            self = .crossesScaleRegions
        case .extremeScale:
            // A scale outside the sane range that the person confirmed is still a scale. It
            // used to become `.missingScale` — "This page has no calibrated scale yet", and
            // blocking — on a page that had just been calibrated (BH-090, BH-415). The
            // presentation vocabulary has no extreme-scale case to carry instead, so it is a
            // diagnostic here until one exists.
            return nil
        case .staleScaleVersion:
            self = .staleScaleVersion
        case .cutoutOutsideParent:
            self = .cutoutOutsideParent
        case .vectorSnapUnavailable:
            self = .vectorSnapUnavailable
        case .selfIntersectionCheckSkipped:
            // IM-070 / ADR-0018: an outline above the engine's vertex limit was measured as
            // drawn, unchecked. The number stands (not blocking), but the person is told it
            // was not checked — the interim `numericalPrecisionLoss` reached nobody.
            self = .selfIntersectionUnchecked
        case .slopeMagnitudeAboveOneHundredPercent, .slopeAzimuthMissingForBoundary,
             .numericalPrecisionLoss, .unitConversionApproximated, .riseDropCountMismatch:
            return nil
        }
    }
}
