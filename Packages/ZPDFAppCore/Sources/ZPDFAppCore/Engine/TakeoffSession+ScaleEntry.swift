import Foundation
import ZPDFContracts

/// Where a scale applied to several pages at once comes from (NL-MEASURE-02).
public enum BulkScaleSource: Hashable, Sendable {
    /// A drawing ratio such as `1:50`. Every page gets its own preset scale, honouring that
    /// page's `/UserUnit`, with `source == .preset` and no calibration evidence.
    case ratio(numerator: Decimal, denominator: Decimal, label: String?)
    /// The scale in force on another page, copied matrix for matrix (a drawing ratio follows
    /// each page's `/UserUnit`). A copied calibration is `source == .inherited`; a copied drawing
    /// ratio stays `.preset`, because it is that ratio on the new page too and the next copy must
    /// rescale it again (S-038). Neither carries evidence: the points were picked on the other
    /// sheet, and citing them here would be a calibration that did not happen here.
    case copyOf(page: PageID)
}

/// One page's drawing ratio in a batch (``TakeoffSession/applyPresetScales(_:)``).
public struct PresetScaleEntry: Hashable, Sendable {
    public let page: PageID
    public let ratioNumerator: Decimal
    public let ratioDenominator: Decimal
    public let label: String?

    public init(page: PageID, ratioNumerator: Decimal = 1, ratioDenominator: Decimal, label: String? = nil) {
        self.page = page
        self.ratioNumerator = ratioNumerator
        self.ratioDenominator = ratioDenominator
        self.label = label
    }
}

/// The scale entry points beside the two-point ``TakeoffSession/calibrate(page:first:second:knownLength:knownLengthUnit:scaleID:label:allowExtreme:)``:
/// a drawing ratio, a separate X/Y calibration, and one scale applied to many pages
/// (NL-MEASURE-01, NL-MEASURE-02, ADR-0019).
///
/// Every one routes through `.changeScale`, so undo, the audit trail and the recompute of
/// dependent measurements are the calibration's own.
extension TakeoffSession {

    /// Installs a drawing-ratio scale on a page (`1:50`, or `1/8" = 1'-0"` as `1:96`).
    ///
    /// The stored scale is `ScaleTransform.preset(...)`: `source == .preset`, the page's
    /// `/UserUnit` honoured, and **no** calibration evidence. A preset installed over a
    /// calibration removes that calibration's evidence in the same step (ADR-0019), because a
    /// derivation that cites picked points under a ratio nobody picked points for is the fake
    /// provenance the scale proposal used to write.
    public func setPresetScale(
        page: PageID,
        ratioNumerator: Decimal = 1,
        ratioDenominator: Decimal,
        label: String? = nil,
        scaleID: ScaleID? = nil,
        allowExtreme: Bool = false,
        keepExisting: Bool = false
    ) throws -> DocumentCommandOutcome {
        let scale = try presetScale(
            page: page,
            ratioNumerator: ratioNumerator,
            ratioDenominator: ratioDenominator,
            label: label,
            scaleID: scaleID,
            allowExtreme: allowExtreme
        )
        // Keep existing values (NL-MEASURE-03) applies to the page's own scale only.
        return try keepingValues(onPage: page, keepExisting && scaleID == nil) {
            try installScale(scale, evidence: nil)
        }
    }

