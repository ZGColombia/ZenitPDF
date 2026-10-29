import Foundation
import ZPDFContracts

/// Keep existing values on a scale change (NL-MEASURE-03, spec 10.6, ADR-0030 §2).
///
/// Recalculate stays the default. Keep installs the new scale and leaves every measurement taken
/// under the old version with its value and its old `scaleVersion`, flagged
/// ``MeasurementWarning/Code/staleScaleVersion``; hydration opens such a value as saved instead of
/// recomputing it, and Measure ▸ Recalculate Stale Measurements brings them to the current scale.
extension TakeoffSession {

    /// Runs `body` with the page's current scale marked to keep its measured values on its next
    /// change. Synchronous on the session, so nothing else can interleave; the mark is cleared
    /// whether or not the change happened.
    func keepingValues<T>(onPage page: PageID, _ keep: Bool, _ body: () throws -> T) rethrows -> T {
        guard keep, let current = pageScale(page) else { return try body() }
        keepExistingForScales.insert(current.id)
        defer { keepExistingForScales.remove(current.id) }
        return try body()
    }

    /// Two-point calibration that keeps the values measured under the page's old scale.
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
    ) throws -> DocumentCommandOutcome {
        try keepingValues(onPage: page, keepExisting && scaleID == nil) {
            try calibrate(
                page: page, first: first, second: second, knownLength: knownLength,
                knownLengthUnit: knownLengthUnit, scaleID: scaleID, label: label, allowExtreme: allowExtreme
            )
        }
    }

    /// A stored value that hydration keeps as saved: a measurement taken under an older version
    /// of the very scale the markup still resolves to, by the current formula. Anything else is
    /// recomputed, as before — including a stale value from an older formula, whose rules changed.
    ///
    /// The value must be one: non-empty and flagged ``MeasurementWarning/Code/staleScaleVersion``.
    /// A detector's capture stamp (ADR-0031) is a result with no values whose formula version
    /// reads as current, and on a row with an older `scaleVersion` it used to pass as kept, so
    /// the row opened with no values and no stale flag (R-046).
    func keepsStoredValue(_ record: MarkupRecord) -> Bool {
        guard record.tool != nil, record.geometry != nil, let measurement = record.measurement,
              !measurement.values.isEmpty, measurement.hasWarning(.staleScaleVersion),
              measurement.formulaVersion == ContractVersion.measurementFormulaVersion,
              let scaleID = record.scaleID, let version = record.scaleVersion,
              let effective = scale(onPage: record.pageID, scaleID: record.scaleID),
              effective.id == scaleID else { return false }
        return version < effective.version
    }

    /// Every markup measured under an older version of its scale.
    public var staleMeasurementIDs: [MarkupID] {
        orderedMarkups.compactMap { record in
            guard let scaleID = record.scaleID, let version = record.scaleVersion, record.measurement != nil,
                  let effective = scale(onPage: record.pageID, scaleID: record.scaleID),
                  effective.id == scaleID, version < effective.version else { return nil }
            return record.id
        }
    }

    /// The kept result, flagged stale against `current` once (on its headline field when it has
    /// one). `nil` when it already carries the flag.
    static func flaggingStale(_ result: MeasurementResult, current: ScaleTransform, tool: MeasurementTool?) -> MeasurementResult? {
        guard !result.warnings.contains(where: { $0.code == .staleScaleVersion }) else { return nil }
        let used = result.provenance?.scaleVersion
        let warning = MeasurementWarning(
            code: .staleScaleVersion,
            field: tool.map { Domain.Field(shown: Shown.Kind(domain: $0).primaryField) }
                .flatMap { result.values[$0] != nil ? $0 : nil }
                ?? result.values.keys.sorted { $0.rawValue < $1.rawValue }.first,
            detail: "used=\(used.map(String.init) ?? "?") current=\(current.version) kept"
        )
        return MeasurementResult(
            values: result.values,
            warnings: result.warnings + [warning],
            formulaVersion: result.formulaVersion,
            provenance: result.provenance
        )
    }
}
