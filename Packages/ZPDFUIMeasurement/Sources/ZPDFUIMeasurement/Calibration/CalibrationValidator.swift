import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Issues

/// Everything that can be wrong with a calibration draft.
///
/// Calibration has four blocked states and one that needs confirmation. Zenit shows all of
/// them as prevention: the issue appears the moment the draft becomes invalid, next to the
/// control that caused it, and Apply stays disabled — the user is never allowed to commit a
/// broken scale and be told afterwards.
public enum CalibrationIssue: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// The single calibration line has fewer than two points.
    case missingPrimaryPoints
    /// The Y line has fewer than two points.
    case missingSecondaryPoints
    /// The two picked points are the same, or near enough that the scale would be nonsense.
    case identicalPrimaryPoints
    /// The two Y points are identical.
    case identicalSecondaryPoints
    /// A usable line, but so short that a one-pixel pick error moves the scale a lot.
    case shortPrimaryBaseline
    /// The Y line is very short.
    case shortSecondaryBaseline
    /// No real-world length has been entered.
    case missingPrimaryLength
    /// No real-world Y length has been entered.
    case missingSecondaryLength
    /// The entered length is zero or negative.
    case nonPositivePrimaryLength
    /// The entered Y length is zero or negative.
    case nonPositiveSecondaryLength
    /// The entered length is positive but outside what a calibration may use.
    case outOfRangePrimaryLength
    /// The entered Y length is positive but outside what a calibration may use.
    case outOfRangeSecondaryLength
    /// The length field holds text that is not a length.
    case unparseablePrimaryLength
    /// The Y length field holds text that is not a length.
    case unparseableSecondaryLength
    /// The chosen unit is not a length unit Zenit can measure in.
    case invalidUnit
    /// The two calibration lines point almost the same way, so the axes cannot be separated.
    case nearParallelAxes
    /// The lines are close to parallel but still separable, with a large residual.
    case obliqueAxes
    /// The two lines lean from horizontal by the same amount in mirror image, so a stretch
    /// along X cannot be told apart from one along Y.
    case mirroredAxes
    /// The two known lengths contradict each other for any axis stretch of the page.
    case inconsistentAxes
    /// Drawing-scale mode with no usable ratio chosen.
    case missingDrawingScale
    /// Drawing-scale mode on a page that is not a standard paper size.
    case nonStandardPaperSize
    /// The resulting scale is far outside anything a construction drawing uses.
    case extremeScale

    public var id: String { rawValue }

    /// How the issue is treated.
    public var severity: CalibrationIssueSeverity {
        switch self {
        case .missingPrimaryPoints, .missingSecondaryPoints,
             .identicalPrimaryPoints, .identicalSecondaryPoints,
             .missingPrimaryLength, .missingSecondaryLength,
             .nonPositivePrimaryLength, .nonPositiveSecondaryLength,
             .outOfRangePrimaryLength, .outOfRangeSecondaryLength,
             .unparseablePrimaryLength, .unparseableSecondaryLength,
             .invalidUnit, .nearParallelAxes, .mirroredAxes, .inconsistentAxes, .missingDrawingScale:
            return .blocking
        case .extremeScale, .obliqueAxes:
            return .requiresConfirmation
        case .shortPrimaryBaseline, .shortSecondaryBaseline, .nonStandardPaperSize:
            return .advisory
        }
    }

    /// The message shown next to the offending control.
    public var message: String {
        switch self {
        case .missingPrimaryPoints:
            return NSLocalizedString(
                "Pick two points on the drawing before entering a length.",
                comment: "Calibration blocked: no calibration line"
            )
        case .missingSecondaryPoints:
            return NSLocalizedString(
                "Pick two points for the vertical dimension as well.",
                comment: "Calibration blocked: no Y calibration line"
            )
        case .identicalPrimaryPoints:
            return NSLocalizedString(
                "The two points are the same. Pick points that are clearly apart.",
                comment: "Calibration blocked: identical points"
            )
        case .identicalSecondaryPoints:
            return NSLocalizedString(
                "The two vertical points are the same. Pick points that are clearly apart.",
                comment: "Calibration blocked: identical Y points"
            )
        case .shortPrimaryBaseline:
            return NSLocalizedString(
                "This calibration line is very short, so a small pick error changes the scale a lot. A longer dimension is more reliable.",
                comment: "Calibration advisory: short baseline"
            )
        case .shortSecondaryBaseline:
            return NSLocalizedString(
                "The vertical calibration line is very short. A longer dimension is more reliable.",
                comment: "Calibration advisory: short Y baseline"
            )
        case .missingPrimaryLength:
            return NSLocalizedString(
                "Enter the real-world length of the picked dimension.",
                comment: "Calibration blocked: no known length"
            )
        case .missingSecondaryLength:
            return NSLocalizedString(
                "Enter the real-world length of the vertical dimension.",
                comment: "Calibration blocked: no known Y length"
            )
        case .nonPositivePrimaryLength:
            return NSLocalizedString(
                "The real-world length must be greater than zero.",
                comment: "Calibration blocked: zero or negative length"
            )
        case .nonPositiveSecondaryLength:
            return NSLocalizedString(
                "The vertical length must be greater than zero.",
                comment: "Calibration blocked: zero or negative Y length"
            )
        case .outOfRangePrimaryLength:
            return NSLocalizedString(
                "This length is outside the range a calibration can use. Check for a mistyped digit or exponent.",
                comment: "Calibration blocked: length outside the allowed range"
            )
        case .outOfRangeSecondaryLength:
            return NSLocalizedString(
                "The vertical length is outside the range a calibration can use. Check for a mistyped digit or exponent.",
                comment: "Calibration blocked: Y length outside the allowed range"
            )
        case .unparseablePrimaryLength:
            return NSLocalizedString(
                "The length is not a number Zenit can read. Type a number such as 5.5, or feet and inches such as 12' 6 1/2\".",
                comment: "Calibration blocked: the length text cannot be read"
            )
        case .unparseableSecondaryLength:
            return NSLocalizedString(
                "The vertical length is not a number Zenit can read. Type a number such as 5.5, or feet and inches such as 12' 6 1/2\".",
                comment: "Calibration blocked: the Y length text cannot be read"
            )
        case .invalidUnit:
            return NSLocalizedString(
                "Choose a length unit before applying the scale.",
                comment: "Calibration blocked: unusable unit"
            )
        case .nearParallelAxes:
            return NSLocalizedString(
                "The two calibration lines point almost the same way, so X and Y cannot be separated. Pick one horizontal and one vertical dimension.",
                comment: "Calibration blocked: near-parallel axes"
            )
        case .obliqueAxes:
            return NSLocalizedString(
                "The calibration lines are not close to perpendicular. Check the residual before applying.",
                comment: "Calibration confirmation: oblique axes"
            )
        case .mirroredAxes:
            return NSLocalizedString(
                "The two lines lean from horizontal by the same amount, so a horizontal stretch cannot be told apart from a vertical one. Pick one horizontal and one vertical dimension.",
                comment: "Calibration blocked: mirror-image calibration lines"
            )
        case .inconsistentAxes:
            return NSLocalizedString(
                "The two lengths contradict each other: no horizontal and vertical stretch of the page fits both. Check both lengths and the picked points.",
                comment: "Calibration blocked: the two known lengths are inconsistent"
            )
        case .missingDrawingScale:
            return NSLocalizedString(
                "Choose the scale printed on the drawing, or type the n of 1:n.",
                comment: "Calibration blocked: no drawing scale chosen"
            )
        case .nonStandardPaperSize:
            return NSLocalizedString(
                "This page is not a standard paper size, so it may have been scaled when the PDF was made. Calibrate on a known dimension to be sure.",
                comment: "Calibration advisory: a drawing scale on a non-standard page size"
            )
        case .extremeScale:
            return NSLocalizedString(
                "This scale is far outside the usual range for a drawing. Confirm that it is correct.",
                comment: "Calibration confirmation: extreme scale"
            )
        }
    }

    /// Whether the issue only names an input the person has not given yet.
    ///
    /// A fresh draft has no points and no length. That is the next step, not a mistake: it
    /// still holds Apply back, but it is not drawn as an error.
    public var isPendingInput: Bool {
        switch self {
        case .missingPrimaryPoints, .missingSecondaryPoints,
             .missingPrimaryLength, .missingSecondaryLength, .missingDrawingScale:
            return true
        default:
            return false
        }
    }

    /// The design-system severity used to draw the issue.
    ///
    /// A pending input is drawn as neutral guidance. It used to be drawn as a red error, so the
    /// sheet showed "Enter the real-world length of the picked dimension." in red the moment the
    /// second point landed, before the person could type anything (live finding L-06).
    public var displaySeverity: ZPDFSeverity {
        if isPendingInput { return .neutral }
        switch severity {
        case .blocking: return .danger
        case .requiresConfirmation: return .warning
        case .advisory: return .info
        }
    }

    /// The checkbox label for an issue the user can confirm past.
    public var confirmationTitle: String? {
        switch self {
        case .extremeScale:
            return NSLocalizedString(
                "I have checked this scale and it is correct",
                comment: "Confirmation checkbox for an extreme scale"
            )
        case .obliqueAxes:
            return NSLocalizedString(
                "Apply the axis-separated scale anyway",
                comment: "Confirmation checkbox for oblique calibration axes"
            )
        default:
            return nil
        }
    }
}

