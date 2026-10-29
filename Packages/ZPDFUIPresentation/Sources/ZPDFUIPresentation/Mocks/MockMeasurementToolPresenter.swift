// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation
import Observation

/// Mock implementation of ``MeasurementToolPresenting``.
///
/// Live values are computed from the placed points and the sample scale, so the
/// measurement HUD, the caption and the inspector can be developed against a value that
/// actually changes as points are added.
@MainActor
@Observable
public final class MockMeasurementToolPresenter: MeasurementToolPresenting {

    public let availableKinds: [MeasurementKind] = MeasurementKind.allCases
    public private(set) var activeKind: MeasurementKind?
    public private(set) var lastUsedKinds: [MeasurementKind] = [.area, .polylength, .count]
    public private(set) var activeScale: ScaleSummary?
    public private(set) var lengthUnit: LengthUnit = .metre
    public private(set) var areaUnit: AreaUnit = .squareMetre
    public private(set) var volumeUnit: VolumeUnit = .cubicMetre
    public private(set) var slopeDisplayMode: SlopeDisplayMode = .percent
    public private(set) var imperialPrecision: ImperialPrecision = .sixteenth
    public private(set) var liveFields: [MeasurementFieldSummary] = []
    public private(set) var liveWarnings: [MeasurementWarningSummary] = []
    public private(set) var snapFeedback: SnapFeedbackSnapshot?
    public private(set) var placedPoints: [PDFPointValue] = []
    public private(set) var isTemporaryMeasurement: Bool = false
    public private(set) var temporaryMeasurements: [MarkupSummary] = []

    /// Called when a measurement is committed, so the canvas can draw the new markup.
    public var onCommit: (@MainActor (MarkupSummary) -> Void)?

    private let project: ZenitSampleProject
    private var committedCount = 0

    /// The page a commit lands on. ``MockPresenterEnvironment`` wires it to the canvas, so a
    /// measurement committed on sheet two is stamped with sheet two (BH-277).
    public var currentPageProvider: (@MainActor () -> PageDescriptor.ID?)?