    /// Calibrates a page with separate X and Y factors from two picked lines (spec 10.3).
    ///
    /// Each line's page components `(dx, dy)` and real length `L` satisfy
    /// `L² = (sx·dx)² + (sy·dy)²`; two lines give two equations linear in `sx²` and `sy²`, the
    /// same solve the calibration sheet previews (BH-252). For an exactly horizontal X line and
    /// an exactly vertical Y line the solve is the plain division, done in `Decimal` so the
    /// factor is as exact as a two-point calibration's.
    ///
    /// - Throws: ``ScaleError/calibrationPointsTooClose(pdfDistance:)`` for a line shorter
    ///   than the minimum, ``ScaleError/nonPositiveKnownLength(_:)`` for a zero length, and
    ///   ``DocumentCommandError/measurementFailed(_:)`` when the lines cannot be separated
    ///   (parallel or mirrored) or disagree (no positive solution).
    public func calibrateXY(
        page: PageID,
        xFirst: PDFPoint,
        xSecond: PDFPoint,
        xKnownLength: Decimal,
        yFirst: PDFPoint,
        ySecond: PDFPoint,
        yKnownLength: Decimal,
        knownLengthUnit: LengthUnit,
        scaleID: ScaleID? = nil,
        label: String? = nil,
        allowExtreme: Bool = false,
        keepExisting: Bool = false
    ) throws -> DocumentCommandOutcome {
        let (id, version) = try scaleIdentity(forPage: page, scaleID: scaleID)
        let factors = try SeparateAxisSolve.factors(
            xLine: (xFirst, xSecond),
            xMetres: knownLengthUnit.toBase(xKnownLength),
            yLine: (yFirst, ySecond),
            yMetres: knownLengthUnit.toBase(yKnownLength)
        )
        let scale = try ScaleTransform.separateXY(
            id: id,
            pageID: page,
            version: version,
            metresPerPointX: factors.x,
            metresPerPointY: factors.y,
            units: scaleUnitPolicy,
            source: .calibrationXY,
            label: label,
            allowExtreme: allowExtreme
        )
        let evidence = CalibrationEvidence(
            points: [xFirst, xSecond, yFirst, ySecond],
            enteredLength: .length(xKnownLength, in: knownLengthUnit),
            enteredUnit: knownLengthUnit,
            secondaryEnteredLength: .length(yKnownLength, in: knownLengthUnit)
        )
        return try keepingValues(onPage: page, keepExisting && scaleID == nil) {
            try installScale(scale, evidence: evidence)
        }
    }

    /// Applies one scale to several pages as one undoable step (NL-MEASURE-02).
    ///
    /// One `.changeScale` per page through ``applyBatch(_:)``, so the dependent measurements on
    /// every page recompute and a single ⌘Z takes the lot back — scales, page assignments and
    /// evidence. Pages are de-duplicated in order. A page named by `.copyOf` is skipped as a
    /// target, since it already has that scale.
    ///
    /// - Throws: ``DocumentCommandError/noScale(_:)`` when `.copyOf` names a page with no
    ///   scale; any refusal leaves the document exactly as it was.
    public func applyScale(_ source: BulkScaleSource, toPages pages: [PageID], keepExisting: Bool = false) throws -> DocumentBatchOutcome {
        var seen: Set<PageID> = []
        var targets = pages.filter { seen.insert($0).inserted }
        let template: ScaleTransform?
        if case .copyOf(let sourcePage) = source {
            guard let found = scale(onPage: sourcePage) else { throw DocumentCommandError.noScale(sourcePage) }
            template = found
            targets.removeAll { $0 == sourcePage }
        } else {
            template = nil
        }
        var built: [ScaleTransform] = []
        for page in targets {
            switch source {
            case .ratio(let numerator, let denominator, let label):
                built.append(try presetScale(
                    page: page,
                    ratioNumerator: numerator,
                    ratioDenominator: denominator,
                    label: label,
                    scaleID: nil,
                    allowExtreme: false
                ))
            case .copyOf:
                guard let template else { continue }
                let (id, version) = try scaleIdentity(forPage: page, scaleID: nil)
                built.append(ScaleTransform(
                    id: id,
                    pageID: page,
                    version: version,
                    matrix: try Self.matrix(template, carriedFrom: template.pageID, to: page, pages: pageDescriptors),
                    units: template.units,
                    // A drawing ratio copied is still a drawing ratio: marked `.inherited`, the copy
                    // lost the rescale, so a 1:50 carried A (UserUnit 1) → B (2) → C (1) kept B's
                    // doubled matrix on C, ×2 on lengths and ×4 on areas under a "1:50" label (S-038).
                    source: template.source == .preset ? .preset : .inherited,
                    label: template.label
                ))
            }
        }
        // Keep existing values (NL-MEASURE-03): every target page's current scale keeps what
        // was measured under it, for this one step.
        let kept = keepExisting ? Set(targets.compactMap { pageScale($0)?.id }) : []
        keepExistingForScales.formUnion(kept)
        defer { keepExistingForScales.subtract(kept) }
        return try installScales(built)
    }

