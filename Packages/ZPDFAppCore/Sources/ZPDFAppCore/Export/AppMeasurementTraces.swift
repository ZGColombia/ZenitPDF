import Foundation
import ZPDFContracts

/// Feature 16's trace, gathered from a live session.
///
/// `MeasurementTraceResolver` was finished and tested and had no caller, so every export
/// shipped without the trace columns every format can write. This is the caller: it hands the
/// resolver exactly what it is allowed to read — page labels, every scale transform the
/// session holds, Scale Region names, page `/UserUnit`s and the audit trail — and nothing that
/// could stand in for "the scale in force now".
extension TakeoffSession {

    /// The resolver's inputs from this session, before the audit trail is folded in.
    public func measurementTraceSources() -> MeasurementTraceResolver.Sources {
        var labels: [PageID: String] = [:]
        var userUnits: [PageID: Double] = [:]
        for page in pageDescriptors {
            labels[page.id] = page.label.isEmpty ? String(page.index + 1) : page.label
            let unit = userUnit(onPage: page.id)
            if unit != 1 { userUnits[page.id] = unit }
        }
        var regions: [ScaleRegionID: String] = [:]
        for region in scaleRegionDefinitions { regions[region.id] = region.name }
        return MeasurementTraceResolver.Sources(
            pageLabels: labels,
            scales: MeasurementTraceResolver.Sources.index(allScales),
            scaleRegionNames: regions,
            pageUserUnits: userUnits
        )
    }
}

extension AppCoreEnvironment {

    /// The trace of every ledger row, keyed by markup.
    ///
    /// Queued audit writes land first, so an edit made just before Export is in the trail the
    /// trace reads (the BH-911 rule the audit-trail export already keeps).
    public func measurementTraceFacts() async -> [MarkupID: MeasurementTraceFacts] {
        await history.settle()
        let sources = await session.measurementTraceSources().absorbing(auditTrail: history.auditRecords)
        let records = await session.ledgerMarkups
        return MeasurementTraceResolver().facts(for: records, sources: sources)
    }
}
