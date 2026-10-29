import Foundation
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation

// MARK: - Snap

extension SnapCandidateKind {
    /// The UI glyph family for an engine snap kind. The two enumerations declare the same
    /// seventeen kinds, in the same order, and this switch is what keeps them that way.
    public init(domain kind: SnapKind) {
        switch kind {
        case .endpoint: self = .endpoint
        case .midpoint: self = .midpoint
        case .intersection: self = .intersection
        case .nearestPointOnSegment: self = .nearestPointOnSegment
        case .perpendicularProjection: self = .perpendicularProjection
        case .parallelGuide: self = .parallelGuide
        case .center: self = .center
        case .quadrant: self = .quadrant
        case .tangent: self = .tangent
        case .grid: self = .grid
        case .angleIncrement: self = .angleIncrement
        case .markupVertex: self = .markupVertex
        case .markupEdge: self = .markupEdge
        case .markupCenter: self = .markupCenter
        case .pdfVectorContent: self = .pdfVectorContent
        case .zoneBoundary: self = .zoneBoundary
        case .calibrationPoint: self = .calibrationPoint
        }
    }
}

extension SnapKind {
    public init(shown kind: SnapCandidateKind) {
        switch kind {
        case .endpoint: self = .endpoint
        case .midpoint: self = .midpoint
        case .intersection: self = .intersection
        case .nearestPointOnSegment: self = .nearestPointOnSegment
        case .perpendicularProjection: self = .perpendicularProjection
        case .parallelGuide: self = .parallelGuide
        case .center: self = .center
        case .quadrant: self = .quadrant
        case .tangent: self = .tangent
        case .grid: self = .grid
        case .angleIncrement: self = .angleIncrement
        case .markupVertex: self = .markupVertex
        case .markupEdge: self = .markupEdge
        case .markupCenter: self = .markupCenter
        case .pdfVectorContent: self = .pdfVectorContent
        case .zoneBoundary: self = .zoneBoundary
        case .calibrationPoint: self = .calibrationPoint
        }
    }
}

extension SnapFeedbackSnapshot {

    /// What the canvas draws for a winning snap candidate.
    ///
    /// `SnapFeedback.labelKey` is a key into the copy catalogue, not a sentence; it is
    /// resolved here so the canvas never has to know that.
    public init(domain feedback: SnapFeedback, pageID: PageID, confidence: Double) {
        self.init(
            kind: SnapCandidateKind(domain: feedback.kind),
            pagePoint: PDFPointValue(domain: feedback.point),
            sourceLabel: SnapCopy.sourceLabel(feedback.labelKey, kind: feedback.kind),
            guideHint: SnapGuideHint(domain: feedback.guide),
            pageID: pageID.rawValue,
            confidence: confidence
        )
    }
}

extension SnapGuideHint {

    /// The guide the canvas strokes, or `nil` when the candidate has no guide geometry.
    public init?(domain guide: SnapGuideGeometry) {
        switch guide {
        case .none, .crosshair:
            // A bare marker is the glyph itself; there is no construction line to stroke.
            return nil
        case .segment(let segment):
            self.init(
                text: NSLocalizedString(
                    "Alignment guide",
                    comment: "Canvas label for a snap guide line"
                ),
                start: PDFPointValue(domain: segment.start),
                end: PDFPointValue(domain: segment.end),
                angleDegrees: Self.degrees(dx: segment.end.x - segment.start.x,
                                           dy: segment.end.y - segment.start.y)
            )
        case .ray(let origin, let direction):
            let degrees = Self.degrees(dx: direction.dx, dy: direction.dy)
            let format = NSLocalizedString(
                "%.1f°",
                comment: "Canvas label for an angle-constrained snap guide"
            )
            self.init(
                text: String(format: format, degrees ?? 0),
                start: PDFPointValue(domain: origin),
                end: nil,
                angleDegrees: degrees
            )
        case .circle(let circle):
            self.init(
                text: NSLocalizedString(
                    "Circle guide",
                    comment: "Canvas label for a circular snap guide"
                ),
                start: PDFPointValue(domain: circle.center),
                end: nil
            )
        case .arc(let arc):
            self.init(
                text: NSLocalizedString(
                    "Arc guide",
                    comment: "Canvas label for an arc snap guide"
                ),
                start: PDFPointValue(domain: arc.startPoint),
                end: PDFPointValue(domain: arc.endPoint)
            )
        }
    }

