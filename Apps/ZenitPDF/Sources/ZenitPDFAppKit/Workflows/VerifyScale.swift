import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Measure ▸ Verify Scale… (NL-MEASURE-04): after calibrating, measure a second dimension the
/// drawing states and see how far the scale is from it.
///
/// Two clicks on the canvas (the calibration pick), the stated length typed in the same grammar
/// the calibration uses, and the result said in the tray: "The scale agrees with the drawing
/// within 0.21 %", or a warning above ``thresholdPercent`` naming both lengths. Nothing about the
/// scale changes; a disagreement is for the person to act on.
@MainActor
public enum VerifyScale {

    public static let modalIdentifier = "calibration.verify"

    /// Above this deviation, in percent, the result is a warning rather than a confirmation.
    public nonisolated static let thresholdPercent: Decimal = 1

    /// Documents waiting for their two verification clicks.
    private static var pending: Set<UUID> = []

    /// One verification.
    public struct Result: Equatable, Sendable {
        /// The drawn line at the page's scale, in metres.
        public let measuredMetres: Decimal
        /// The length the drawing states, in metres.
        public let statedMetres: Decimal
        /// `measured / stated − 1`.
        public var deviation: Decimal { measuredMetres / statedMetres - 1 }
        /// The deviation in percent, unsigned.
        public var percent: Decimal { Swift.abs(deviation * 100) }
        public var agrees: Bool { percent <= thresholdPercent }
    }

    /// Arms the verification: the canvas's next two points are compared, not calibrated.
    static func arm(_ document: ZenitPDFProjectDocument) {
        PendingPointPicks.disarmAll(document)  // one borrowed pick at a time (R-001)
        pending.insert(document.documentIdentity)
    }

    /// Whether the document is waiting for verification points.
    static func isArmed(_ document: ZenitPDFProjectDocument) -> Bool { pending.contains(document.documentIdentity) }

    /// Forgets a pending verification (Escape before the second click).
    static func disarm(_ document: ZenitPDFProjectDocument) { pending.remove(document.documentIdentity) }

    /// Measures the two points on the page's scale and compares them with the stated length.
    ///
    /// - Throws: ``DocumentCommandError/noScale(_:)`` on a page with no scale.
    public static func evaluate(
        points: [PDFPointValue],
        stated: CalibrationPrompt.Entry,
        page: PageID,
        session: TakeoffSession
    ) async throws -> Result {
        let geometry = MeasurementGeometry(pageID: page, points: points.map { PDFPoint(shown: $0) })
        let result = try await session.measure(tool: .length, geometry: geometry)
        let measured = result[.planLength]?.value ?? 0
        return Result(measuredMetres: measured, statedMetres: stated.unit.toBase(stated.length))
    }

    /// The tray entry for a result.
    public static func warning(for result: Result, page: PageID, formatter: QuantityFormatter) -> AppWarning {
        let percent = String(format: "%.2f", NSDecimalNumber(decimal: result.percent).doubleValue)
        let measured = formatter.textWithUnit(Shown.Quantity.metres(result.measuredMetres))
        let stated = formatter.textWithUnit(Shown.Quantity.metres(result.statedMetres))
        let title = result.agrees
            ? String(format: NSLocalizedString(
                "The scale agrees with the drawing within %@ %%.",
                comment: "Verify scale result: the deviation in percent"
            ), percent)
            : String(format: NSLocalizedString(
                "The scale is off by %@ %%.",
                comment: "Verify scale result above the threshold: the deviation in percent"
            ), percent)
        let message = String(
            format: NSLocalizedString(
                "The line measures %1$@ where the drawing says %2$@.",
                comment: "Verify scale detail: measured length, stated length"
            ),
            measured, stated
        ) + (result.agrees ? "" : " " + NSLocalizedString(
            "Check the calibration before measuring further.",
            comment: "Verify scale advice when the scale disagrees"
        ))
        return AppWarning(
            id: UUID(),
            severity: result.agrees ? .info : .warning,
            title: title,
            message: message,
            source: NSLocalizedString("Verify Scale", comment: "Warning source: scale verification"),
            timestamp: Date(),
            relatedPageID: page.rawValue
        )
    }

    /// The two points arrived: ask the stated length, compare, and say the result.
    static func finish(points: [PDFPointValue], document: ZenitPDFProjectDocument, window: NSWindow?) {
        disarm(document)
        guard points.count == 2, let core = document.core, let current = core.document.currentPageID,
              let window else { return }
        guard let entry = CalibrationPrompt.ask(
            in: window,
            defaultUnit: CalibrationPrompt.promptUnit(for: core.snapshot.units.length),
            title: NSLocalizedString("What length does the drawing state for that line?", comment: "Verify scale prompt title"),
            message: NSLocalizedString(
                "Use a printed dimension other than the one you calibrated on. Nothing about the scale changes.",
                comment: "Verify scale prompt message"
            ),
            confirmTitle: NSLocalizedString("Verify", comment: "Verify scale prompt button"),
            identifier: modalIdentifier
        ) else { return }
        let page = PageID(current)
        Task { @MainActor in
            do {
                _ = try await record(points: points, stated: entry, page: page, core: core)
                // The check is kept with the calibration evidence (ADR-0030): the document has
                // something new to save, though nothing about the scale changed.
                document.updateChangeCount(.changeDone)
            } catch {
                ZenitErrorPresenter.present(error, in: window)
            }
        }
    }

    /// Measures, stores the check with the calibration evidence (when the scale has any), lists it
    /// in History and says the result in the tray (NL-MEASURE-04, ADR-0030 §1).
    @discardableResult
    static func record(
        points: [PDFPointValue],
        stated: CalibrationPrompt.Entry,
        page: PageID,
        core: AppCoreEnvironment
    ) async throws -> (result: Result, storedWithEvidence: Bool) {
        let formatter = core.snapshot.ledger.formatter
        let check = try await core.verifyScale(
            page: page,
            points: points.map { PDFPoint(shown: $0) },
            statedLength: stated.length,
            statedUnit: stated.unit
        ) { verification in
            let result = Result(measuredMetres: verification.measuredLength.value, statedMetres: verification.statedLength.value)
            let warning = Self.warning(for: result, page: page, formatter: formatter)
            return warning.title + " " + warning.message
        }
        let result = Result(measuredMetres: check.verification.measuredLength.value, statedMetres: check.verification.statedLength.value)
        core.document.post(warning(for: result, page: page, formatter: formatter))
        return (result, check.storedWithEvidence)
    }
}