    /// Installs a drawing ratio per page — each sheet's own proposal — as one undoable step
    /// (NL-MEASURE-02). Every scale is `source == .preset` with no evidence.
    public func applyPresetScales(_ entries: [PresetScaleEntry]) throws -> DocumentBatchOutcome {
        var seen: Set<PageID> = []
        let built = try entries.filter { seen.insert($0.page).inserted }.map { entry in
            try presetScale(
                page: entry.page,
                ratioNumerator: entry.ratioNumerator,
                ratioDenominator: entry.ratioDenominator,
                label: entry.label,
                scaleID: nil,
                allowExtreme: false
            )
        }
        return try installScales(built)
    }

    /// Installs several pages' scales through one `applyBatch`, with every target's evidence
    /// cleared in the same patch (CR-5): recorded, removed, and restored by the undo.
    private func installScales(_ built: [ScaleTransform]) throws -> DocumentBatchOutcome {
        var previousEvidence: [ScaleID: CalibrationEvidence?] = [:]
        for scale in built {
            previousEvidence.updateValue(evidence(for: scale.id), forKey: scale.id)
            clearEvidence(for: scale.id)
        }
        do {
            let outcome = try applyBatch(built.map { DocumentCommand.changeScale($0) })
            var inverse = outcome.inverse
            var forward = outcome.forward
            var mergedInverse = inverse.calibrationEvidence ?? [:]
            var mergedForward = forward.calibrationEvidence ?? [:]
            for (id, previous) in previousEvidence {
                mergedInverse.updateValue(previous, forKey: id)
                mergedForward.updateValue(nil, forKey: id)
            }
            inverse.calibrationEvidence = mergedInverse.isEmpty ? nil : mergedInverse
            forward.calibrationEvidence = mergedForward.isEmpty ? nil : mergedForward
            return DocumentBatchOutcome(
                commands: outcome.commands,
                inverse: inverse,
                forward: forward,
                changedMarkupIDs: outcome.changedMarkupIDs,
                changedPageIDs: outcome.changedPageIDs
            )
        } catch {
            for (id, previous) in previousEvidence {
                restoreEvidence(previous, for: id)
            }
            throw error
        }
    }

    /// How many measurements each page holds that a new scale on it would recompute: every
    /// markup with a tool and geometry resolving to the page's own scale, or to none yet.
    /// The bulk sheet's preview count (NL-MEASURE-02).
    public func measurementCount(onPages pages: Set<PageID>) -> Int {
        orderedMarkups.reduce(0) { count, record in
            guard pages.contains(record.pageID), record.tool != nil, record.geometry != nil,
                  record.tool != .temporaryMeasure else { return count }
            let pageScale = scale(onPage: record.pageID)
            let effective = scale(onPage: record.pageID, scaleID: record.scaleID)
            return (effective == nil || effective?.id == pageScale?.id) ? count + 1 : count
        }
    }

    /// How many markups sit on the pages at all.
    public func markupCount(onPages pages: Set<PageID>) -> Int {
        orderedMarkups.reduce(0) { pages.contains($1.pageID) ? $0 + 1 : $0 }
    }

    // MARK: Internals

    /// A copied scale's matrix on another page. A drawing ratio is per PDF unit *times the
    /// page's `/UserUnit`* (CR-128), so a preset carried to a page that declares a different
    /// user unit is rescaled by `target / source` — exactly, in `Decimal`. A calibration is a
    /// measured map of page points and is carried unchanged.
    static func matrix(
        _ template: ScaleTransform,
        carriedFrom sourcePage: PageID?,
        to targetPage: PageID,
        pages: [ZPDFContracts.PageDescriptor]
    ) throws -> AffineScaleMatrix {
        guard template.source == .preset,
              let source = pages.first(where: { $0.id == sourcePage }),
              let target = pages.first(where: { $0.id == targetPage }),
              source.userUnit != target.userUnit else { return template.matrix }
        let factor = try NumericPolicy.decimal(from: target.userUnit) / NumericPolicy.decimal(from: source.userUnit)
        let m = template.matrix
        return AffineScaleMatrix(a: m.a * factor, b: m.b * factor, c: m.c * factor, d: m.d * factor, tx: m.tx, ty: m.ty)
    }

