import Foundation
import ZPDFContracts

/// The bus side of the scale entry points (NL-MEASURE-01, NL-MEASURE-02, ADR-0019): each one
/// undoable, audited and published like ``DocumentCommandBus/calibrate(page:first:second:knownLength:knownLengthUnit:scaleID:label:allowExtreme:)``.
extension DocumentCommandBus {

    private static var changeScaleActionName: String {
        NSLocalizedString("Change Scale", comment: "Undo action name for a scale change")
    }

    /// Installs a drawing-ratio scale (`source == .preset`, no evidence) on one page.
    @discardableResult
    public func setPresetScale(
        page: PageID,
        ratioNumerator: Decimal = 1,
        ratioDenominator: Decimal,
        label: String? = nil,
        scaleID: ScaleID? = nil,
        allowExtreme: Bool = false,
        keepExisting: Bool = false
    ) async throws -> DocumentChangeSet {
        try await performSessionStep(actionName: Self.changeScaleActionName) { session in
            try await session.setPresetScale(
                page: page,
                ratioNumerator: ratioNumerator,
                ratioDenominator: ratioDenominator,
                label: label,
                scaleID: scaleID,
                allowExtreme: allowExtreme,
                keepExisting: keepExisting
            )
        }
    }

    /// Two-point calibration that keeps the values measured under the page's old scale
    /// (NL-MEASURE-03): they stay as they are, flagged stale, until Recalculate Stale.
    @discardableResult
    public func calibrate(
        page: PageID,
        first: PDFPoint,
        second: PDFPoint,
        knownLength: Decimal,
        knownLengthUnit: Domain.Length,
        scaleID: ScaleID? = nil,
        label: String? = nil,
        allowExtreme: Bool = false,
        keepExisting: Bool
    ) async throws -> DocumentChangeSet {
        try await performSessionStep(actionName: Self.changeScaleActionName) { session in
            try await session.calibrate(
                page: page, first: first, second: second, knownLength: knownLength,
                knownLengthUnit: knownLengthUnit, scaleID: scaleID, label: label,
                allowExtreme: allowExtreme, keepExisting: keepExisting
            )
        }
    }

    /// Measure ▸ Recalculate Stale Measurements: every value kept under an older scale version is
    /// brought to its scale's current version, as one undoable step (NL-MEASURE-03).
    @discardableResult
    public func recalculateStale() async throws -> DocumentChangeSet {
        try await perform(.recalculateMeasurements(pageID: nil))
    }

    /// Calibrates one page with separate X and Y factors (`source == .calibrationXY`).
    @discardableResult
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
    ) async throws -> DocumentChangeSet {
        try await performSessionStep(actionName: Self.changeScaleActionName) { session in
            try await session.calibrateXY(
                page: page,
                xFirst: xFirst,
                xSecond: xSecond,
                xKnownLength: xKnownLength,
                yFirst: yFirst,
                ySecond: ySecond,
                yKnownLength: yKnownLength,
                knownLengthUnit: knownLengthUnit,
                scaleID: scaleID,
                label: label,
                allowExtreme: allowExtreme,
                keepExisting: keepExisting
            )
        }
    }

    /// Applies one scale to several pages as a single undoable step.
    @discardableResult
    public func applyScale(_ source: BulkScaleSource, toPages pages: [PageID], keepExisting: Bool = false) async throws -> DocumentBatchOutcome {
        try await performSessionBatchStep(
            actionName: NSLocalizedString("Apply Scale to Pages", comment: "Undo action name for a scale applied to several pages")
        ) { session in
            try await session.applyScale(source, toPages: pages, keepExisting: keepExisting)
        }
    }

    /// Adds a Scale Region with its own drawing ratio, leaving the page's scale alone, as a single
    /// undoable step (NL-AUTO-19). Returns the new scale's identifier.
    @discardableResult
    public func addRegionPresetScale(
        page: PageID,
        ratioNumerator: Decimal = 1,
        ratioDenominator: Decimal,
        label: String? = nil,
        boundary: [PDFPoint],
        name: String
    ) async throws -> ScaleID {
        var created: ScaleID?
        _ = try await performSessionBatchStep(
            actionName: NSLocalizedString("Add Scale Region", comment: "Undo action name for a Scale Region added with its own drawing ratio")
        ) { session in
            let result = try await session.addRegionPresetScale(
                page: page,
                ratioNumerator: ratioNumerator,
                ratioDenominator: ratioDenominator,
                label: label,
                boundary: boundary,
                name: name
            )
            created = result.scaleID
            return result.outcome
        }
        guard let created else { throw DocumentCommandError.noScale(page) }
        return created
    }

    /// Installs each page's own drawing ratio (its proposal) as a single undoable step.
    @discardableResult
    public func applyPresetScales(_ entries: [PresetScaleEntry]) async throws -> DocumentBatchOutcome {
        try await performSessionBatchStep(
            actionName: NSLocalizedString("Apply Proposed Scales", comment: "Undo action name for applying the scales read from several sheets")
        ) { session in
            try await session.applyPresetScales(entries)
        }
    }
}