/// How hard an issue bites.
public enum CalibrationIssueSeverity: String, Hashable, Sendable, CaseIterable {
    /// Apply is disabled until it is fixed.
    case blocking
    /// Apply is disabled until the matching checkbox is ticked.
    case requiresConfirmation
    /// Shown, but Apply stays available.
    case advisory
}

// MARK: - Preview

/// What the draft would produce if it were applied.
public struct CalibrationPreview: Hashable, Sendable {

    /// Metres of real world per PDF page point along x.
    public var sx: Double
    /// Metres of real world per PDF page point along y.
    public var sy: Double
    /// Whether ``sx`` and ``sy`` agree.
    public var isUniform: Bool
    /// The `1:n` string for the x axis.
    public var ratioString: String
    /// The `1:n` string for the y axis, when the axes differ.
    public var secondaryRatioString: String?
    /// Angle between the two calibration lines in degrees, `nil` in uniform mode.
    public var axisAngleDegrees: Double?
    /// Relative difference between the two axis scales, `0` when they agree.
    ///
    /// Reported as the residual of the axis-separated fit, so the user can see
    /// how much the drawing is actually stretched.
    public var residual: Double?

    public init(
        sx: Double,
        sy: Double,
        isUniform: Bool,
        ratioString: String,
        secondaryRatioString: String? = nil,
        axisAngleDegrees: Double? = nil,
        residual: Double? = nil
    ) {
        self.sx = sx
        self.sy = sy
        self.isUniform = isUniform
        self.ratioString = ratioString
        self.secondaryRatioString = secondaryRatioString
        self.axisAngleDegrees = axisAngleDegrees
        self.residual = residual
    }