    private func presetScale(
        page: PageID,
        ratioNumerator: Decimal,
        ratioDenominator: Decimal,
        label: String?,
        scaleID: ScaleID?,
        allowExtreme: Bool
    ) throws -> ScaleTransform {
        let (id, version) = try scaleIdentity(forPage: page, scaleID: scaleID)
        guard let descriptor = pageDescriptors.first(where: { $0.id == page }) else {
            throw DocumentCommandError.unknownPage(page)
        }
        return try ScaleTransform.preset(
            id: id,
            page: descriptor,
            version: version,
            ratioNumerator: ratioNumerator,
            ratioDenominator: ratioDenominator,
            units: scaleUnitPolicy,
            label: label,
            allowExtreme: allowExtreme
        )
    }
}

/// The separate X/Y solve, pure (spec 10.3; the same algebra as the calibration sheet's preview,
/// BH-252).
enum SeparateAxisSolve {

    /// Below this `|sin(θ2 − θ1) · sin(θ2 + θ1)|` the two lines cannot separate the axes.
    static let minimumSeparability = 0.01

    static func factors(
        xLine: (PDFPoint, PDFPoint),
        xMetres: Decimal,
        yLine: (PDFPoint, PDFPoint),
        yMetres: Decimal
    ) throws -> (x: Decimal, y: Decimal) {
        guard xMetres > 0 else { throw ScaleError.nonPositiveKnownLength(xMetres) }
        guard yMetres > 0 else { throw ScaleError.nonPositiveKnownLength(yMetres) }
        for line in [xLine, yLine] {
            let distance = line.0.distance(to: line.1)
            guard distance.isFinite, distance >= ScaleTransform.minimumCalibrationPDFDistance else {
                throw ScaleError.calibrationPointsTooClose(pdfDistance: distance)
            }
        }
        let dx1 = xLine.1.x - xLine.0.x, dy1 = xLine.1.y - xLine.0.y
        let dx2 = yLine.1.x - yLine.0.x, dy2 = yLine.1.y - yLine.0.y
        // Axis-aligned: the exact division, in Decimal.
        if dy1 == 0, dx2 == 0 {
            let x = xMetres / (try NumericPolicy.decimal(from: Swift.abs(dx1)))
            let y = yMetres / (try NumericPolicy.decimal(from: Swift.abs(dy2)))
            return (x, y)
        }
        let real1 = NumericPolicy.double(from: xMetres)
        let real2 = NumericPolicy.double(from: yMetres)
        let a1 = dx1 * dx1, b1 = dy1 * dy1
        let a2 = dx2 * dx2, b2 = dy2 * dy2
        let determinant = a1 * b2 - a2 * b1
        let separability = Swift.abs(determinant) / ((a1 + b1) * (a2 + b2))
        guard separability >= minimumSeparability else {
            throw DocumentCommandError.measurementFailed(
                "the two calibration lines are too close to parallel (or mirrored) to separate X from Y"
            )
        }
        let sx2 = (real1 * real1 * b2 - real2 * real2 * b1) / determinant
        let sy2 = (a1 * real2 * real2 - a2 * real1 * real1) / determinant
        guard sx2 > 0, sy2 > 0, sx2.isFinite, sy2.isFinite else {
            throw DocumentCommandError.measurementFailed(
                "the two calibration lines disagree: no stretch of the page axes fits both lengths"
            )
        }
        return (try NumericPolicy.decimal(from: sx2.squareRoot()), try NumericPolicy.decimal(from: sy2.squareRoot()))
    }
}