    /// The bearing of a direction in degrees, or `nil` when the direction is degenerate.
    private static func degrees(dx: Double, dy: Double) -> Double? {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
        return Foundation.atan2(dy, dx) * 180 / Double.pi
    }
}

/// Localized copy for snap feedback.
enum SnapCopy {

    /// The human phrase behind a `SnapFeedback.labelKey`.
    ///
    /// The engine emits a key so it stays free of `NSLocalizedString` and of the copy
    /// standard; the mapping lives here, and an unknown key degrades to the kind's own
    /// display name rather than to the raw key.
    static func sourceLabel(_ key: String, kind: SnapKind) -> String {
        switch key {
        case "snap.source.vector":
            return NSLocalizedString("PDF geometry", comment: "Snap source: the page's vector content")
        case "snap.source.markup":
            return NSLocalizedString("Markup", comment: "Snap source: another Zenit markup")
        case "snap.source.boundary":
            return NSLocalizedString("Zone boundary", comment: "Snap source: a Project Zone or Scale Region boundary")
        case "snap.source.grid":
            return NSLocalizedString("Grid", comment: "Snap source: the synthetic grid")
        case "snap.source.angle":
            return NSLocalizedString("Angle guide", comment: "Snap source: the angle increment guide")
        default:
            return SnapCandidateKind(domain: kind).displayName
        }
    }
}

// MARK: - Scale

extension ScaleSummary {

    /// The scale as the status bar and the measurement palette show it.
    ///
    /// `sx` and `sy` stay in metres per PDF point, which is what the engine holds; the
    /// human-readable `1:50` is derived in ``ScaleBridge/ratioText(for:userUnit:localeIdentifier:)``
    /// and travels as ``displayString`` so no view has to reinvent the arithmetic.
    ///
    /// `localeIdentifier` is the document's (L-38): the Inspector's Scale row, the Scale Regions
    /// panel and the Bulk Scale sheet show ``displayString`` verbatim, and they read
    /// "1:49 × 1:51" — whole numbers in no locale — for the scale the Calibrate sheet and the
    /// status strip call 1:49,5 × 1:50,6.
    public init(
        domain scale: ScaleTransform,
        name: String?,
        userUnit: Double = 1,
        localeIdentifier: String = "en_US_POSIX"
    ) {
        let sx = scale.matrix.metresPerPointX
        let sy = scale.matrix.metresPerPointY
        let ratio = ScaleBridge.ratioText(for: scale, userUnit: userUnit, localeIdentifier: localeIdentifier)
        self.init(
            id: scale.id.rawValue,
            name: name ?? scale.label ?? ratio,
            displayString: ratio,
            isUniform: scale.matrix.isUniform,
            sx: sx,
            sy: sy,
            unit: ScaleBridge.shownLengthUnit(scale.units.length),
            version: scale.version,
            locked: false
        )
    }
}

/// Derivations the scale UI needs that the contract deliberately does not store.
public enum ScaleBridge {