    /// The residual as a percentage string, for the readout.
    public var residualPercentString: String? {
        guard let residual else { return nil }
        return String(
            format: NSLocalizedString(
                "%.2f %%",
                comment: "Residual of an axis-separated calibration, as a percentage"
            ),
            residual * 100
        )
    }

    /// The angle readout, for the readout row.
    public var axisAngleString: String? {
        guard let axisAngleDegrees else { return nil }
        return String(
            format: NSLocalizedString(
                "%.1f°",
                comment: "Angle between the two calibration lines"
            ),
            axisAngleDegrees
        )
    }
}

// MARK: - Validation result

/// The verdict on a draft: what is wrong, and what it would produce.
public struct CalibrationValidation: Hashable, Sendable {

    /// Every issue found, blocking first.
    ///
    /// A confirmable issue the person has ticked stays in this list, so the sheet keeps its
    /// warning and its checkbox on screen and the tick can be taken back. It used to vanish the
    /// moment it was ticked, taking its own checkbox with it (BH-251).
    public let issues: [CalibrationIssue]
    /// The confirmable issues the person has ticked. They no longer hold Apply back.
    public let confirmedIssues: Set<CalibrationIssue>
    /// What applying the draft would produce, when it is computable at all.
    public let preview: CalibrationPreview?

