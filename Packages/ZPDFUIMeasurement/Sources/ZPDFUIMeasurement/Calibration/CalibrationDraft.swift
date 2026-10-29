import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Mode

/// Uniform two-point calibration, or separate X and Y calibration.
public enum CalibrationMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// One line and one known length; `sx == sy`.
    case uniform
    /// Two lines and two known lengths; `sx` and `sy` are calibrated independently.
    case separateAxes
    /// The ratio printed in the title block — 1:50, or 1/8" = 1'-0" — with no points picked.
    ///
    /// The common case for a vector drawing set, in one step (IM-016). It is only right when
    /// the PDF is at its true paper size, which the validator checks as far as it can.
    case drawingScale

    public var id: String { rawValue }

    /// A localized name for the mode picker.
    public var displayName: String {
        switch self {
        case .uniform:
            return NSLocalizedString("Uniform", comment: "Calibration mode: one scale for both axes")
        case .separateAxes:
            return NSLocalizedString("Separate X / Y", comment: "Calibration mode: axis-separated scale")
        case .drawingScale:
            return NSLocalizedString("Drawing scale", comment: "Calibration mode: the ratio printed on the drawing")
        }
    }

    /// One line of help under the mode picker.
    public var explanation: String {
        switch self {
        case .uniform:
            return NSLocalizedString(
                "Pick two points on a known dimension. One scale applies to the whole page.",
                comment: "Help text for uniform calibration"
            )
        case .separateAxes:
            return NSLocalizedString(
                "Calibrate a horizontal and a vertical dimension separately, for drawings that are stretched on one axis.",
                comment: "Help text for separate axis calibration"
            )
        case .drawingScale:
            return NSLocalizedString(
                "Choose the scale printed in the title block. This is only correct when the PDF is at its true paper size.",
                comment: "Help text for drawing-scale calibration"
            )
        }
    }
}

// MARK: - Axis input

/// One calibration line: two picked page points and the real-world length they represent.
public struct CalibrationAxisInput: Codable, Hashable, Sendable {

    /// First picked point in page space, or `nil` while the user is still picking.
    public var start: PDFPointValue?
    /// Second picked point in page space.
    public var end: PDFPointValue?
    /// The known real-world length, expressed in the draft's unit. `nil` means not entered.
    public var knownLength: Double?
    /// Text the length field is holding that is not a length, when that is why ``knownLength``
    /// is `nil`.
    ///
    /// Set only by ``CalibrationDraft/resolvingPendingLengths(primary:secondary:)``. Without it
    /// the validator could not tell "nothing typed" from "typed `12x`", and told a person who
    /// had just typed a length to enter one (IM-017).
    public var unparsedLengthText: String?

    public init(
        start: PDFPointValue? = nil,
        end: PDFPointValue? = nil,
        knownLength: Double? = nil,
        unparsedLengthText: String? = nil
    ) {
        self.start = start
        self.end = end
        self.knownLength = knownLength
        self.unparsedLengthText = unparsedLengthText
    }

    /// Distance between the picked points in PDF page points, or `nil` while incomplete.
    public var pdfDistance: Double? {
        guard let start, let end else { return nil }
        return start.distance(to: end)
    }

    /// Direction of the line in radians, or `nil` while incomplete or degenerate.
    public var directionRadians: Double? {
        guard let start, let end else { return nil }
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx != 0 || dy != 0 else { return nil }
        return atan2(dy, dx)
    }

    /// How many points still need picking, for the step indicator.
    public var pickedPointCount: Int {
        (start == nil ? 0 : 1) + (end == nil ? 0 : 1)
    }
}

// MARK: - Draft

/// Everything the calibration sheet collects before it is allowed to commit.
public struct CalibrationDraft: Codable, Hashable, Sendable {

    /// Uniform or separate axes.
    public var mode: CalibrationMode
    /// The single line in uniform mode, the X line in separate mode.
    public var primary: CalibrationAxisInput
    /// The Y line. Ignored in uniform mode.
    public var secondary: CalibrationAxisInput
    /// The unit identifier chosen in the picker.
    ///
    /// Deliberately a `String` and not a `LengthUnit`: the picker is a free identifier and an
    /// unresolvable one is a real, blockable error rather than something to silently default.
    public var unitIdentifier: String
    /// Fraction precision applied to imperial entry and readout.
    public var imperialPrecision: ImperialPrecision
    /// What the resulting scale will be called.
    public var name: String
    /// The user ticked the extreme-scale confirmation.
    public var confirmsExtremeScale: Bool
    /// The user ticked the near-parallel confirmation.
    public var confirmsNearParallelAxes: Bool
    /// Apply the finished scale to more than the current page.
    public var appliesBeyondCurrentPage: Bool
    /// The `n` of a `1:n` drawing scale, used in ``CalibrationMode/drawingScale`` mode.
    public var drawingScaleDenominator: Double?
    /// The page's size in PDF points, when the host knows it, so a drawing scale can be
    /// checked against the standard paper sizes it only holds for.
    public var pageSizePoints: PDFSizeValue?