    /// `"1:50"` for a scale, or `"1:49.5 × 1:50.6"` for a separate-XY scale.
    ///
    /// A PDF point is 1/72 inch, so one metre on the page is `72 / 0.0254` points. The
    /// denominator is that divided by the metres a point represents, written by
    /// ``ZPDFUIPresentation/ScaleRatioText`` — the Calibrate sheet's rule, shared with the status
    /// strip (L-38): two decimals below 1:10, one below 1:100, none from there up, so the float
    /// noise of a nominal 1:49.99999 still reads 1:50. It used to round every denominator to a
    /// whole number, so the 1:49,47 × 1:50,64 the sheet called 1:49,5 × 1:50,6 read 1:49 × 1:51
    /// in the Inspector, the Scale Regions panel and the Bulk Scale sheet.
    ///
    /// `localeIdentifier` is the document's for anything a person reads (``ScaleSummary``, the
    /// ledger's scale names); files — the archive, the PDF `/Measure` label, the measurement
    /// trace — keep the locale-independent default.
    ///
    /// `userUnit` is the page's `/UserUnit`: a scale on a `/UserUnit 2` sheet carries twice the
    /// metres per page unit for the *same* nominal ratio, so the ratio a person reads is the
    /// factor divided back by the unit (CR-128). Without it a `1:100` preset on such a sheet
    /// read `1:200`.
    public static func ratioText(
        for scale: ScaleTransform,
        userUnit: Double = 1,
        localeIdentifier: String = "en_US_POSIX"
    ) -> String {
        ScaleRatioText.ratio(
            metresPerPointX: scale.matrix.metresPerPointX,
            metresPerPointY: scale.matrix.metresPerPointY,
            isUniform: scale.matrix.isUniform,
            userUnit: userUnit,
            locale: Locale(identifier: localeIdentifier)
        )
    }

    /// The nominal `n` in `1:n` as a whole number, clamped to at least 1 so a degenerate scale
    /// cannot print `1:0`. What a person reads is ``ratioText(for:userUnit:localeIdentifier:)``.
    public static func denominator(metresPerPoint: Double, userUnit: Double = 1) -> Int {
        guard let exact = ScaleRatioText.denominator(metresPerPoint: metresPerPoint, userUnit: userUnit)
        else { return 1 }
        return max(1, Int(exact.rounded()))
    }

    /// The presentation length unit for a contract one.
    public static func shownLengthUnit(_ unit: Domain.Length) -> ZPDFUIPresentation.LengthUnit {
        switch unit {
        case .millimetre: .millimetre
        case .centimetre: .centimetre
        case .metre: .metre
        case .kilometre: .kilometre
        case .inch: .inch
        case .foot: .foot
        case .yard: .yard
        case .mile: .mile
        }
    }

    /// `"1:100 @ 1.00 m"` — the status bar's scale segment, in the
    /// numbers of `localeIdentifier`: `"1:100 @ 1,00 m"` on a Swedish-format machine.
    ///
    /// The second half is the output length unit the ratio is read in, as the reference binds it
    /// (`@ 1.00m`). It used to print the unit's size *in metres* followed by the unit's own
    /// symbol, so imperial read `1:50 @ 0.30ft` — a claim that a foot is 0.30 feet — and metric
    /// was right only because a metre is 1.00 m (BH-093). `userUnit` is the page's
    /// `/UserUnit` (CR-128, BH-092).
    ///
    /// L-38: the separate X/Y scale X 848.0 pt = 14,8 m, Y 839.6 pt = 15 m —
    /// 1:49.47 × 1:50.64 — read "1:49 × 1:51 @ 1.00m" here while the Calibrate sheet that made
    /// it read 1:49,5 and 1:50,6: two rounding rules for one scale, and a point where every other
    /// value in the app uses the locale's comma. The ratio is now
    /// ``ratioText(for:userUnit:localeIdentifier:)``'s — one rule, ``ZPDFUIPresentation/ScaleRatioText``,
    /// for the strip, the sheet, ``ScaleSummary/displayString`` and the scale names — and both
    /// numbers are in the document's locale, the one the ledger and the canvas captions use.
    public static func statusText(
        for scale: ScaleTransform,
        units: DisplayUnitSelection,
        userUnit: Double = 1,
        localeIdentifier: String = "en_US_POSIX"
    ) -> String {
        statusText(
            metresPerPointX: scale.matrix.metresPerPointX,
            metresPerPointY: scale.matrix.metresPerPointY,
            isUniform: scale.matrix.isUniform,
            units: units,
            userUnit: userUnit,
            localeIdentifier: localeIdentifier
        )
    }