    public init(
        issues: [CalibrationIssue],
        preview: CalibrationPreview?,
        confirmedIssues: Set<CalibrationIssue> = []
    ) {
        self.issues = issues.sorted { lhs, rhs in
            CalibrationValidation.severityRank(lhs.severity)
                < CalibrationValidation.severityRank(rhs.severity)
        }
        self.confirmedIssues = confirmedIssues.filter { $0.severity == .requiresConfirmation }
        self.preview = preview
    }

    /// Issues that must be fixed.
    public var blockingIssues: [CalibrationIssue] { issues.filter { $0.severity == .blocking } }
    /// Issues that still need a tick before Apply lights up.
    public var confirmationIssues: [CalibrationIssue] {
        issues.filter { $0.severity == .requiresConfirmation && !confirmedIssues.contains($0) }
    }
    /// Whether the person has ticked the confirmation for `issue`.
    public func isConfirmed(_ issue: CalibrationIssue) -> Bool { confirmedIssues.contains(issue) }

    /// Whether Apply may be enabled.
    public var canApply: Bool { blockingIssues.isEmpty && confirmationIssues.isEmpty }

    /// A single spoken summary for the Apply button's accessibility value.
    public var applyAccessibilityValue: String {
        if canApply {
            return NSLocalizedString(
                "Ready to apply",
                comment: "Accessibility value when the calibration can be committed"
            )
        }
        if let first = blockingIssues.first ?? confirmationIssues.first {
            return first.message
        }
        return NSLocalizedString(
            "Not ready",
            comment: "Accessibility value when the calibration cannot be committed"
        )
    }

    private static func severityRank(_ severity: CalibrationIssueSeverity) -> Int {
        switch severity {
        case .blocking: return 0
        case .requiresConfirmation: return 1
        case .advisory: return 2
        }
    }
}

// MARK: - Validator

/// Checks a ``CalibrationDraft`` and computes what it would produce.
///
/// Pure, synchronous and view-free, so the sheet can call it on every keystroke and the tests
/// can cover the blocked states without a window.
public enum CalibrationValidator {

    /// At or below this PDF-point distance the two picked points count as identical.
    ///
    /// The frozen scale contract's floor: two-point calibration rejects points closer than
    /// 4 PDF points (SCALE_CONTRACT, `ScaleTransform.calibratedTwoPoint`). This was 1.0, so a
    /// 2.5 pt pick earned only the short-baseline advisory and the sheet committed a
    /// calibration the domain refuses (BH-250).
    public static let identicalPointTolerance: Double = 4.0
    /// Below this PDF-point distance the baseline is usable but shown as fragile.
    public static let shortBaselineThreshold: Double = 24.0
    /// Below this angle between the two calibration lines the axes cannot be separated.
    public static let nearParallelDegrees: Double = 5.0
    /// Below this angle the separation is possible but reported for confirmation.
    public static let obliqueDegrees: Double = 60.0
    /// Metres per page point below which the scale is treated as extreme.
    public static let minimumPlausibleScale: Double = 1e-4
    /// Metres per page point above which the scale is treated as extreme.
    public static let maximumPlausibleScale: Double = 5.0
    /// The range a known length has to fall in, in the draft's unit.
    ///
    /// Far wider than any drawing needs. It exists to keep a mistyped exponent out of the
    /// scale. It used to be enforced only by the field's warning glyph while Apply stayed
    /// live (BH-249); it is a blocking issue now.
    public static let allowedLengthRange: ClosedRange<Double> = 0.000_001...1_000_000
    /// Below this conditioning the two lines cannot separate an X stretch from a Y stretch.
    ///
    /// `|sin(a - b) * sin(a + b)|` for line directions `a` and `b`: zero when the lines are
    /// parallel and zero when they mirror each other about the page axes. `sin²(5°)` is what a
    /// horizontal line and a line 5° off it score, so it matches the near-parallel threshold.
    static let minimumAxisSeparability: Double = pow(sin(5 * .pi / 180), 2)

    /// The name a scale gets when the person leaves Name empty.
    ///
    /// One definition, used by ``makeScaleSummary(from:id:version:locale:)`` and by the sheet's Name
    /// placeholder, so the placeholder shows exactly the name the scale will get (IM-204).
    public static func generatedName(for preview: CalibrationPreview) -> String {
        String(
            format: NSLocalizedString(
                "Scale %@",
                comment: "Default scale name built from the ratio string"
            ),
            preview.ratioString
        )
    }

