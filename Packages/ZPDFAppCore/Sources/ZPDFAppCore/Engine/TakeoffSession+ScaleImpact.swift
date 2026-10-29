import Foundation
import ZPDFContracts
import ZPDFMeasurementEngine

/// What replacing a page's scale would change, computed before anything changes
/// (NL-MEASURE-03, spec 10.6). A dry run: every affected measurement is recomputed on a copy
/// against the candidate scale, through the same engine, and nothing is stored.
public struct ScaleChangeImpact: Equatable, Sendable {

    /// One summed field's total over the affected measurements, before and after, as the ledger
    /// totals it: Repeat × applied, cutout rows left out.
    public struct FieldTotal: Equatable, Sendable {
        public let field: MeasurementField
        public let before: Decimal
        public let after: Decimal

        /// `after / before − 1`, or `nil` when there was nothing before.
        public var relativeChange: Decimal? {
            guard before != 0 else { return nil }
            return after / before - 1
        }
    }

    /// How many measurements would get a different value.
    public let changedCount: Int
    /// The summed fields that change, in the order a person reads a takeoff: areas, lengths,
    /// volume. Only fields with a non-zero total on either side are listed.
    public let totals: [FieldTotal]

    public static let none = ScaleChangeImpact(changedCount: 0, totals: [])
}

extension TakeoffSession {

    /// The summed fields the impact reports, in reading order.
    static let impactFields: [MeasurementField] = [
        .netArea, .trueArea, .netWallArea, .planLength, .trueLength, .perimeter, .volume
    ]

    /// What installing `candidate` as `page`'s own scale would change.
    ///
    /// Covers every measurement on the page that resolves to the page's scale today (a Scale
    /// Region's own scale is untouched by a page recalibration, exactly as ``applyScale`` scopes
    /// it). A page with no scale yet changes nothing that has a value, so the impact is `.none`.
    /// A measurement the candidate cannot measure (a radius under a non-uniform scale) counts as
    /// changed and contributes nothing after.
    public func scaleChangeImpact(page: PageID, candidate: ScaleTransform) -> ScaleChangeImpact {
        guard let current = scale(onPage: page) else { return .none }
        let engine = dryRunEngine
        var before: [MeasurementField: Decimal] = [:]
        var after: [MeasurementField: Decimal] = [:]
        var changed = 0
        for record in orderedMarkups where record.pageID == page {
            guard let tool = record.tool, let geometry = record.geometry,
                  let old = record.measurement,
                  scale(onPage: page, scaleID: record.scaleID)?.id == current.id else { continue }
            let new = try? engine.calculate(
                tool: tool, geometry: geometry, scale: candidate, parameters: record.parameters ?? .default
            )
            var differs = new == nil
            // The totals are the ledger's (S-037): a cutout row carries no quantity there
            // (ADR-0018) — its area is already out of the parent's net area, and its perimeter
            // is not added beside the parent's — and every quantity counts Repeat × times.
            let totalled = record.parentMarkupID == nil
            let times = RepetitionColumn.count(of: record)
            for field in Self.impactFields {
                let oldValue = old[field]?.value
                let newValue = new?[field]?.value
                if totalled, let oldValue { before[field, default: 0] += RepetitionColumn.repeatedTotal(value: oldValue, count: times) }
                if totalled, let newValue { after[field, default: 0] += RepetitionColumn.repeatedTotal(value: newValue, count: times) }
                if oldValue != newValue { differs = true }
            }
            if differs { changed += 1 }
        }
        let totals = Self.impactFields.compactMap { field -> ScaleChangeImpact.FieldTotal? in
            let b = before[field] ?? 0, a = after[field] ?? 0
            guard b != 0 || a != 0 else { return nil }
            return ScaleChangeImpact.FieldTotal(field: field, before: b, after: a)
        }
        return ScaleChangeImpact(changedCount: changed, totals: totals)
    }

    /// The separate X/Y factors two picked lines give, without installing anything — the
    /// candidate for an impact preview of ``calibrateXY(page:xFirst:xSecond:xKnownLength:yFirst:ySecond:yKnownLength:knownLengthUnit:scaleID:label:allowExtreme:)``.
    public nonisolated static func separateAxisFactors(
        xLine: (PDFPoint, PDFPoint),
        xMetres: Decimal,
        yLine: (PDFPoint, PDFPoint),
        yMetres: Decimal
    ) throws -> (x: Decimal, y: Decimal) {
        try SeparateAxisSolve.factors(xLine: xLine, xMetres: xMetres, yLine: yLine, yMetres: yMetres)
    }
}
