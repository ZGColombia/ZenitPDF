import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Recalculate or Cancel, with what would change, before a recalibration commits
/// (NL-MEASURE-03, spec 10.6).
///
/// A recalibration used to restamp every dependent measurement with no count and no summary.
/// Now the sheet's Apply first runs the session's dry run and, when anything with a value would
/// change, says how many measurements and how the totals move — "40 measurements change. Plan
/// Area 1 204.00 → 1 187.35 m² (−1.38 %)" — and waits for Recalculate, Cancel, or Keep Existing
/// Values: the new scale is installed and the measurements keep their values, flagged as measured
/// against an older scale (ADR-0030 §2), until Measure ▸ Recalculate Stale Measurements.
@MainActor
enum ScaleImpactConfirmation {

    static let modalIdentifier = "calibration.recalculateImpact"

    /// The scale a request would install on the page, built without installing it.
    static func candidate(
        for request: CalibrationRequest,
        replacing current: ScaleTransform,
        page: ZPDFContracts.PageDescriptor
    ) throws -> ScaleTransform {
        switch request {
        case let .preset(denominator, label, _):
            return try ScaleTransform.preset(
                id: current.id, page: page, version: current.version + 1,
                ratioDenominator: denominator, units: current.units, label: label, allowExtreme: true
            )
        case let .twoPoint(first, second, length, unit, label, _):
            return try ScaleTransform.calibratedTwoPoint(
                id: current.id, pageID: page.id, version: current.version + 1,
                first: first, second: second, knownLength: length, knownLengthUnit: unit,
                units: current.units, label: label, allowExtreme: true
            )
        case let .separateAxes(xFirst, xSecond, xLength, yFirst, ySecond, yLength, unit, label, _):
            let factors = try TakeoffSession.separateAxisFactors(
                xLine: (xFirst, xSecond), xMetres: unit.toBase(xLength),
                yLine: (yFirst, ySecond), yMetres: unit.toBase(yLength)
            )
            return try ScaleTransform.separateXY(
                id: current.id, pageID: page.id, version: current.version + 1,
                metresPerPointX: factors.x, metresPerPointY: factors.y,
                units: current.units, source: .calibrationXY, label: label, allowExtreme: true
            )
        }
    }

    /// The sentence the confirmation shows. Pure, for the tests.
    static func message(for impact: ScaleChangeImpact, formatter: QuantityFormatter) -> String {
        var lines = [String(
            format: NSLocalizedString(
                "Measurements that change: %d.",
                comment: "Recalibration impact: how many measurements get a new value"
            ),
            impact.changedCount
        )]
        for total in impact.totals {
            let dimension = total.field.dimension
            let before = formatter.text(Shown.Quantity(value: total.before, dimension: Shown.Dimension(domain: dimension)))
            let after = formatter.text(Shown.Quantity(value: total.after, dimension: Shown.Dimension(domain: dimension)))
            let unit = formatter.symbol(Shown.Quantity(value: total.after, dimension: Shown.Dimension(domain: dimension)))
            var line = String(
                format: NSLocalizedString(
                    "%1$@ %2$@ → %3$@ %4$@",
                    comment: "Recalibration impact line: field name, total before, total after, unit"
                ),
                fieldName(total.field), before, after, unit
            )
            if let change = total.relativeChange {
                let percent = NSDecimalNumber(decimal: change * 100).doubleValue
                line += String(format: " (%@%.2f %%)", percent >= 0 ? "+" : "−", abs(percent))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The ledger's name for a field, which is the field's own display name: the net area reads
    /// "Plan Area" and the net wall area "Wall Area", as their columns are called (X-037). The
    /// special cases that said so here are gone since the field names agree (X-fieldname-case).
    static func fieldName(_ field: ZPDFContracts.MeasurementField) -> String {
        Shown.Field(domain: field)?.displayName ?? field.rawValue
    }

    /// What the person chose.
    enum Decision: Equatable, Sendable {
        case recalculate
        case keepExisting
        case cancel
    }

    /// Asks Recalculate, Cancel or Keep Existing Values when the request would change measured
    /// values on the page.
    ///
    /// - Returns: `.recalculate` without asking when nothing with a value changes (a first
    ///   calibration, or an empty page). A process with no user answers Cancel.
    static func decide(
        _ request: CalibrationRequest,
        page: PageID,
        core: AppCoreEnvironment,
        window: NSWindow?
    ) async -> Decision {
        let session = core.session
        guard let current = await session.scale(onPage: page),
              let descriptor = await session.pageDescriptors.first(where: { $0.id == page }),
              let candidate = try? candidate(for: request, replacing: current, page: descriptor) else { return .recalculate }
        let impact = await session.scaleChangeImpact(page: page, candidate: candidate)
        guard impact.changedCount > 0 else { return .recalculate }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Recalculate the measurements on this page?",
            comment: "Recalibration impact title"
        )
        alert.informativeText = message(for: impact, formatter: core.snapshot.ledger.formatter)
        alert.addButton(withTitle: NSLocalizedString("Recalculate", comment: "Recalibration impact: apply and recompute"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Recalibration impact: change nothing"))
        alert.addButton(withTitle: NSLocalizedString("Keep Existing Values", comment: "Recalibration impact: apply, and leave the measured values as they are, flagged stale"))
        return await withCheckedContinuation { continuation in
            ZenitModalPresenter.runAlert(
                alert,
                identifier: modalIdentifier,
                sheetedOn: window,
                answerWithoutAUser: .dismissed
            ) { answer in
                switch answer {
                case .button(0): continuation.resume(returning: .recalculate)
                case .button(2): continuation.resume(returning: .keepExisting)
                default: continuation.resume(returning: .cancel)
                }
            }
        }
    }

    /// The Bool form: whether to go ahead (Recalculate or Keep).
    static func confirm(
        _ request: CalibrationRequest,
        page: PageID,
        core: AppCoreEnvironment,
        window: NSWindow?
    ) async -> Bool {
        await decide(request, page: page, core: core, window: window) != .cancel
    }
}