    /// Validates a draft.
    ///
    /// `locale` is the document's: the preview's ratio is written in its digits by
    /// ``ScaleRatioText``, the rule every other `1:n` in the app follows (L-38). The app formats
    /// its documents in the current locale, which is the default.
    public static func validate(_ draft: CalibrationDraft, locale: Locale = .current) -> CalibrationValidation {
        var issues: [CalibrationIssue] = []

        guard let unit = draft.resolvedUnit else {
            issues.append(.invalidUnit)
            issues.append(contentsOf: geometryIssues(draft))
            return CalibrationValidation(issues: issues, preview: nil)
        }

        if draft.mode == .drawingScale {
            return validateDrawingScale(draft, locale: locale)
        }

        issues.append(contentsOf: geometryIssues(draft))
        issues.append(contentsOf: lengthIssues(draft))

        // An empty name is not an issue: the scale gets a generated name, and the sheet shows
        // that name as the field's placeholder. The old "unnamed scales are hard to find"
        // advisory warned about a scale that was never going to be unnamed (IM-204).

        // Only compute a preview when the geometry and the lengths are actually usable;
        // showing "1:0" while the user is still typing is worse than showing nothing.
        let solved = makePreview(draft, unit: unit, locale: locale)
        let preview = solved.preview
        issues.append(contentsOf: solved.issues)

        var confirmed: Set<CalibrationIssue> = []
        if let preview {
            let extreme = !(minimumPlausibleScale...maximumPlausibleScale).contains(preview.sx)
                || !(minimumPlausibleScale...maximumPlausibleScale).contains(preview.sy)
            if extreme {
                issues.append(.extremeScale)
                if draft.confirmsExtremeScale { confirmed.insert(.extremeScale) }
            }
        }

        if draft.mode == .separateAxes, let angle = axisAngleDegrees(draft) {
            if angle < nearParallelDegrees {
                issues.append(.nearParallelAxes)
            } else if angle < obliqueDegrees {
                issues.append(.obliqueAxes)
                if draft.confirmsNearParallelAxes { confirmed.insert(.obliqueAxes) }
            }
        }

        return CalibrationValidation(issues: issues, preview: preview, confirmedIssues: confirmed)
    }

    // MARK: Drawing scale

    /// Drawing-scale mode: `sx = sy = n × 0.0254 / 72` metres per point, checked by the same
    /// extreme-scale rule as a picked calibration (IM-016).
    private static func validateDrawingScale(_ draft: CalibrationDraft, locale: Locale) -> CalibrationValidation {
        var issues: [CalibrationIssue] = []
        guard let denominator = draft.drawingScaleDenominator, denominator.isFinite, denominator > 0 else {
            return CalibrationValidation(issues: [.missingDrawingScale], preview: nil)
        }
        if let size = draft.pageSizePoints, StandardPaperSize.match(size) == nil {
            issues.append(.nonStandardPaperSize)
        }
        let sx = denominator * MeasurementUnitCatalog.metresPerPagePoint
        let preview = CalibrationPreview(
            sx: sx,
            sy: sx,
            isUniform: true,
            ratioString: MeasurementValueFormatter.ratioString(metresPerPagePoint: sx, locale: locale)
        )
        var confirmed: Set<CalibrationIssue> = []
        if !(minimumPlausibleScale...maximumPlausibleScale).contains(sx) {
            issues.append(.extremeScale)
            if draft.confirmsExtremeScale { confirmed.insert(.extremeScale) }
        }
        return CalibrationValidation(issues: issues, preview: preview, confirmedIssues: confirmed)
    }

    // MARK: Geometry