    public init(
        mode: CalibrationMode = .uniform,
        primary: CalibrationAxisInput = CalibrationAxisInput(),
        secondary: CalibrationAxisInput = CalibrationAxisInput(),
        unitIdentifier: String = LengthUnit.metre.rawValue,
        imperialPrecision: ImperialPrecision = .sixteenth,
        name: String = "",
        confirmsExtremeScale: Bool = false,
        confirmsNearParallelAxes: Bool = false,
        appliesBeyondCurrentPage: Bool = false,
        drawingScaleDenominator: Double? = nil,
        pageSizePoints: PDFSizeValue? = nil
    ) {
        self.drawingScaleDenominator = drawingScaleDenominator
        self.pageSizePoints = pageSizePoints
        self.mode = mode
        self.primary = primary
        self.secondary = secondary
        self.unitIdentifier = unitIdentifier
        self.imperialPrecision = imperialPrecision
        self.name = name
        self.confirmsExtremeScale = confirmsExtremeScale
        self.confirmsNearParallelAxes = confirmsNearParallelAxes
        self.appliesBeyondCurrentPage = appliesBeyondCurrentPage
    }

    /// The resolved unit, or `nil` when ``unitIdentifier`` names nothing Zenit can measure in.
    public var resolvedUnit: LengthUnit? {
        MeasurementUnitCatalog.lengthUnit(forIdentifier: unitIdentifier)
    }

    /// Whether the sheet should show the imperial fraction precision control.
    public var showsImperialPrecision: Bool {
        guard let resolvedUnit else { return false }
        return !resolvedUnit.isMetric
    }

    /// The draft with the length fields' uncommitted text folded into ``primary`` and
    /// ``secondary``.
    ///
    /// A text field only writes back when it loses focus or the user presses Return, so the
    /// first click on Apply is spent committing the field and a second is needed to apply —
    /// live finding LT-5. The fix is not to guess at focus ordering but to let the field say
    /// what it is holding, and to validate and commit the draft that includes it. Reading the
    /// field's current text rather than the last-committed binding is the whole of it.
    ///
    /// Resolution is safe in the blocking direction: text that is not a length clears that
    /// axis's length instead of leaving the previous one standing, so Apply can never commit
    /// a number the field has stopped showing.
    public func resolvingPendingLengths(
        primary primaryText: String = "",
        secondary secondaryText: String = ""
    ) -> CalibrationDraft {
        var resolved = self
        switch CalibrationPendingLength.reading(primaryText, unit: resolvedUnit) {
        case .none: break
        case .length(let value):
            resolved.primary.knownLength = value
            resolved.primary.unparsedLengthText = nil
        case .unusable:
            resolved.primary.knownLength = nil
            resolved.primary.unparsedLengthText = primaryText
        }
        guard mode == .separateAxes else { return resolved }
        switch CalibrationPendingLength.reading(secondaryText, unit: resolvedUnit) {
        case .none: break
        case .length(let value):
            resolved.secondary.knownLength = value
            resolved.secondary.unparsedLengthText = nil
        case .unusable:
            resolved.secondary.knownLength = nil
            resolved.secondary.unparsedLengthText = secondaryText
        }
        return resolved
    }

    /// A fresh draft that starts where the last calibration on this project left off.
    ///
    /// Every new sheet used to open in metres at 1/16, uniform — so the second sheet of an
    /// imperial set started in the wrong unit, which is the classic wrong-unit calibration
    /// (IM-101). The host passes the scale it applied last; `nil` gives the plain defaults.
    public static func seeded(
        from lastScale: ScaleSummary?,
        precision: ImperialPrecision = .sixteenth
    ) -> CalibrationDraft {
        guard let lastScale else { return CalibrationDraft(imperialPrecision: precision) }
        return CalibrationDraft(
            mode: lastScale.isUniform ? .uniform : .separateAxes,
            unitIdentifier: lastScale.unit.rawValue,
            imperialPrecision: precision
        )
    }