    /// The scale in force where the estimator is measuring. ``MockPresenterEnvironment``
    /// wires it to the canvas's Scale Region resolution (BH-773).
    public var scaleProvider: (@MainActor () -> ScaleSummary?)?

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.project = project
        self.activeScale = project.defaultScale
    }

    public private(set) var parameterText: String = ""
    public private(set) var parameterValue: Decimal?

    public var canCommit: Bool {
        guard let activeKind else { return false }
        guard placedPoints.count >= activeKind.minimumPointCount else { return false }
        guard !isMissingRequiredParameter else { return false }
        return !hasBlockingWarning
    }

    public func setParameterText(_ text: String) {
        parameterText = text
        parameterValue = Self.parseParameter(text)
        // BH-276: a new depth or height changes the live value at once.
        recomputeLiveValues()
    }

    /// Reads a typed parameter by the product's shared grammar, ``TypedDecimalGrammar`` — the
    /// one the app core's options bar reads with (X-020), not a copy of it. BH-774:
    /// `Decimal(string:locale:)` read "0,30" as its prefix 0 — a zero depth that bypassed the
    /// missing-value refusal.
    static func parseParameter(_ text: String) -> Decimal? {
        TypedDecimalGrammar.decimal(text)
    }

    // MARK: Tool selection

    public func activate(kind: MeasurementKind) {
        activeKind = kind
        isTemporaryMeasurement = kind.isTemporary
        parameterText = ""
        parameterValue = nil
        placedPoints = []
        liveFields = []
        liveWarnings = []
        lastUsedKinds = ([kind] + lastUsedKinds.filter { $0 != kind }).prefix(6).map { $0 }
    }

    public func deactivate() {
        activeKind = nil
        isTemporaryMeasurement = false
        placedPoints = []
        liveFields = []
        liveWarnings = []
        snapFeedback = nil
    }

    // MARK: Point handling

    public func placePoint(_ point: PDFPointValue) {
        guard activeKind != nil else { return }
        placedPoints.append(point)
        recomputeLiveValues()
    }

    public func removeLastPoint() {
        guard !placedPoints.isEmpty else { return }
        placedPoints.removeLast()
        recomputeLiveValues()
    }

    public func cancelActiveMeasurement() {
        placedPoints = []
        liveFields = []
        liveWarnings = []
    }

    public func commitActiveMeasurement() {
        guard canCommit, let activeKind else { return }
        let markup = makeMarkup(kind: activeKind)
        if isTemporaryMeasurement {
            temporaryMeasurements.append(markup)
        } else {
            onCommit?(markup)
        }
        committedCount += 1
        placedPoints = []
        liveFields = []
        liveWarnings = []
    }

    public func promoteTemporaryMeasurementsToMarkups() {
        for measurement in temporaryMeasurements {
            var promoted = measurement
            promoted.comment = NSLocalizedString(
                "Promoted from a temporary measurement.",
                comment: "Comment written when a temporary measurement becomes a markup"
            )
            onCommit?(promoted)
        }
        temporaryMeasurements = []
    }

    public func clearTemporaryMeasurements() { temporaryMeasurements = [] }

    // MARK: Units

    public func setLengthUnit(_ unit: LengthUnit) {
        lengthUnit = unit
        areaUnit = unit.areaCounterpart
        recomputeLiveValues()
    }

    public func setAreaUnit(_ unit: AreaUnit) {
        areaUnit = unit
        recomputeLiveValues()
    }

    public func setVolumeUnit(_ unit: VolumeUnit) {
        volumeUnit = unit
        recomputeLiveValues()
    }

    public func setSlopeDisplayMode(_ mode: SlopeDisplayMode) { slopeDisplayMode = mode }

    public func setImperialPrecision(_ precision: ImperialPrecision) {
        imperialPrecision = precision
        recomputeLiveValues()
    }

    // MARK: Live computation

    /// Recomputes ``liveFields`` and ``liveWarnings`` from the placed points.
    ///
    /// Lengths use `Σ ||A × Δp||` and areas the shoelace formula multiplied by
    /// `abs(det(A))`, matching the contract the real engine will implement.
    private func recomputeLiveValues() {
        if let scaleProvider { activeScale = scaleProvider() ?? project.defaultScale }
        guard let activeKind, let scale = activeScale else {
            liveFields = []
            liveWarnings = activeScale == nil ? [.missingScale] : []
            return
        }

        var warnings: [MeasurementWarningSummary] = []
        var fields: [MeasurementFieldSummary] = []

        // The typed parameter is in the active length unit; the engine works in metres.
        let parameterMetres = parameterValue.map { $0 * lengthUnit.metresPerUnit }

        switch activeKind {
        case .count:
            fields.append(ZenitSampleProject.fieldSummary(.count, DecimalQuantity.count(Decimal(placedPoints.count))))
        case .angle:
            // BH-776: an angle is an angle, not a count of its points.
            if let degrees = vertexAngleDegrees() {
                fields.append(angleField(.angle, degrees: degrees))
            }
        case .slope:
            // BH-776: the steepness is the typed parameter; the drawn run is its plan length.
            if let percent = parameterValue {
                fields.append(MeasurementFieldSummary(
                    field: .slopeRatio,
                    quantity: DecimalQuantity(value: percent / 100, dimension: .ratio),
                    displayText: SampleFormatting.string(percent / 100, fractionDigits: 2),
                    displayUnitSymbol: ""
                ))
            }
            fields.append(lengthField(.planLength, metres: Decimal(planLengthInMetres(scale: scale)), isDerived: true))
        case .perimeter:
            // BH-275: a perimeter is closed — the segment back to the first point counts.
            fields.append(lengthField(.perimeter, metres: Decimal(closedPerimeterInMetres(scale: scale))))
        case .wallArea:
            // BH-276: a wall's area is its drawn run times the typed height.
            let run = Decimal(planLengthInMetres(scale: scale))
            if let height = parameterMetres {
                fields.append(areaField(.wallArea, squareMetres: run * height))
                fields.append(lengthField(.height, metres: height, isDerived: true))
            }
            fields.append(lengthField(.planLength, metres: run, isDerived: true))
        case .volume:
            // BH-276: the depth is the one the estimator typed, not a hard-coded 0.30 m.
            let squareMetres = Decimal(planAreaInSquareMetres(scale: scale))
            if let depth = parameterMetres {
                fields.append(volumeField(.volume, cubicMetres: squareMetres * depth))
                fields.append(lengthField(.depth, metres: depth, isDerived: true))
            }
            fields.append(areaField(.planArea, squareMetres: squareMetres, isDerived: true))
        default:
            switch activeKind.dimension.lengthPower {
            case 1:
                let metres = Decimal(planLengthInMetres(scale: scale))
                if placedPoints.count >= 2, metres == 0 { warnings.append(.degenerateGeometry) }
                fields.append(lengthField(activeKind.primaryField, metres: metres))
            case 2:
                let squareMetres = Decimal(planAreaInSquareMetres(scale: scale))
                if placedPoints.count >= 3, squareMetres == 0 { warnings.append(.degenerateGeometry) }
                fields.append(areaField(activeKind.primaryField, squareMetres: squareMetres))
                fields.append(lengthField(.perimeter, metres: Decimal(closedPerimeterInMetres(scale: scale)), isDerived: true))
            default:
                fields.append(ZenitSampleProject.fieldSummary(.count, DecimalQuantity.count(Decimal(placedPoints.count))))
            }
        }

        liveFields = fields
        liveWarnings = warnings
    }

    // MARK: Display units (BH-775)

    /// A length field shown in the active length unit, rounded to the imperial precision for
    /// an imperial unit.
    private func lengthField(_ field: MeasurementField, metres: Decimal, isDerived: Bool = false) -> MeasurementFieldSummary {
        let shown = metres / lengthUnit.metresPerUnit
        return MeasurementFieldSummary(
            field: field, quantity: .metres(metres),
            displayText: displayText(shown, imperial: !lengthUnit.isMetric),
            displayUnitSymbol: lengthUnit.symbol, isDerived: isDerived
        )
    }

    private func areaField(_ field: MeasurementField, squareMetres: Decimal, isDerived: Bool = false) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: field, quantity: .squareMetres(squareMetres),
            displayText: SampleFormatting.string(squareMetres / areaUnit.squareMetresPerUnit, fractionDigits: 2),
            displayUnitSymbol: areaUnit.symbol, isDerived: isDerived
        )
    }

    private func volumeField(_ field: MeasurementField, cubicMetres: Decimal) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: field, quantity: .cubicMetres(cubicMetres),
            displayText: SampleFormatting.string(cubicMetres / volumeUnit.cubicMetresPerUnit, fractionDigits: 2),
            displayUnitSymbol: volumeUnit.symbol
        )
    }

    private func angleField(_ field: MeasurementField, degrees: Double) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: field, quantity: .radians(Decimal(degrees * .pi / 180)),
            displayText: String(format: "%.1f", degrees),
            displayUnitSymbol: AngleDisplayUnit.degrees.symbol
        )
    }

    /// A value in a display unit: two decimals metric, the nearest imperial fraction imperial.
    private func displayText(_ value: Decimal, imperial: Bool) -> String {
        guard imperial else { return SampleFormatting.string(value, fractionDigits: 2) }
        let denominator = Double(max(1, imperialPrecision.denominator))
        let rounded = (NSDecimalNumber(decimal: value).doubleValue * denominator).rounded() / denominator
        return SampleFormatting.string(Decimal(rounded), fractionDigits: 4)
    }

    /// The angle at the middle of three points, in degrees.
    private func vertexAngleDegrees() -> Double? {
        guard placedPoints.count >= 3 else { return nil }
        let a = placedPoints[0], vertex = placedPoints[1], b = placedPoints[2]
        let v1 = (a.x - vertex.x, a.y - vertex.y)
        let v2 = (b.x - vertex.x, b.y - vertex.y)
        let lengths = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot() * (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        guard lengths > 0 else { return nil }
        let cosine = max(-1, min(1, (v1.0 * v2.0 + v1.1 * v2.1) / lengths))
        return acos(cosine) * 180 / .pi
    }

    /// Open polyline length in metres.
    private func planLengthInMetres(scale: ScaleSummary) -> Double {
        guard placedPoints.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<placedPoints.count {
            let previous = placedPoints[index - 1]
            let current = placedPoints[index]
            let dx = (current.x - previous.x) * scale.sx
            let dy = (current.y - previous.y) * scale.sy
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    /// Closed outline length in metres.
    private func closedPerimeterInMetres(scale: ScaleSummary) -> Double {
        guard placedPoints.count >= 3, let first = placedPoints.first, let last = placedPoints.last
        else { return 0 }
        let dx = (first.x - last.x) * scale.sx
        let dy = (first.y - last.y) * scale.sy
        return planLengthInMetres(scale: scale) + (dx * dx + dy * dy).squareRoot()
    }

    /// Shoelace polygon area in square metres.
    private func planAreaInSquareMetres(scale: ScaleSummary) -> Double {
        guard placedPoints.count >= 3 else { return 0 }
        var doubled = 0.0
        for index in placedPoints.indices {
            let current = placedPoints[index]
            let next = placedPoints[(index + 1) % placedPoints.count]
            doubled += current.x * next.y - next.x * current.y
        }
        return abs(doubled) / 2 * scale.areaFactor
    }

    /// Builds the markup a commit would produce.
    private func makeMarkup(kind: MeasurementKind) -> MarkupSummary {
        // BH-277: the page the estimator is on, not always sheet one.
        let currentID = currentPageProvider?()
        let page = project.pages.first { $0.id == currentID } ?? project.pages[0]
        let bounds = boundsOfPlacedPoints() ?? PDFRectValue(x: 0, y: 0, width: 1, height: 1)
        let now = SampleFormatting.sampleDate(days: 30, hours: committedCount)
        return MarkupSummary(
            id: SampleFormatting.sampleID(2_000 + committedCount),
            kind: kind == .count ? .count : .measurement,
            measurementKind: kind,
            subject: kind.displayName,
            label: NSLocalizedString("New measurement", comment: "Default label for a freshly committed measurement"),
            pageLabel: page.label,
            pageID: page.id,
            pageIndex: page.index,
            status: .open,
            author: "A. Mason",
            colorRGBA: ZenitSampleProject.color(for: kind.dimension),
            measurementFields: liveFields,
            created: now,
            modified: now,
            boundsInPageSpace: bounds
        )
    }

    /// Axis-aligned bounds of the placed points.
    private func boundsOfPlacedPoints() -> PDFRectValue? {
        guard let first = placedPoints.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in placedPoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
#endif