    private static func geometryIssues(_ draft: CalibrationDraft) -> [CalibrationIssue] {
        guard draft.mode != .drawingScale else { return [] }
        var issues: [CalibrationIssue] = []
        if let distance = draft.primary.pdfDistance {
            if distance <= identicalPointTolerance {
                issues.append(.identicalPrimaryPoints)
            } else if distance < shortBaselineThreshold {
                issues.append(.shortPrimaryBaseline)
            }
        } else {
            issues.append(.missingPrimaryPoints)
        }

        guard draft.mode == .separateAxes else { return issues }
        if let distance = draft.secondary.pdfDistance {
            if distance <= identicalPointTolerance {
                issues.append(.identicalSecondaryPoints)
            } else if distance < shortBaselineThreshold {
                issues.append(.shortSecondaryBaseline)
            }
        } else {
            issues.append(.missingSecondaryPoints)
        }
        return issues
    }

    private static func lengthIssues(_ draft: CalibrationDraft) -> [CalibrationIssue] {
        var issues: [CalibrationIssue] = []
        if let issue = lengthIssue(
            draft.primary,
            missing: .missingPrimaryLength,
            unparseable: .unparseablePrimaryLength,
            nonPositive: .nonPositivePrimaryLength,
            outOfRange: .outOfRangePrimaryLength
        ) {
            issues.append(issue)
        }

        guard draft.mode == .separateAxes else { return issues }
        if let issue = lengthIssue(
            draft.secondary,
            missing: .missingSecondaryLength,
            unparseable: .unparseableSecondaryLength,
            nonPositive: .nonPositiveSecondaryLength,
            outOfRange: .outOfRangeSecondaryLength
        ) {
            issues.append(issue)
        }
        return issues
    }

    private static func lengthIssue(
        _ input: CalibrationAxisInput,
        missing: CalibrationIssue,
        unparseable: CalibrationIssue,
        nonPositive: CalibrationIssue,
        outOfRange: CalibrationIssue
    ) -> CalibrationIssue? {
        guard let value = input.knownLength else {
            let typed = input.unparsedLengthText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return typed.isEmpty ? missing : unparseable
        }
        if !(value > 0) || !value.isFinite { return nonPositive }
        if !allowedLengthRange.contains(value) { return outOfRange }
        return nil
    }

    /// Whether a known length is one a scale may be computed from.
    private static func isUsableLength(_ value: Double?) -> Bool {
        guard let value, value.isFinite else { return false }
        return allowedLengthRange.contains(value)
    }

    /// The unsigned angle between the two calibration lines, folded into `0...90` degrees.
    ///
    /// Direction does not matter — a line drawn right-to-left calibrates the same axis as one
    /// drawn left-to-right — so 175° between the two lines is 5° of separation, not 175°.
    public static func axisAngleDegrees(_ draft: CalibrationDraft) -> Double? {
        guard let a = draft.primary.directionRadians,
              let b = draft.secondary.directionRadians
        else { return nil }
        var degrees = abs((a - b) * 180 / .pi).truncatingRemainder(dividingBy: 180)
        if degrees > 90 { degrees = 180 - degrees }
        return degrees
    }

    // MARK: Preview