    /// The inputs that decide the number the scale comes out as.
    ///
    /// A confirmation is given for one scale. When any of these change, the scale the
    /// person confirmed is no longer the one on screen, so the tick must not carry over
    /// (BH-251).
    public struct ScaleInputs: Hashable, Sendable {
        let mode: CalibrationMode
        let primary: CalibrationAxisInput
        let secondary: CalibrationAxisInput
        let unitIdentifier: String
        let drawingScaleDenominator: Double?
    }

    /// The scale-deciding inputs of this draft.
    public var scaleInputs: ScaleInputs {
        ScaleInputs(
            mode: mode,
            primary: primary,
            secondary: secondary,
            unitIdentifier: unitIdentifier,
            drawingScaleDenominator: drawingScaleDenominator
        )
    }

    /// Clears both confirmations when the scale-deciding inputs differ from `previous`.
    ///
    /// Finding BH-251: once ticked, `confirmsExtremeScale` survived every later edit, so a
    /// second, different extreme value was committed with no warning at all.
    public mutating func clearConfirmationsIfScaleChanged(from previous: ScaleInputs) {
        guard previous != scaleInputs else { return }
        confirmsExtremeScale = false
        confirmsNearParallelAxes = false
    }

    /// Which axis the next click fills, so the sheet can tell the user what to do next.
    public var nextPickStep: CalibrationPickStep {
        guard mode != .drawingScale else { return .done }
        if primary.pickedPointCount < 2 {
            return mode == .uniform
                ? (primary.pickedPointCount == 0 ? .primaryStart : .primaryEnd)
                : (primary.pickedPointCount == 0 ? .xAxisStart : .xAxisEnd)
        }
        guard mode == .separateAxes else { return .done }
        if secondary.pickedPointCount < 2 {
            return secondary.pickedPointCount == 0 ? .yAxisStart : .yAxisEnd
        }
        return .done
    }
}

// MARK: - Pending length

/// What a calibration length field is holding but has not committed yet.
///
/// The distinction that matters is between *nothing pending* and *pending nonsense*. An empty
/// field is the first: the draft's own length stands, because the field is simply not the place
/// the value came from. Text that will not parse is the second, and it has to block, because
/// the person is looking at characters that are not the number the draft still holds.
public enum CalibrationPendingLength: Hashable, Sendable {

    /// The field has nothing uncommitted.
    case none
    /// The field is holding a usable length, expressed in the draft's unit.
    case length(Double)
    /// The field is holding text that is not a length.
    case unusable

    /// Reads a field's current text as a length in `unit`.
    ///
    /// Imperial units accept what an estimator types off a drawing — `12' 6 1/2"`, `6 1/2`,
    /// `12 ft 6 in` — through the same parser the field's own echo uses. Metric units accept
    /// both `12,5` and `12.5`, so a Swedish keyboard is not a parse failure.
    ///
    /// A **bare** number under an imperial unit is read in the unit the popup names, not in
    /// inches. `12` with feet chosen is twelve feet: reading it as twelve inches calibrated the
    /// whole sheet at a twelfth of the intended scale, silently, from an entry the person had
    /// every reason to think was unambiguous. Finding CR-165.
    public static func reading(_ text: String, unit: LengthUnit?) -> CalibrationPendingLength {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        guard let unit else { return .unusable }

        if unit.isMetric || ImperialLengthFormatter.isBareNumber(trimmed) {
            guard let value = parseDecimal(trimmed) else { return .unusable }
            return .length(value)
        }

        // A mixed number with no mark of its own — `6 1/2`, `1/2` — is a number in the popup's
        // unit exactly as `6.5` is. It used to be read as inches whatever the popup said, so
        // under feet the two spellings calibrated a factor of twelve apart (BH-247).
        if ImperialLengthFormatter.isUnitless(trimmed) {
            guard let value = ImperialLengthFormatter.parseUnitlessNumber(trimmed) else { return .unusable }
            return .length(value)
        }

        guard let inches = ImperialLengthFormatter.parseInches(trimmed) else { return .unusable }
        let metresPerUnit = NSDecimalNumber(decimal: unit.metresPerUnit).doubleValue
        return .length(inches * ImperialLengthFormatter.metresPerInch / metresPerUnit)
    }