    /// The same status-bar segment, derived from a snapshot's ``ScaleSummary``.
    ///
    /// Built from the summary's factors rather than its display string, so it is a synchronous
    /// function of one document snapshot and of this call's locale and
    /// `/UserUnit`, whatever locale the summary was made in.
    public static func statusText(
        for scale: ScaleSummary,
        units: DisplayUnitSelection,
        userUnit: Double = 1,
        localeIdentifier: String = "en_US_POSIX"
    ) -> String {
        statusText(
            metresPerPointX: scale.sx,
            metresPerPointY: scale.sy,
            isUniform: scale.isUniform,
            units: units,
            userUnit: userUnit,
            localeIdentifier: localeIdentifier
        )
    }

    static func statusText(
        metresPerPointX: Double,
        metresPerPointY: Double,
        isUniform: Bool,
        units: DisplayUnitSelection,
        userUnit: Double,
        localeIdentifier: String
    ) -> String {
        let locale = Locale(identifier: localeIdentifier)
        let ratio = ScaleRatioText.ratio(
            metresPerPointX: metresPerPointX,
            metresPerPointY: metresPerPointY,
            isUniform: isUniform,
            userUnit: userUnit,
            locale: locale
        )
        return "\(ratio) @ \(unitSuffix(units, locale: locale))"
    }

    /// One output length unit, as the status bar's scale segment states it: `"1.00 m"`, or
    /// `"1,00 m"` in a comma locale.
    static func unitSuffix(_ units: DisplayUnitSelection, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let one = 1.0.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(2)))
        return "\(one) \(units.length.symbol)"
    }
}

// MARK: - Pages

extension ZPDFUIPresentation.PageDescriptor {

    /// A page as the navigator and the canvas see it.
    ///
    /// `outlineTitle` is the drawing's outline entry for the page, when the app read one; the
    /// sheet title falls back to the page's own label (``PageDescriptor/resolvedSheetTitle``).
    public init(domain page: ZPDFContracts.PageDescriptor, outlineTitle: String? = nil) {
        self.init(
            id: page.id.rawValue,
            index: page.index,
            label: page.label,
            mediaBox: PDFRectValue(domain: page.boxes.media),
            cropBox: PDFRectValue(domain: page.boxes.crop),
            rotation: ZPDFUIPresentation.PageRotation(domain: page.rotation),
            sheetTitle: ZPDFUIPresentation.PageDescriptor.resolvedSheetTitle(
                outlineTitle: outlineTitle,
                label: page.label
            )
        )
    }

    /// `"841 × 594 mm"` — the status bar's page-size text, in the selected length unit
    /// when it is metric and in inches when it is not.
    ///
    /// `userUnit` is the page's `/UserUnit`: a page unit is `userUnit / 72` inch, so a sheet
    /// declared at `/UserUnit 2` is physically twice the size its box suggests (CR-128).
    public func dimensionsText(units: DisplayUnitSelection, userUnit: Double = 1) -> String {
        let size = rotatedVisibleSize
        let unit = (userUnit.isFinite && userUnit > 0) ? userUnit : 1
        let metresPerPoint = 0.0254 / 72.0 * unit
        if units.length.isMetric {
            let width = size.width * metresPerPoint * 1000
            let height = size.height * metresPerPoint * 1000
            return String(format: "%.0f × %.0f mm", width, height)
        }
        let width = size.width * unit / 72.0
        let height = size.height * unit / 72.0
        return String(format: "%.1f × %.1f in", width, height)
    }
}