    private static func makePreview(
        _ draft: CalibrationDraft,
        unit: LengthUnit,
        locale: Locale
    ) -> (preview: CalibrationPreview?, issues: [CalibrationIssue]) {
        guard let primaryDistance = draft.primary.pdfDistance,
              primaryDistance > identicalPointTolerance,
              let primaryLength = draft.primary.knownLength,
              isUsableLength(primaryLength)
        else { return (nil, []) }

        let metresPerUnit = NSDecimalNumber(decimal: unit.metresPerUnit).doubleValue
        let uniformSX = primaryLength * metresPerUnit / primaryDistance

        guard draft.mode == .separateAxes else {
            return (CalibrationPreview(
                sx: uniformSX,
                sy: uniformSX,
                isUniform: true,
                ratioString: MeasurementValueFormatter.ratioString(metresPerPagePoint: uniformSX, locale: locale)
            ), [])
        }

        guard let secondaryDistance = draft.secondary.pdfDistance,
              secondaryDistance > identicalPointTolerance,
              let secondaryLength = draft.secondary.knownLength,
              isUsableLength(secondaryLength),
              let primaryStart = draft.primary.start, let primaryEnd = draft.primary.end,
              let secondaryStart = draft.secondary.start, let secondaryEnd = draft.secondary.end
        else {
            // The X axis alone is still worth previewing; the sheet shows the Y issues next to
            // the Y controls, so a partially filled separate-axis draft is not a blank panel.
            return (CalibrationPreview(
                sx: uniformSX,
                sy: uniformSX,
                isUniform: true,
                ratioString: MeasurementValueFormatter.ratioString(metresPerPagePoint: uniformSX, locale: locale),
                axisAngleDegrees: axisAngleDegrees(draft)
            ), [])
        }

        // Separate X / Y calibration solves for the page-axis scales, not for the lines.
        //
        // A drawing stretched along the page axes maps a line with page components (dx, dy)
        // to the real length L where L² = (sx·dx)² + (sy·dy)². Two lines give two equations,
        // linear in sx² and sy². Dividing each known length by its line's full Euclidean
        // length instead — which this did — is only right for a perfectly horizontal X line
        // and a perfectly vertical Y line: a 45° and a 135° line on a drawing stretched 10 %
        // in Y came out sx == sy with a 0.00 % residual, and both committed scales were wrong
        // (BH-252). For axis-aligned lines the solve reduces exactly to the old division.
        let real1 = primaryLength * metresPerUnit
        let real2 = secondaryLength * metresPerUnit
        let dx1 = primaryEnd.x - primaryStart.x, dy1 = primaryEnd.y - primaryStart.y
        let dx2 = secondaryEnd.x - secondaryStart.x, dy2 = secondaryEnd.y - secondaryStart.y
        let a1 = dx1 * dx1, b1 = dy1 * dy1
        let a2 = dx2 * dx2, b2 = dy2 * dy2
        let determinant = a1 * b2 - a2 * b1
        // Conditioning, normalised by the squared line lengths so it is scale-free:
        // |sin(θ2 - θ1) · sin(θ2 + θ1)|.
        let separability = abs(determinant) / ((a1 + b1) * (a2 + b2))
        guard separability >= minimumAxisSeparability else {
            // Parallel lines are reported by the angle check; a mirror pair is not parallel
            // and needs its own sentence.
            let angle = axisAngleDegrees(draft) ?? 0
            return (nil, angle < nearParallelDegrees ? [] : [.mirroredAxes])
        }
        let sx2 = (real1 * real1 * b2 - real2 * real2 * b1) / determinant
        let sy2 = (a1 * real2 * real2 - a2 * real1 * real1) / determinant
        guard sx2 > 0, sy2 > 0, sx2.isFinite, sy2.isFinite else {
            return (nil, [.inconsistentAxes])
        }
        let sx = sx2.squareRoot()
        let sy = sy2.squareRoot()
        let residual = abs(sx - sy) / Swift.max(sx, sy)
        return (CalibrationPreview(
            sx: sx,
            sy: sy,
            isUniform: residual < 1e-9,
            ratioString: MeasurementValueFormatter.ratioString(metresPerPagePoint: sx, locale: locale),
            secondaryRatioString: MeasurementValueFormatter.ratioString(metresPerPagePoint: sy, locale: locale),
            axisAngleDegrees: axisAngleDegrees(draft),
            residual: residual
        ), [])
    }

    /// Turns a validated draft into the scale summary the rest of the app carries.
    ///
    /// Returns `nil` when the draft cannot be applied, so a caller physically cannot commit a
    /// blocked calibration by mistake.
    public static func makeScaleSummary(
        from draft: CalibrationDraft,
        id: UUID = UUID(),
        version: Int = 1,
        locale: Locale = .current
    ) -> ScaleSummary? {
        let validation = validate(draft, locale: locale)
        guard validation.canApply, let preview = validation.preview, let unit = draft.resolvedUnit
        else { return nil }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? generatedName(for: preview) : trimmed
        return ScaleSummary(
            id: id,
            name: name,
            // Both axes for a separate X / Y scale, as ``ScaleSummary/displayString`` is written
            // everywhere else — it carried the X ratio alone (L-38).
            displayString: ScaleRatioText.ratio(
                metresPerPointX: preview.sx,
                metresPerPointY: preview.sy,
                isUniform: preview.isUniform,
                locale: locale
            ),
            isUniform: preview.isUniform,
            sx: preview.sx,
            sy: preview.sy,
            unit: unit,
            version: version,
            locked: false
        )
    }
}