    /// Parses a decimal through the one grammar every Zenit field shares (CR-184).
    ///
    /// Both `12,5` and `12.5` work whatever the keyboard layout, `1 200` is twelve hundred, and
    /// `nan` — which the old `Double(string)` fallback accepted and handed to the validator's
    /// `value > 0` check as neither true nor false — does not parse at all.
    static func parseDecimal(_ string: String) -> Double? {
        ZPDFDecimalParser.double(string, allowingExponent: true)
    }
}

/// The point the calibration flow is waiting for.
public enum CalibrationPickStep: String, Hashable, Sendable, CaseIterable {
    case primaryStart
    case primaryEnd
    case xAxisStart
    case xAxisEnd
    case yAxisStart
    case yAxisEnd
    case done

    /// The instruction shown above the canvas and spoken when the step changes.
    public var instruction: String {
        switch self {
        case .primaryStart:
            return NSLocalizedString("Click the first point of a known dimension.", comment: "Calibration step")
        case .primaryEnd:
            return NSLocalizedString("Click the second point of the same dimension.", comment: "Calibration step")
        case .xAxisStart:
            return NSLocalizedString("Click the first point of a known horizontal dimension.", comment: "Calibration step")
        case .xAxisEnd:
            return NSLocalizedString("Click the second point of the horizontal dimension.", comment: "Calibration step")
        case .yAxisStart:
            return NSLocalizedString("Click the first point of a known vertical dimension.", comment: "Calibration step")
        case .yAxisEnd:
            return NSLocalizedString("Click the second point of the vertical dimension.", comment: "Calibration step")
        case .done:
            return NSLocalizedString("Enter the real-world lengths, then apply the scale.", comment: "Calibration step")
        }
    }
}

// MARK: - Drawing scale presets

/// A drawing scale as a title block prints it.
public struct DrawingScalePreset: Identifiable, Hashable, Sendable {

    /// The printed form: `1:50`, or `1/8" = 1'-0"`. A drawing notation, not translated.
    public let title: String
    /// The `n` of the equivalent `1:n`.
    public let denominator: Double

    public var id: String { title }

    public init(title: String, denominator: Double) {
        self.title = title
        self.denominator = denominator
    }

    /// Metric ratios in common use on construction drawings.
    public static let metric: [DrawingScalePreset] = [1, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000].map {
        DrawingScalePreset(title: "1:\($0)", denominator: Double($0))
    }

    /// Architectural and engineering imperial scales, as `1:n` (1/8" = 1'-0" is 1:96).
    public static let imperial: [DrawingScalePreset] = [
        DrawingScalePreset(title: "1\" = 1'-0\"", denominator: 12),
        DrawingScalePreset(title: "1/2\" = 1'-0\"", denominator: 24),
        DrawingScalePreset(title: "1/4\" = 1'-0\"", denominator: 48),
        DrawingScalePreset(title: "3/16\" = 1'-0\"", denominator: 64),
        DrawingScalePreset(title: "1/8\" = 1'-0\"", denominator: 96),
        DrawingScalePreset(title: "3/32\" = 1'-0\"", denominator: 128),
        DrawingScalePreset(title: "1/16\" = 1'-0\"", denominator: 192),
        DrawingScalePreset(title: "1\" = 10'", denominator: 120),
        DrawingScalePreset(title: "1\" = 20'", denominator: 240),
        DrawingScalePreset(title: "1\" = 50'", denominator: 600),
        DrawingScalePreset(title: "1\" = 100'", denominator: 1200)
    ]
}

/// The standard paper sizes a drawing scale is printed for, in PDF points.
public enum StandardPaperSize {

    /// ISO A0–A4, ANSI A–E and ARCH A–E1, portrait.
    public static let sizes: [(name: String, width: Double, height: Double)] = [
        ("A0", 2384, 3370), ("A1", 1684, 2384), ("A2", 1191, 1684), ("A3", 842, 1191), ("A4", 595, 842),
        ("ANSI A", 612, 792), ("ANSI B", 792, 1224), ("ANSI C", 1224, 1584), ("ANSI D", 1584, 2448),
        ("ANSI E", 2448, 3168), ("ARCH A", 648, 864), ("ARCH B", 864, 1296), ("ARCH C", 1296, 1728),
        ("ARCH D", 1728, 2592), ("ARCH E", 2592, 3456), ("ARCH E1", 2160, 3024)
    ]

    /// The standard size `size` matches in either orientation, within 1 %, or `nil`.
    public static func match(_ size: PDFSizeValue) -> String? {
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        return sizes.first { entry in
            abs(short - entry.width) <= entry.width * 0.01 && abs(long - entry.height) <= entry.height * 0.01
        }?.name
    }
}
